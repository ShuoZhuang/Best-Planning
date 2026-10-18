// 安装包验证：大小、SHA-256、ZIP 结构、AppxManifest 身份（规格 §10.1 第 2、3 层）。
//
// 这里做的是"**从成品里读事实**"：包身份、发布者、架构、版本都来自 MSIX 内部的
// `AppxManifest.xml`，而不是清单里的声明。两者一致才算通过——只信清单等于让远端同时
// 决定"装什么"和"它说自己是谁"。
//
// 签名与证书链由 Windows API 验证（`UpdateHelper.verifyPackage`），因为 MSIX 的签名
// 不是 Authenticode/PKCS#7 文件签名，Dart 侧没有可信的等价实现。命令式地把它推给助手，
// 也让"主程序验证过"不能替代"助手再验证一次"（§10.2）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:xml/xml.dart';

final class ZipUpdatePackageVerifier implements UpdatePackageVerifier {
  ZipUpdatePackageVerifier({this.helper});

  final UpdateHelper? helper;

  /// MSIX 必须具备的条目。缺任何一个都说明"这不是一个可安装的 MSIX"。
  static const List<String> requiredEntries = [
    '[Content_Types].xml',
    'AppxManifest.xml',
    'AppxBlockMap.xml',
  ];

  static const String signatureEntry = 'AppxSignature.p7x';

