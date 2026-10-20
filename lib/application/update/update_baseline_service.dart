// 回退基线的建立与校验（规格 §13.3 / UPD-038 的前置条件；1.11.1 修复 §4.4 / §6）。
//
// 基线是"当前已安装版本的正式回退包"。它必须**可观察、可重试、可严格校验**：
//   · 复用已有基线时与新建时走**同一个** `validate()`（INV-06），不再"只查存在与长度"；
//   · 失败返回结构化错误码，由编排器持久化成独立的基线准备状态并安排退避；
//   · 下载前先算磁盘预算，空间不足是可重试失败，**不删除**已就绪的目标包；
//   · 基线对象不再声称持有数据快照：快照属于具体安装事务（UPD-INC-020）。
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/rollback_baseline.dart';
import 'package:personal_planner/domain/update/update_baseline_status.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

/// 基线下载前的磁盘预算：基线包本体 + 可能的 partial 增长 + 原子替换余量 + 快照预留。
int baselineDiskRequirementBytes(
  int packageBytes, {
  int snapshotReserveBytes = 0,
}) => packageBytes * 2 + 1024 * 1024 + snapshotReserveBytes;

final class UpdateBaselineService implements UpdateBaselinePreparer {
  UpdateBaselineService({
    required this.layout,
    required this.manifestSource,
    required this.downloader,
    required this.verifier,
    required this.clock,
    this.diskSpace,
    this.snapshotReserveBytes = 0,
    this.verifyNativeSignature = true,
  });

  final UpdateStorageLayout layout;
  final UpdateManifestSource manifestSource;
  final UpdatePackageDownloader downloader;
  final UpdatePackageVerifier verifier;
  final Clock clock;
  final DiskSpaceProbe? diskSpace;
  final int snapshotReserveBytes;

  /// 是否要求 Windows 原生签名验证。
  ///
  /// 生产装配了助手时为 `true`（默认）；未装配助手的开发/诊断环境没有这项能力，
  /// 但长度、SHA-256、ZIP 结构与包身份/发布者仍然照常校验。
  final bool verifyNativeSignature;

  /// 若已有可用基线则直接返回；否则尝试建立。失败返回结构化原因，不抛异常。
  @override
  Future<UpdateBaselineResult> ensureBaseline({
    required InstalledPackage installed,
    required UpdateState state,
  }) async {
    final existing = state.baseline;
    if (existing != null && existing.version == installed.version) {
      final validation = await validate(
        installed: installed,
        baseline: existing,
      );
      if (validation.usable) {
        return UpdateBaselineResult(baseline: existing);
      }
      // 已有基线不可用：只删除**受控路径内**的那份坏文件，然后重建。
      await _deleteIfControlled(existing.packagePath);
    }

    final tag = 'v${installed.version.semanticLabel}';
    final fetched = await manifestSource.fetchForTag(tag);
    final verified = fetched.verified;
    if (verified == null || fetched.failure != null) {
      return UpdateBaselineResult(
        failure:
            fetched.failure ??
            const UpdateFailure(UpdateFailureCode.manifestEmpty),
      );
    }
    final manifest = verified.manifest;
    if (manifest.msixVersion != installed.version) {
      return const UpdateBaselineResult(
        failure: UpdateFailure(
          UpdateFailureCode.manifestVersionInconsistent,
          detail: 'baseline_manifest_version_mismatch',
        ),
      );
    }
    if (!manifest.compatibility.matchesClient) {
      return const UpdateBaselineResult(
        failure: UpdateFailure(UpdateFailureCode.packageIdentityMismatch),
      );
    }
    if (manifest.isRevoked) {
      return const UpdateBaselineResult(
        failure: UpdateFailure(UpdateFailureCode.packageVersionRevoked),
      );
    }

    // 磁盘预算：空间不足是可重试失败，不触碰任何已验证文件。
    final probe = diskSpace;
    if (probe != null) {
      final available = await probe.availableBytes(
        layout.baselineDirectory.path,
      );
      final required = baselineDiskRequirementBytes(
        manifest.package.sizeBytes,
        snapshotReserveBytes: snapshotReserveBytes,
      );
      if (available != null && available < required) {
        return UpdateBaselineResult(
          failure: UpdateFailure(
            UpdateFailureCode.blockedDiskSpaceLow,
            detail: 'available=$available required=$required',
          ),
        );
      }
    }

    final target = UpdateTarget(
      version: manifest.release.version,
      buildNumber: manifest.release.buildNumber,
      tag: manifest.tag,
      msixVersion: manifest.msixVersion,
      fileName: manifest.package.fileName,
      downloadUrl: manifest.package.downloadUrl,
      sizeBytes: manifest.package.sizeBytes,
      sha256: manifest.package.sha256,
      manifestDigest: verified.canonicalDigest,
      keyId: manifest.signature.keyId,
    );
    final baselineFile = layout.baselinePackage(installed.version);
    await baselineFile.parent.create(recursive: true);
    final partial = File('${baselineFile.path}.partial');
    final outcome = await downloader.download(
      target: target,
      partialPath: partial.path,
      readyPath: baselineFile.path,
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );
    if (!outcome.isSuccess) {
      return UpdateBaselineResult(
        failure:
            outcome.failure ??
            const UpdateFailure(UpdateFailureCode.downloadRetryExhausted),
      );
    }

    final baseline = RollbackBaseline(
      version: installed.version,
      packagePath: baselineFile.path,
      sha256: target.sha256,
      sizeBytes: target.sizeBytes,
      createdAtUtc: clock.nowUtc(),
    );
    final validation = await validate(installed: installed, baseline: baseline);
    if (!validation.usable) {
      await _deleteIfControlled(baselineFile.path);
      return UpdateBaselineResult(
        failure:
            validation.failure ??
            const UpdateFailure(UpdateFailureCode.packageFormatInvalid),
      );
    }
    return UpdateBaselineResult(baseline: baseline);
  }

