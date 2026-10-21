// 触发器矩阵与 single-flight（1.11.1 修复 §7 / Task 7）。
//
// 事故里"回退基线未就绪"会永久残留，是因为只有一个入口（启动 + 自动更新开启）会建基线，
// 而失败后又没有可观察的重试。这里逐行验证触发矩阵：开关、手动检查、下载、点击安装、
// 用户重试都必须到达**同一个** single-flight 任务。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/rollback_baseline.dart';
import 'package:personal_planner/domain/update/update_baseline_status.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_settings.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_doubles.dart';
import '../../support/update_fixtures.dart';

const InstalledPackage _installed = InstalledPackage(
  identityName: appPackageIdentityName,
  publisher: appPublisher,
  familyName: appPackageFamilyName,
  architecture: PackageArchitecture.x64,
  version: MsixVersion(1, 10, 2, 0),
);

final RollbackBaseline _baseline = RollbackBaseline(
  version: _installed.version,
  packagePath: 'C:/Updates/baseline/BestPlanning_1.10.2.0_x64.msix',
  sha256: testPackageSha256,
  sizeBytes: 2048,
  createdAtUtc: DateTime.utc(2026, 10, 20),
);

void main() {
  late Directory directory;
  late UpdateStorageLayout layout;
  late InMemoryUpdateSafetyCoordinator safety;
  late FakeInstallCoordinator coordinator;
  late MemoryLogSink log;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_controller_test_');
    layout = UpdateStorageLayout(root: directory);
    safety = InMemoryUpdateSafetyCoordinator();
    coordinator = FakeInstallCoordinator();
    log = MemoryLogSink();
  });

  tearDown(() {
    safety.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  UpdateOrchestrator buildOrchestrator({
    required ManifestFetchResult fetchResult,
    UpdateBaselinePreparer? baseline,
    InMemoryStateStore? store,
  }) => UpdateOrchestrator(
    manifestSource: FakeManifestSource(fetchResult),
    stateStore: store ?? InMemoryStateStore(),
    installedPackages: FakeInstalledPackages(_installed),
    downloader: FakeDownloader(),
    verifier: FakeVerifier(),
    layout: layout,
    safety: safety,
    log: log,
    clock: FakeClock(),
    diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    installCoordinator: coordinator,
    baselineService: baseline,
  );

  Future<UpdateController> buildController({
    required ManifestFetchResult fetchResult,
    UpdateBaselinePreparer? baseline,
    InMemoryStateStore? store,
    UpdateSettingsStore? settings,
  }) async {
    final controller = UpdateController(
      orchestrator: buildOrchestrator(
        fetchResult: fetchResult,
        baseline: baseline,
        store: store,
      ),
      settings: settings ?? _MemorySettings(),
      safety: safety,
    );
    await controller.initialize();
    return controller;
  }

  test('自动更新从关改为开：立即触发基线准备，无需重启', () async {
    final baseline = CountingBaselineFake(baseline: _baseline);
    final settings = _MemorySettings(
      const UpdateSettings(autoUpdateEnabled: false),
    );
    final controller = await buildController(
      fetchResult: networkFailureFixture(),
      baseline: baseline,
      settings: settings,
    );
    expect(baseline.calls, 0);

    await controller.setAutoUpdateEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(baseline.calls, 1);
    expect(controller.state.baselinePreparation.phase, BaselinePhase.ready);
  });

  test('自动更新从开改为关不触发基线', () async {
    final baseline = CountingBaselineFake(baseline: _baseline);
    final controller = await buildController(
      fetchResult: networkFailureFixture(),
      baseline: baseline,
    );
    expect(baseline.calls, 0);

    await controller.setAutoUpdateEnabled(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(baseline.calls, 0);
  });

  test('手动检查也触发基线（不等待完成）', () async {
    final baseline = CountingBaselineFake(baseline: _baseline);
    final controller = await buildController(
      fetchResult: networkFailureFixture(),
      baseline: baseline,
    );

    await controller.checkNow();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(baseline.calls, 1);
  });

  test('手动下载目标版本也触发基线', () async {
    final baseline = CountingBaselineFake(baseline: _baseline);
    final verified = await verifiedManifestFixture(
      version: '1.11.0',
      buildNumber: 52,
    );
    final controller = await buildController(
      fetchResult: ManifestFetchResult.verified(verified),
      baseline: baseline,
    );

    await controller.downloadManually();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(baseline.calls, 1);
  });

  test('多入口并发调用只产生一个真实基线任务（INV-07）', () async {
    final baseline = CountingBaselineFake(
      baseline: _baseline,
      delay: const Duration(milliseconds: 40),
    );
    final controller = await buildController(
      fetchResult: networkFailureFixture(),
      baseline: baseline,
    );

    await Future.wait([
      controller.ensureBaseline(),
      controller.ensureBaseline(),
      controller.retryBaseline(),
      controller.orchestrator.ensureRollbackBaseline(),
    ]);

    expect(baseline.calls, 1);
  });

  test('点击安装时基线未就绪：先补建基线，成功后继续安装', () async {
    final verified = await verifiedManifestFixture(
      version: '1.11.0',
      buildNumber: 52,
    );
    final ready = layout.readyPackage(_targetFrom(verified));
    await ready.parent.create(recursive: true);
    await ready.writeAsBytes(List<int>.filled(2048, 0));
    final baseline = CountingBaselineFake(baseline: _baseline);
    final store = InMemoryStateStore(
      UpdateState(
        phase: UpdatePhase.ready,
        currentMsixVersion: _installed.version,
        target: _targetFrom(verified),
        receivedBytes: 2048,
        totalBytes: 2048,
      ),
    );
    final controller = await buildController(
      fetchResult: ManifestFetchResult.verified(verified),
      baseline: baseline,
      store: store,
    );

    await controller.install();

    expect(baseline.calls, 1, reason: '安装入口必须主动补建基线（UPD-INC-008）');
    expect(coordinator.prepareCalls, 1, reason: '基线就绪后继续安装');
    expect(coordinator.exitCalls, 1);
    expect(safety.status.canInstall, isTrue);
  });

  test('基线补建失败：停留在 ready 并显示可重试的阻塞', () async {
    final verified = await verifiedManifestFixture(
      version: '1.11.0',
      buildNumber: 52,
    );
    final ready = layout.readyPackage(_targetFrom(verified));
    await ready.parent.create(recursive: true);
    await ready.writeAsBytes(List<int>.filled(2048, 0));
    final baseline = CountingBaselineFake(
      failure: const UpdateFailure(UpdateFailureCode.networkOffline),
    );
    final store = InMemoryStateStore(
      UpdateState(
        phase: UpdatePhase.ready,
        currentMsixVersion: _installed.version,
        target: _targetFrom(verified),
        receivedBytes: 2048,
        totalBytes: 2048,
      ),
    );
    final controller = await buildController(
      fetchResult: ManifestFetchResult.verified(verified),
      baseline: baseline,
      store: store,
    );

    await controller.install();

    expect(coordinator.prepareCalls, 0, reason: '基线未就绪不得启动助手');
    expect(controller.state.phase, UpdatePhase.ready);
    expect(
      controller.state.lastFailure!.code,
      UpdateFailureCode.blockedRollbackNotReady,
    );
    expect(
      controller.state.baselinePreparation.phase,
      BaselinePhase.retryWaiting,
    );
    expect(safety.status.canInstall, isFalse);
    expect(
      controller.state.baselinePreparation.nextAttemptUtc,
      isNotNull,
      reason: '失败必须带可观察的退避计划（INV-08）',
    );
  });

  test('基线成功后清除历史 blocker 与旧失败', () async {
    final store = InMemoryStateStore(
      const UpdateState(
        phase: UpdatePhase.ready,
        lastFailure: UpdateFailure(UpdateFailureCode.blockedRollbackNotReady),
      ),
    );
    final baseline = CountingBaselineFake(baseline: _baseline);
    final controller = await buildController(
      fetchResult: networkFailureFixture(),
      baseline: baseline,
      store: store,
    );
    safety.setRollbackNotReady(true);

    await controller.ensureBaseline();

    expect(controller.state.baseline!.version.value, '1.10.2.0');
    expect(controller.state.baselinePreparation.phase, BaselinePhase.ready);
    expect(controller.state.lastFailure, isNull);
    expect(safety.status.canInstall, isTrue);
  });
}

UpdateTarget _targetFrom(VerifiedManifest verified) {
  final m = verified.manifest;
  return UpdateTarget(
    version: m.release.version,
    buildNumber: m.release.buildNumber,
    tag: m.tag,
    msixVersion: m.msixVersion,
    fileName: m.package.fileName,
    downloadUrl: m.package.downloadUrl,
    sizeBytes: m.package.sizeBytes,
    sha256: m.package.sha256,
    manifestDigest: verified.canonicalDigest,
    keyId: m.signature.keyId,
  );
}

final class _MemorySettings implements UpdateSettingsStore {
  _MemorySettings([this.value = const UpdateSettings()]);

  UpdateSettings value;

  @override
  Future<UpdateSettings> load() async => value;

  @override
  Future<void> save(UpdateSettings settings) async {
    value = settings;
  }
}