  @override
  Future<PackageVerification> verify({
    required String path,
    required UpdateTarget target,
    required InstalledPackage installed,
    required bool verifyNativeSignature,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.packageFormatInvalid),
      );
    }

    final int sizeBytes;
    final String sha256Hex;
    try {
      sizeBytes = await file.length();
      sha256Hex = (await sha256.bind(file.openRead()).first).toString();
    } on FileSystemException {
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.downloadPermissionDenied),
      );
    }

    if (sizeBytes != target.sizeBytes) {
      return PackageVerification.invalid(
        UpdateFailure(
          UpdateFailureCode.downloadSizeMismatch,
          detail: 'size=$sizeBytes expected=${target.sizeBytes}',
        ),
      );
    }
    if (sha256Hex != target.sha256) {
      return PackageVerification.invalid(
        UpdateFailure(
          UpdateFailureCode.downloadHashMismatch,
          detail: 'sha256=$sha256Hex',
        ),
      );
    }

    final Archive archive;
    InputFileStream? input;
    try {
      input = InputFileStream(path);
      archive = ZipDecoder().decodeStream(input);
    } on Object {
      input?.closeSync();
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.packageFormatInvalid),
      );
    }

    final List<int>? manifestBytes;
    try {
      // 必须在关闭文件句柄之前读出清单内容：archive 4 的条目是惰性读取的。
      manifestBytes = archive.find('AppxManifest.xml')?.readBytes();
    } on Object {
      input.closeSync();
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.packageFormatInvalid),
      );
    } finally {
      // 不关闭会让 Windows 无法删除/移动这个包（安装前它会被再次校验与改名）。
      input.closeSync();
    }

    final names = archive.files.map((entry) => entry.name).toSet();
    for (final required in requiredEntries) {
      if (!names.contains(required)) {
        return PackageVerification.invalid(
          UpdateFailure(
            UpdateFailureCode.packageFormatInvalid,
            detail: 'missing=$required',
          ),
        );
      }
    }
    if (!names.contains(signatureEntry)) {
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.packageSignatureMissing),
      );
    }

    if (manifestBytes == null || manifestBytes.isEmpty) {
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.packageFormatInvalid),
      );
    }

    final _AppxIdentity identity;
    try {
      identity = _parseIdentity(manifestBytes);
    } on Object {
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.packageFormatInvalid),
      );
    }

    // 包内部版本必须与清单声明的目标版本一致（清单签名保护前者，包清单保护后者）。
    if (!identity.versionMatches(target.msixVersion)) {
      return PackageVerification.invalid(
        UpdateFailure(
          UpdateFailureCode.packageVersionMismatch,
          detail: 'package=${identity.version.value} target=${target.msixVersion.value}',
        ),
      );
    }

    final mismatch = _identityMismatch(identity, installed);
    if (mismatch != null) {
      return PackageVerification.invalid(mismatch);
    }

    final relation = target.msixVersion.compareTo(installed.version);
    if (relation == 0) {
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.packageVersionSame),
      );
    }
    if (relation < 0) {
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.packageDowngradeBlocked),
      );
    }

    if (verifyNativeSignature) {
      final activeHelper = helper;
      if (activeHelper == null) {
        return const PackageVerification.invalid(
          UpdateFailure(UpdateFailureCode.helperMissing),
        );
      }
      final native = await activeHelper.verifyPackage(path: path);
      if (!native.ok) {
        return PackageVerification.invalid(
          native.failure ??
              const UpdateFailure(UpdateFailureCode.packageSignatureInvalid),
        );
      }
    }

    return PackageVerification.valid(
      path: path,
      sizeBytes: sizeBytes,
      sha256: sha256Hex,
      identity: InstalledPackage(
        identityName: identity.name,
        publisher: identity.publisher,
        familyName: packageFamilyNameFor(identity.name, identity.publisher),
        architecture: identity.architecture,
        version: identity.version,
      ),
      nativeSignatureVerified: verifyNativeSignature,
    );
  }

  UpdateFailure? _identityMismatch(
    _AppxIdentity identity,
    InstalledPackage installed,
  ) {
    if (identity.name != appPackageIdentityName) {
      return const UpdateFailure(UpdateFailureCode.packageIdentityMismatch);
    }
    if (normalizePublisher(identity.publisher) != normalizePublisher(appPublisher)) {
      return const UpdateFailure(UpdateFailureCode.packagePublisherMismatch);
    }
    if (packageFamilyNameFor(identity.name, identity.publisher) !=
        appPackageFamilyName) {
      return const UpdateFailure(UpdateFailureCode.packageFamilyMismatch);
    }
    if (identity.architecture != PackageArchitecture.x64) {
      return const UpdateFailure(UpdateFailureCode.packageArchMismatch);
    }
    if (installed.familyName != appPackageFamilyName) {
      return const UpdateFailure(UpdateFailureCode.packageFamilyMismatch);
    }
    return null;
  }

  _AppxIdentity _parseIdentity(List<int> bytes) {
    final document = XmlDocument.parse(utf8.decode(bytes));
    final identity = document
        .findAllElements('Identity')
        .where((element) => element.parentElement?.name.local == 'Package')
        .firstOrNull;
    if (identity == null) {
      throw const FormatException('AppxManifest.xml 缺少 Package/Identity');
    }
    final name = identity.getAttribute('Name');
    final publisher = identity.getAttribute('Publisher');
    final version = MsixVersion.tryParse(identity.getAttribute('Version'));
    final architecture =
        PackageArchitecture.tryParse(
          identity.getAttribute('ProcessorArchitecture'),
        ) ??
        // 缺省表示 neutral；MSIX 要求显式声明，因此这里按"不匹配"处理。
        PackageArchitecture.neutral;
    if (name == null || name.isEmpty || publisher == null || publisher.isEmpty) {
      throw const FormatException('Identity 缺少 Name/Publisher');
    }
    if (version == null) {
      throw const FormatException('Identity 缺少合法的 Version');
    }
    return _AppxIdentity(
      name: name,
      publisher: publisher,
      version: version,
      architecture: architecture,
    );
  }
}

final class _AppxIdentity {
  const _AppxIdentity({
    required this.name,
    required this.publisher,
    required this.version,
    required this.architecture,
  });

  final String name;
  final String publisher;
  final MsixVersion version;
  final PackageArchitecture architecture;

  bool versionMatches(MsixVersion expected) => version == expected;
}