  /// **唯一**的基线校验入口（INV-06）。建立与复用、安装前置条件都调用它。
  @override
  Future<BaselineValidationResult> validate({
    required InstalledPackage installed,
    required RollbackBaseline baseline,
  }) async {
    if (baseline.version != installed.version) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(
          UpdateFailureCode.packageVersionMismatch,
          detail: 'baseline_version_not_installed',
        ),
      );
    }
    final path = baseline.packagePath;
    final normalizedPath = path.isEmpty
        ? ''
        : UpdateStorageLayout.normalize(path);
    final baselineRoot = UpdateStorageLayout.normalize(
      layout.baselineDirectory.path,
    );
    if (path.isEmpty ||
        !layout.containsPath(path) ||
        !normalizedPath.startsWith('$baselineRoot${Platform.pathSeparator}')) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(
          UpdateFailureCode.rollbackPackageInvalid,
          detail: 'path_outside_baseline_directory',
        ),
      );
    }
    final file = File(path);
    final FileSystemEntityType type;
    try {
      type = await FileSystemEntity.type(path, followLinks: false);
    } on FileSystemException {
      return const BaselineValidationResult.invalid(
        UpdateFailure(UpdateFailureCode.rollbackPackageInvalid),
      );
    }
    if (type == FileSystemEntityType.notFound) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(UpdateFailureCode.rollbackPackageMissing),
      );
    }
    // 符号链接/目录都不接受：它们可以让"受控路径"指向别处。
    if (type != FileSystemEntityType.file) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(
          UpdateFailureCode.rollbackPackageInvalid,
          detail: 'not_a_regular_file',
        ),
      );
    }

    final int length;
    try {
      length = await file.length();
    } on FileSystemException {
      return const BaselineValidationResult.invalid(
        UpdateFailure(UpdateFailureCode.rollbackPackageInvalid),
      );
    }
    if (length != baseline.sizeBytes) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(
          UpdateFailureCode.rollbackPackageInvalid,
          detail: 'length_mismatch',
        ),
      );
    }

    // 长度相同但内容不同的基线必须在**密码学**层面被拒绝（UPD-INC-010）。
    final verification = await verifier.verifyBaseline(
      path: path,
      expectedVersion: baseline.version,
      expectedSizeBytes: baseline.sizeBytes,
      expectedSha256: baseline.sha256,
      verifyNativeSignature: verifyNativeSignature,
    );
    if (!verification.ok) {
      final failure =
          verification.failure ??
          const UpdateFailure(UpdateFailureCode.rollbackPackageInvalid);
      return BaselineValidationResult.invalid(failure);
    }
    final identity = verification.identity;
    if (identity == null) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(UpdateFailureCode.rollbackPackageInvalid),
      );
    }
    if (identity.version != installed.version) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(
          UpdateFailureCode.packageVersionMismatch,
          detail: 'package_version_not_installed',
        ),
      );
    }
    if (identity.identityName != installed.identityName) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(UpdateFailureCode.packageIdentityMismatch),
      );
    }
    if (identity.familyName != installed.familyName) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(UpdateFailureCode.packageFamilyMismatch),
      );
    }
    if (normalizePublisher(identity.publisher) !=
        normalizePublisher(installed.publisher)) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(UpdateFailureCode.packagePublisherMismatch),
      );
    }
    if (identity.architecture != installed.architecture) {
      return const BaselineValidationResult.invalid(
        UpdateFailure(UpdateFailureCode.packageArchMismatch),
      );
    }
    return BaselineValidationResult.valid(identity: identity);
  }

  /// 计算文件 SHA-256（诊断与测试用，不参与信任判断）。
  Future<String?> sha256Of(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return (await sha256.bind(file.openRead()).first).toString();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _deleteIfControlled(String path) async {
    if (path.isEmpty || !layout.containsPath(path)) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // 删不掉时保留文件：下一次校验仍会失败，不会误装。
    }
  }
}
