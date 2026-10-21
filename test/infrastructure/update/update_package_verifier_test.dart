// 安装包验证：大小/哈希/ZIP 结构/身份/版本（UPD-014 / UPD-016 / UPD-032 的主程序侧）。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/update_package_verifier.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_msix_test_');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<File> writePackage({
    String identityName = appPackageIdentityName,
    String publisher = appPublisher,
    String version = '1.9.0.0',
    String architecture = 'x64',
    bool includeManifest = true,
    bool includeSignature = true,
  }) async {
    final archive = Archive()
      ..add(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
      ..add(ArchiveFile.string('AppxBlockMap.xml', '<BlockMap/>'));
    if (includeManifest) {
      archive.add(
        ArchiveFile.string(
          'AppxManifest.xml',
          _manifestXml(
            name: identityName,
            publisher: publisher,
            version: version,
            architecture: architecture,
          ),
        ),
      );
    }
    if (includeSignature) {
      archive.add(ArchiveFile.bytes('AppxSignature.p7x', [1, 2, 3]));
    }
    final bytes = ZipEncoder().encode(archive);
    final file = File('${directory.path}${Platform.pathSeparator}package.msix');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<UpdateTarget> targetFor(
    File file, {
    MsixVersion? version,
    String? sha256Override,
  }) async {
    final bytes = await file.readAsBytes();
    return UpdateTarget(
      version: const SemVer(1, 9, 0),
      buildNumber: 46,
      tag: 'v1.9.0',
      msixVersion: version ?? const MsixVersion(1, 9, 0, 0),
      fileName: 'BestPlanning_1.9.0.0_x64.msix',
      downloadUrl: 'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/BestPlanning_1.9.0.0_x64.msix',
      sizeBytes: bytes.length,
      sha256: sha256Override ?? sha256.convert(bytes).toString(),
      manifestDigest: 'a' * 64,
      keyId: 'test-key',
    );
  }

  const installed = InstalledPackage(
    identityName: appPackageIdentityName,
    publisher: appPublisher,
    familyName: appPackageFamilyName,
    architecture: PackageArchitecture.x64,
    version: MsixVersion(1, 8, 1, 0),
  );

  Future<PackageVerification> verify(
    File file, {
    UpdateTarget? target,
    bool native = false,
    UpdateHelper? helper,
  }) async => ZipUpdatePackageVerifier(helper: helper).verify(
    path: file.path,
    target: target ?? await targetFor(file),
    installed: installed,
    verifyNativeSignature: native,
  );

  test('结构、哈希与身份全部匹配时通过', () async {
    final file = await writePackage();
    final result = await verify(file);
    expect(result.ok, isTrue, reason: '${result.failure?.code}');
    expect(result.identity!.identityName, appPackageIdentityName);
    expect(result.identity!.familyName, appPackageFamilyName);
    expect(result.identity!.version.value, '1.9.0.0');
    expect(result.nativeSignatureVerified, isFalse);
  });

  test('大小不符被拒绝', () async {
    final file = await writePackage();
    final target = await targetFor(file);
    final wrong = UpdateTarget(
      version: target.version,
      buildNumber: target.buildNumber,
      tag: target.tag,
      msixVersion: target.msixVersion,
      fileName: target.fileName,
      downloadUrl: target.downloadUrl,
      sizeBytes: target.sizeBytes + 1,
      sha256: target.sha256,
      manifestDigest: target.manifestDigest,
      keyId: target.keyId,
    );
    final result = await verify(file, target: wrong);
    expect(result.failure!.code, UpdateFailureCode.downloadSizeMismatch);
  });

  test('SHA-256 不符被拒绝', () async {
    final file = await writePackage();
    final target = await targetFor(file, sha256Override: '0' * 64);
    final result = await verify(file, target: target);
    expect(result.failure!.code, UpdateFailureCode.downloadHashMismatch);
  });

  test('缺少 AppxSignature.p7x 时拒绝', () async {
    final file = await writePackage(includeSignature: false);
    final result = await verify(file);
    expect(result.failure!.code, UpdateFailureCode.packageSignatureMissing);
  });

  test('缺少 AppxManifest.xml 时拒绝', () async {
    final file = await writePackage(includeManifest: false);
    final result = await verify(file);
    expect(result.failure!.code, UpdateFailureCode.packageFormatInvalid);
  });

  test('Publisher 与当前版本不一致时拒绝', () async {
    final file = await writePackage(publisher: 'CN=Someone Else');
    final result = await verify(file);
    expect(result.failure!.code, UpdateFailureCode.packagePublisherMismatch);
  });

  test('包身份名不一致时拒绝', () async {
    final file = await writePackage(identityName: 'Other.App');
    final result = await verify(file);
    expect(result.failure!.code, UpdateFailureCode.packageIdentityMismatch);
  });

  test('架构不是 x64 时拒绝', () async {
    final file = await writePackage(architecture: 'arm64');
    final result = await verify(file);
    expect(result.failure!.code, UpdateFailureCode.packageArchMismatch);
  });

  test('包内部版本与清单目标不一致时拒绝', () async {
    final file = await writePackage(version: '1.9.1.0');
    final result = await verify(file);
    expect(result.failure!.code, UpdateFailureCode.packageVersionMismatch);
  });

  test('目标版本与已安装版本相同时拒绝', () async {
    final file = await writePackage(version: '1.8.1.0');
    final target = await targetFor(
      file,
      version: const MsixVersion(1, 8, 1, 0),
    );
    final result = await verify(file, target: target);
    expect(result.failure!.code, UpdateFailureCode.packageVersionSame);
  });

  test('目标版本低于已安装版本时拒绝', () async {
    final file = await writePackage(version: '1.8.0.0');
    final target = await targetFor(
      file,
      version: const MsixVersion(1, 8, 0, 0),
    );
    final result = await verify(file, target: target);
    expect(result.failure!.code, UpdateFailureCode.packageDowngradeBlocked);
  });

  test('要求原生验证但没有助手时拒绝，而不是跳过', () async {
    final file = await writePackage();
    final result = await verify(file, native: true);
    expect(result.failure!.code, UpdateFailureCode.helperMissing);
  });

  test('要求原生验证时由助手做第二次验证', () async {
    final file = await writePackage();
    final helper = _FakeHelper();
    final result = await verify(file, native: true, helper: helper);
    expect(result.ok, isTrue, reason: '${result.failure?.code}');
    expect(helper.verifiedPaths, [file.path]);
    expect(result.nativeSignatureVerified, isTrue);
  });

  test('助手判定签名无效时整体失败', () async {
    final file = await writePackage();
    final helper = _FakeHelper(
      failure: const UpdateFailure(UpdateFailureCode.packageSignatureInvalid),
    );
    final result = await verify(file, native: true, helper: helper);
    expect(result.failure!.code, UpdateFailureCode.packageSignatureInvalid);
  });
}

final class _FakeHelper implements UpdateHelper {
  _FakeHelper({this.failure});

  final UpdateFailure? failure;
  final List<String> verifiedPaths = [];

  @override
  Future<HelperProbe?> probe() async => null;

  @override
  Future<PackageVerification> verifyPackage({required String path}) async {
    verifiedPaths.add(path);
    final failure = this.failure;
    if (failure != null) return PackageVerification.invalid(failure);
    return PackageVerification.valid(
      path: path,
      sizeBytes: 1,
      sha256: 'a' * 64,
      identity: null,
      nativeSignatureVerified: true,
    );
  }

  @override
  Future<HelperLaunchResult> launch(UpdateHelperRequest request) async =>
      const HelperLaunchResult.started();
}

String _manifestXml({
  required String name,
  required String publisher,
  required String version,
  required String architecture,
}) =>
    '''<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="$name" Publisher="$publisher" Version="$version" ProcessorArchitecture="$architecture" />
  <Properties><DisplayName>优计主义</DisplayName></Properties>
</Package>''';
