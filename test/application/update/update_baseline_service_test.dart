// 回退基线（UPD-038 的前置条件 / 规格 §13.3；1.11.1 修复 §4.4 / §6）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_baseline_service.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/rollback_baseline.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_doubles.dart';
import '../../support/update_fixtures.dart';

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

    expect(result.ok, isTrue, reason: result.failure?.code.code);
    final baseline = result.baseline!;
    expect(baseline.version.value, '1.8.1.0');
    expect(
      baseline.packagePath,
      layout.baselinePackage(installedFixture.version).path,
    );
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
    expect(result.failure!.code, UpdateFailureCode.networkOffline);
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
    expect(result.failure!.code, UpdateFailureCode.downloadHashMismatch);
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
    expect(result.failure!.code, UpdateFailureCode.packageSignatureInvalid);
    expect(
      await layout.baselinePackage(installedFixture.version).exists(),
      isFalse,
    );
  });

  group('严格校验（INV-06 / UPD-INC-010～012）', () {
    Future<UpdateBaselineService> build({
      required ManifestFetchResult result,
      required UpdatePackageDownloader downloader,
      UpdatePackageVerifier? verifier,
      DiskSpaceProbe? diskSpace,
    }) async => UpdateBaselineService(
      layout: layout,
      manifestSource: FakeManifestSource(result),
      downloader: downloader,
      verifier: verifier ?? FakeVerifier(),
      clock: FakeClock(),
      diskSpace: diskSpace,
    );

    RollbackBaseline baselineAt(String path, {int sizeBytes = 2048}) =>
        RollbackBaseline(
          version: installedFixture.version,
          packagePath: path,
          sha256: testPackageSha256,
          sizeBytes: sizeBytes,
          createdAtUtc: DateTime.utc(2026, 10, 18),
        );

    test('同长度但 SHA 错误的基线被拒绝并重建', () async {
      final file = layout.baselinePackage(installedFixture.version);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(2048, 0));
      final existing = baselineAt(file.path);
      final verifier = _ScriptedVerifier([
        const PackageVerification.invalid(
          UpdateFailure(UpdateFailureCode.downloadHashMismatch),
        ),
        PackageVerification.valid(
          path: file.path,
          sizeBytes: 2048,
          sha256: testPackageSha256,
          identity: installedFixture,
        ),
      ]);
      final downloader = _WritingDownloader();
      final service = await build(
        result: ManifestFetchResult.verified(
          await verifiedManifestFixture(version: '1.8.1'),
        ),
        downloader: downloader,
        verifier: verifier,
      );

      final result = await service.ensureBaseline(
        installed: installedFixture,
        state: UpdateState(phase: UpdatePhase.idle, baseline: existing),
      );

      expect(result.ok, isTrue);
      expect(verifier.baselineCalls, 2, reason: '旧基线被拒绝后才重新建立');
      expect(downloader.calls, 1);
      expect(await file.exists(), isTrue);
    });

    test('SHA 对但包版本不等于已安装版本被拒绝', () async {
      final file = layout.baselinePackage(installedFixture.version);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(2048, 0));
      final service = await build(
        result: networkFailureFixture(),
        downloader: _WritingDownloader(),
        verifier: FakeVerifier(
          baselineIdentity: const InstalledPackage(
            identityName: appPackageIdentityName,
            publisher: appPublisher,
            familyName: appPackageFamilyName,
            architecture: PackageArchitecture.x64,
            version: MsixVersion(1, 9, 0, 0),
          ),
        ),
      );

      final validation = await service.validate(
        installed: installedFixture,
        baseline: baselineAt(file.path),
      );

      expect(validation.usable, isFalse);
      expect(
        validation.failure!.code,
        UpdateFailureCode.packageVersionMismatch,
      );
    });

    test('Publisher 不同被拒绝', () async {
      final file = layout.baselinePackage(installedFixture.version);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(2048, 0));
      final service = await build(
        result: networkFailureFixture(),
        downloader: _WritingDownloader(),
        verifier: FakeVerifier(
          baselineIdentity: const InstalledPackage(
            identityName: appPackageIdentityName,
            publisher: 'CN=Other Publisher, C=CN',
            familyName: appPackageFamilyName,
            architecture: PackageArchitecture.x64,
            version: MsixVersion(1, 8, 1, 0),
          ),
        ),
      );

      final validation = await service.validate(
        installed: installedFixture,
        baseline: baselineAt(file.path),
      );

      expect(validation.usable, isFalse);
      expect(
        validation.failure!.code,
        UpdateFailureCode.packagePublisherMismatch,
      );
    });

    test('基线位于基线目录之外被拒绝', () async {
      final outside = File(
        '${directory.parent.path}${Platform.pathSeparator}outside.msix',
      );
      await outside.writeAsBytes(List<int>.filled(2048, 0));
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync();
      });
      final service = await build(
        result: networkFailureFixture(),
        downloader: _WritingDownloader(),
      );

      final validation = await service.validate(
        installed: installedFixture,
        baseline: baselineAt(outside.path),
      );

      expect(validation.usable, isFalse);
      expect(
        validation.failure!.code,
        UpdateFailureCode.rollbackPackageInvalid,
      );
    });

    test('空间不足是可重试失败，且不删除已就绪的目标包', () async {
      final targetReady = File(
        '${layout.versionDirectory(const MsixVersion(1, 9, 0, 0)).path}'
        '${Platform.pathSeparator}package.msix.ready',
      );
      await targetReady.parent.create(recursive: true);
      await targetReady.writeAsBytes(List<int>.filled(2048, 0));
      final downloader = _WritingDownloader();
      final service = await build(
        result: ManifestFetchResult.verified(
          await verifiedManifestFixture(version: '1.8.1'),
        ),
        downloader: downloader,
        diskSpace: FakeDiskSpace(0),
      );

      final result = await service.ensureBaseline(
        installed: installedFixture,
        state: const UpdateState(phase: UpdatePhase.idle),
      );

      expect(result.ok, isFalse);
      expect(result.failure!.code, UpdateFailureCode.blockedDiskSpaceLow);
      expect(result.failure!.retryable, isTrue);
      expect(downloader.calls, 0, reason: '空间不足不能开始下载');
      expect(await targetReady.exists(), isTrue, reason: '不得删除目标 ready');
    });

    test('安装前常量被篡改时再次被发现', () async {
      final file = layout.baselinePackage(installedFixture.version);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(2048, 0));
      final service = await build(
        result: networkFailureFixture(),
        downloader: _WritingDownloader(),
      );
      final baseline = baselineAt(file.path);
      expect(
        (await service.validate(
          installed: installedFixture,
          baseline: baseline,
        )).usable,
        isTrue,
      );

      // 篡改成同长度的另一份内容：严格校验必须发现。
      await file.writeAsBytes(List<int>.filled(2048, 9));
      final tampered = await build(
        result: networkFailureFixture(),
        downloader: _WritingDownloader(),
        verifier: FakeVerifier(
          onVerifyBaseline: () => const PackageVerification.invalid(
            UpdateFailure(UpdateFailureCode.downloadHashMismatch),
          ),
        ),
      );
      final validation = await tampered.validate(
        installed: installedFixture,
        baseline: baseline,
      );
      expect(validation.usable, isFalse);
      expect(validation.failure!.code, UpdateFailureCode.downloadHashMismatch);
    });

    test('基线对象不再假装持有数据快照', () {
      final json = RollbackBaseline(
        version: installedFixture.version,
        packagePath: 'C:/Updates/baseline/pkg.msix',
        sha256: testPackageSha256,
        sizeBytes: 2048,
        createdAtUtc: DateTime.utc(2026, 10, 18),
      ).toJson();
      expect(json.containsKey('snapshotPath'), isFalse);
      expect(json.containsKey('snapshotSha256'), isFalse);
    });
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

/// 按顺序返回验证结论的替身：用来表达"旧基线坏、新基线好"。
final class _ScriptedVerifier implements UpdatePackageVerifier {
  _ScriptedVerifier(this._results);

  final List<PackageVerification> _results;
  int baselineCalls = 0;

  @override
  Future<PackageVerification> verify({
    required String path,
    required UpdateTarget target,
    required InstalledPackage installed,
    required bool verifyNativeSignature,
  }) async => _results.last;

  @override
  Future<PackageVerification> verifyBaseline({
    required String path,
    required MsixVersion expectedVersion,
    required int expectedSizeBytes,
    required String expectedSha256,
    required bool verifyNativeSignature,
  }) async {
    final index = baselineCalls.clamp(0, _results.length - 1);
    baselineCalls++;
    return _results[index];
  }
}
