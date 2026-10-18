// 回退基线的建立与校验（规格 §13.3 / UPD-038 的前置条件）。
//
// 1.9.0 手动安装之后，客户端必须通过**指定版本的不可变清单**下载自己的正式 MSIX，建立
// "当前稳定版本的回退包"。基线完成前允许下载新版本，但**禁止安装**——否则一旦新版启动失败，
// 没有可回退的包。
//
// 基线只使用不涉及业务数据的公开产物：
//   1. 取 `v{当前版本}/update-manifest.json`（不可变）；
//   2. 下载其中的 MSIX；
//   3. 校验大小、SHA-256 与包身份（目标版本等于当前版本是被允许的，这是基线而不是升级）。
import 'dart:io';

import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/rollback_baseline.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

final class UpdateBaselineResult {
  const UpdateBaselineResult({this.baseline, this.failure});

  final RollbackBaseline? baseline;
  final String? failure;

  bool get ok => baseline != null;
}

final class UpdateBaselineService {
  UpdateBaselineService({
    required this.layout,
    required this.manifestSource,
    required this.downloader,
    required this.verifier,
    required this.clock,
  });

  final UpdateStorageLayout layout;
  final UpdateManifestSource manifestSource;
  final UpdatePackageDownloader downloader;
  final UpdatePackageVerifier verifier;
  final Clock clock;

  /// 若已有可用基线则直接返回；否则尝试建立。失败返回原因，不抛异常。
  Future<UpdateBaselineResult> ensureBaseline({
    required InstalledPackage installed,
    required UpdateState state,
  }) async {
    final existing = state.baseline;
    if (existing != null && await _isUsable(existing)) {
      return UpdateBaselineResult(baseline: existing);
    }

    final tag = 'v${installed.version.semanticLabel}';
    final fetched = await manifestSource.fetchForTag(tag);
    final verified = fetched.verified;
    if (verified == null || fetched.failure != null) {
      return UpdateBaselineResult(
        failure: fetched.failure?.code.code ?? 'UPDATE_MANIFEST_EMPTY',
      );
    }
    final manifest = verified.manifest;
    if (manifest.msixVersion != installed.version) {
      return const UpdateBaselineResult(
        failure: 'UPDATE_MANIFEST_VERSION_INCONSISTENT',
      );
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
        failure: outcome.failure?.code.code ?? 'UPDATE_DOWNLOAD_RETRY_EXHAUSTED',
      );
    }

    // 基线是"当前版本自己"，因此用 0.0.0.0 作为比较基准，避开"版本相同"的拒绝。
    final verification = await verifier.verify(
      path: baselineFile.path,
      target: target,
      installed: InstalledPackage(
        identityName: installed.identityName,
        publisher: installed.publisher,
        familyName: installed.familyName,
        architecture: installed.architecture,
        version: const MsixVersion(0, 0, 0, 0),
      ),
      verifyNativeSignature: true,
    );
    if (!verification.ok) {
      try {
        if (await baselineFile.exists()) await baselineFile.delete();
      } on Object {
        // 忽略：下次会重新下载。
      }
      return UpdateBaselineResult(
        failure: verification.failure?.code.code ?? 'UPDATE_PACKAGE_FORMAT_INVALID',
      );
    }

    final baseline = RollbackBaseline(
      version: installed.version,
      packagePath: baselineFile.path,
      sha256: target.sha256,
      sizeBytes: target.sizeBytes,
      createdAtUtc: clock.nowUtc(),
      snapshotPath: state.snapshotPath,
    );
    return UpdateBaselineResult(baseline: baseline);
  }

  Future<bool> _isUsable(RollbackBaseline baseline) async {
    try {
      final file = File(baseline.packagePath);
      if (!await file.exists()) return false;
      if (await file.length() != baseline.sizeBytes) return false;
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
