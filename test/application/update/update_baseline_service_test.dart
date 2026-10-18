// 回退基线（UPD-038 的前置条件 / 规格 §13.3）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_baseline_service.dart';
import 'package:personal_planner/domain/update/rollback_baseline.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_doubles.dart';

void main() {
  late Directory directory;
  late UpdateStorageLayout layout;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_baseline_test_');
    layout = UpdateStorageLayout(root: directory);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<UpdateBaselineService> buildService({
    required ManifestFetchResult result,
    required UpdatePackageDownloader downloader,
    UpdatePackageVerifier? verifier,
  }) async => UpdateBaselineService(
    layout: layout,
    manifestSource: FakeManifestSource(result),
    downloader: downloader,
    verifier: verifier ?? FakeVerifier(),
    clock: FakeClock(),
  );

  test('按当前版本的不可变清单下载并建立基线', () async {
    final verified = await verifiedManifestFixture(version: '1.8.1');
    final downloader = _WritingDownloader();
    final service = await buildService(
      result: ManifestFetchResult.verified(verified),
      downloader: downloader,
    );

    final result = await service.ensureBaseline(
      installed: installedFixture,
      state: const UpdateState(phase: UpdatePhase.idle),
    );

    expect(result.ok, isTrue, reason: result.failure);
    final baseline = result.baseline!;
    expect(baseline.version.value, '1.8.1.0');
    expect(baseline.packagePath, layout.baselinePackage(installedFixture.version).path);
    expect(baseline.sha256, hasLength(64));
    expect(await File(baseline.packagePath).exists(), isTrue);
    expect(downloader.calls, 1);
  });

  test('已有可用基线时不再下载', () async {
    final file = layout.baselinePackage(installedFixture.version);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(2048, 0));
    final baseline = RollbackBaseline(
      version: installedFixture.version,
      packagePath: file.path,
      sha256: 'a' * 64,
      sizeBytes: 2048,
      createdAtUtc: DateTime.utc(2026, 10, 18),
    );
    final downloader = _WritingDownloader();
    final service = await buildService(
      result: networkFailureFixture(),
      downloader: downloader,
    );

    final result = await service.ensureBaseline(
      installed: installedFixture,
      state: UpdateState(phase: UpdatePhase.idle, baseline: baseline),
    );

    expect(result.ok, isTrue);
    expect(downloader.calls, 0);
  });

  test('清单获取失败时不产生基线', () async {
    final service = await buildService(
      result: networkFailureFixture(),
      downloader: _WritingDownloader(),
    );

    final result = await service.ensureBaseline(
      installed: installedFixture,
      state: const UpdateState(phase: UpdatePhase.idle),
    );

    expect(result.ok, isFalse);
    expect(result.failure, UpdateFailureCode.networkOffline.code);
  });

  test('下载失败时不产生基线', () async {
    final verified = await verifiedManifestFixture(version: '1.8.1');
    final service = await buildService(
      result: ManifestFetchResult.verified(verified),
      downloader: _FailingDownloader(),
    );

    final result = await service.ensureBaseline(
      installed: installedFixture,
      state: const UpdateState(phase: UpdatePhase.idle),
    );

    expect(result.ok, isFalse);
    expect(result.failure, UpdateFailureCode.downloadHashMismatch.code);
  });

  test('包验证失败时删除半成品', () async {
    final verified = await verifiedManifestFixture(version: '1.8.1');
    final service = await buildService(
      result: ManifestFetchResult.verified(verified),
      downloader: _WritingDownloader(),
      verifier: FakeVerifier(
        onVerify: () => const PackageVerification.invalid(
          UpdateFailure(UpdateFailureCode.packageSignatureInvalid),
        ),
      ),
    );

    final result = await service.ensureBaseline(
      installed: installedFixture,
      state: const UpdateState(phase: UpdatePhase.idle),
    );

    expect(result.ok, isFalse);
    expect(result.failure, UpdateFailureCode.packageSignatureInvalid.code);
    expect(
      await layout.baselinePackage(installedFixture.version).exists(),
      isFalse,
    );
  });
}

/// 按下发的目标大小写满文件，模拟一次成功下载。
final class _WritingDownloader implements UpdatePackageDownloader {
  int calls = 0;

  @override
  Future<DownloadOutcome> download({
    required UpdateTarget target,
    required String partialPath,
    required String readyPath,
    String? etag,
    String? lastModified,
    required bool Function() shouldCancel,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
  }) async {
    calls++;
    final file = File(readyPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(target.sizeBytes, 0));
    onProgress(target.sizeBytes, target.sizeBytes);
    return DownloadOutcome.success(
      path: readyPath,
      sizeBytes: target.sizeBytes,
      sha256: target.sha256,
    );
  }
}

final class _FailingDownloader implements UpdatePackageDownloader {
  @override
  Future<DownloadOutcome> download({
    required UpdateTarget target,
    required String partialPath,
    required String readyPath,
    String? etag,
    String? lastModified,
    required bool Function() shouldCancel,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
  }) async => const DownloadOutcome.failed(
    UpdateFailure(UpdateFailureCode.downloadHashMismatch),
  );
}

