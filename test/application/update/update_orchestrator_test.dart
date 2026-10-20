// 编排器：四类结论、状态推进、失败分类与恢复（UPD-004 / UPD-005 / UPD-012 / UPD-025）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_doubles.dart';

void main() {
  late Directory directory;
  late UpdateStorageLayout layout;
  late FakeClock clock;
  late InMemoryStateStore store;
  late InMemoryUpdateSafetyCoordinator safety;
  late MemoryLogSink log;
  late FakeInstalledPackages installed;
  late FakeDownloader downloader;
  late FakeVerifier verifier;

  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'update_orchestrator_test_',
    );
    layout = UpdateStorageLayout(root: directory);
    clock = FakeClock();
    store = InMemoryStateStore();
    safety = InMemoryUpdateSafetyCoordinator();
    log = MemoryLogSink();
    installed = FakeInstalledPackages();
    downloader = FakeDownloader();
    verifier = FakeVerifier();
  });

  tearDown(() {
    safety.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  UpdateOrchestrator build({
    required ManifestFetchResult fetchResult,
    UpdatePackageDownloader? packageDownloader,
    UpdatePackageVerifier? packageVerifier,
    int? availableBytes,
    UpdateInstallCoordinator? installCoordinator,
    UpdateLock? updateLock,
    ProcessIdentityProbe? processProbe,
    UpdateSafetyCoordinator? safetyOverride,
  }) => UpdateOrchestrator(
    manifestSource: FakeManifestSource(fetchResult),
    stateStore: store,
    installedPackages: installed,
    downloader: packageDownloader ?? downloader,
    verifier: packageVerifier ?? verifier,
    layout: layout,
    safety: safetyOverride ?? safety,
    log: log,
    clock: clock,
    diskSpace: FakeDiskSpace(availableBytes ?? 50 * 1024 * 1024 * 1024),
    installCoordinator: installCoordinator,
    updateLock: updateLock,
    processProbe: processProbe,
  );

  test('验证通过且版本更高：进入 updateAvailable，四类结论里只有它不是 upToDate', () async {
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    final result = await orchestrator.check(manual: true, autoDownload: false);

    expect(result.classification, UpdateCheckClassification.updateAvailable);
    expect(result.isConfirmedUpToDate, isFalse);
    expect(orchestrator.state.phase, UpdatePhase.updateAvailable);
    expect(orchestrator.state.target!.msixVersion.value, '1.9.0.0');
    expect(orchestrator.state.lastConfirmedUtc, isNotNull);
  });

  test('验证通过且版本相同：upToDate 是唯一可以显示“已是最新版”的结论', () async {
    final verified = await verifiedManifestFixture(version: '1.8.1');
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    final result = await orchestrator.check(manual: false);

    expect(result.classification, UpdateCheckClassification.upToDate);
    expect(result.isConfirmedUpToDate, isTrue);
    expect(orchestrator.state.phase, UpdatePhase.upToDate);
    expect(orchestrator.state.target, isNull);
  });

  test('网络失败是“暂时无法确认”，绝不会显示已是最新', () async {
    final orchestrator = build(fetchResult: networkFailureFixture());

    final result = await orchestrator.check(manual: false);

    expect(
      result.classification,
      UpdateCheckClassification.temporarilyUnconfirmed,
    );
    expect(result.isConfirmedUpToDate, isFalse);
    expect(orchestrator.state.phase, UpdatePhase.temporarilyBlocked);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.networkOffline,
    );
  });

  test('签名无效是“更新源异常”，不是无更新', () async {
    final orchestrator = build(
      fetchResult: ManifestFetchResult.failed(
        const UpdateFailure(UpdateFailureCode.manifestSignatureInvalid),
      ),
    );

    final result = await orchestrator.check(manual: true);

    expect(result.classification, UpdateCheckClassification.sourceInvalid);
    expect(orchestrator.state.phase, UpdatePhase.failed);
  });

  test('更高版本被撤回时拒绝安装', () async {
    final verified = await verifiedManifestFixture(
      revokedVersions: ['1.9.0.0'],
    );
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    final result = await orchestrator.check(manual: true);

    expect(result.classification, UpdateCheckClassification.sourceInvalid);
    expect(orchestrator.state.phase, UpdatePhase.failed);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.packageVersionRevoked,
    );
  });

  test('清单里的发布者与客户端不一致时拒绝', () async {
    final verified = await verifiedManifestFixture(
      publisher: 'CN=Someone Else',
    );
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    final result = await orchestrator.check(manual: true);

    expect(result.classification, UpdateCheckClassification.sourceInvalid);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.packagePublisherMismatch,
    );
  });

  test('远端版本低于当前版本按降级拒绝', () async {
    final verified = await verifiedManifestFixture(version: '1.8.0');
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    final result = await orchestrator.check(manual: true);

    expect(result.classification, UpdateCheckClassification.sourceInvalid);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.packageDowngradeBlocked,
    );
  });

  test('自动下载：检查完成后直接进入 ready', () async {
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    await orchestrator.check(manual: false, autoDownload: true);

    expect(orchestrator.state.phase, UpdatePhase.ready);
    expect(downloader.calls, 1);
    expect(verifier.calls, 1);
    expect(
      orchestrator.state.receivedBytes,
      orchestrator.state.target!.sizeBytes,
    );
  });

  test('下载失败：进入 failed 并安排退避，而不是假装就绪', () async {
    downloader.outcome = const DownloadOutcome.failed(
      UpdateFailure(UpdateFailureCode.downloadHashMismatch),
    );
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    await orchestrator.check(manual: false, autoDownload: true);

    expect(orchestrator.state.phase, UpdatePhase.failed);
    expect(orchestrator.state.retryAttempt, 1);
    expect(orchestrator.state.nextAttemptUtc, isNotNull);
    expect(orchestrator.canAutoRetry, isFalse);
    expect(orchestrator.state.hasReadyPackage, isFalse);
  });

  test('验证失败：不进入 ready', () async {
    verifier.onVerify = () => const PackageVerification.invalid(
      UpdateFailure(UpdateFailureCode.packagePublisherMismatch),
    );
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    await orchestrator.check(manual: false, autoDownload: true);

    expect(orchestrator.state.phase, UpdatePhase.failed);
    expect(orchestrator.state.hasReadyPackage, isFalse);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.packagePublisherMismatch,
    );
  });

  test('另一个进程持有更新锁时不再下载（UPD-021）', () async {
    final lock = FakeUpdateLock(allow: false);
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
      updateLock: lock,
      processProbe: FakeProcessProbe(),
    );

    await orchestrator.check(manual: false, autoDownload: true);

    expect(lock.acquires, 1);
    expect(downloader.calls, 0);
    expect(orchestrator.state.phase, UpdatePhase.temporarilyBlocked);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.blockedInstallerBusy,
    );
    expect(lock.releases, 0);
  });

  test('下载成功后释放更新锁', () async {
    final lock = FakeUpdateLock();
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
      updateLock: lock,
      processProbe: FakeProcessProbe(),
    );

    await orchestrator.check(manual: false, autoDownload: true);

    expect(orchestrator.state.phase, UpdatePhase.ready);
    expect(lock.acquires, 1);
    expect(lock.releases, 1);
  });
  test('同一目标连续失败三次后停止自动重试（UPD-039）', () async {
    downloader.outcome = const DownloadOutcome.failed(
      UpdateFailure(UpdateFailureCode.downloadHashMismatch),
    );
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    await orchestrator.check(manual: false, autoDownload: true);
    await orchestrator.startDownload();
    await orchestrator.startDownload();

    expect(orchestrator.state.phase, UpdatePhase.failed);
    expect(orchestrator.state.targetFailureCount, 3);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.downloadRetryExhausted,
    );
    expect(orchestrator.state.lastFailure!.retryable, isFalse);
    expect(orchestrator.state.nextAttemptUtc, isNull);
    expect(orchestrator.canAutoRetry, isFalse);
  });

  test('回退过的版本被暂停：再次检查不会自动下载，手动重试才恢复', () async {
    store.state = const UpdateState(
      phase: UpdatePhase.rolledBack,
      target: targetFixture,
    );
    final verified = await verifiedManifestFixture();
    final source = FakeManifestSource(ManifestFetchResult.verified(verified));
    final orchestrator = UpdateOrchestrator(
      manifestSource: source,
      stateStore: store,
      installedPackages: installed,
      downloader: downloader,
      verifier: verifier,
      layout: layout,
      safety: safety,
      log: log,
      clock: clock,
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    );

    await orchestrator.initialize();
    expect(orchestrator.state.phase, UpdatePhase.failed);
    expect(orchestrator.state.pausedTargetVersion, '1.9.0.0');

    final result = await orchestrator.check(manual: false, autoDownload: true);
    expect(result.failure!.code, UpdateFailureCode.installTargetPaused);
    expect(downloader.calls, 0);

    // 用户显式重试会清掉暂停并允许重新检查/下载。
    await orchestrator.retry();
    expect(orchestrator.state.pausedTargetVersion, isNull);
  });

  test('磁盘空间不足时暂停并给出可重试的阻塞原因', () async {
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
      availableBytes: 1024,
    );

    await orchestrator.check(manual: false, autoDownload: true);

    expect(orchestrator.state.phase, UpdatePhase.temporarilyBlocked);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.blockedDiskSpaceLow,
    );
    expect(safety.status.blockers, contains(UpdateBlocker.diskSpaceLow));
    expect(downloader.calls, 0);
  });

  test('同一时刻的两触发合并成一次检查', () async {
    final verified = await verifiedManifestFixture();
    final source = FakeManifestSource(ManifestFetchResult.verified(verified));
    final orchestrator = UpdateOrchestrator(
      manifestSource: source,
      stateStore: store,
      installedPackages: installed,
      downloader: downloader,
      verifier: verifier,
      layout: layout,
      safety: safety,
      log: log,
      clock: clock,
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    );

    final results = await Future.wait([
      orchestrator.check(manual: true, autoDownload: false),
      orchestrator.check(manual: true, autoDownload: false),
    ]);

    expect(source.calls, 1);
    expect(results, hasLength(2));
  });

  test('下载进行中再次检查不会发起第二个清单请求', () async {
    final blocking = BlockingDownloader();
    final verified = await verifiedManifestFixture();
    final source = FakeManifestSource(ManifestFetchResult.verified(verified));
    final orchestrator = UpdateOrchestrator(
      manifestSource: source,
      stateStore: store,
      installedPackages: installed,
      downloader: blocking,
      verifier: verifier,
      layout: layout,
      safety: safety,
      log: log,
      clock: clock,
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    );

    final first = orchestrator.check(manual: true, autoDownload: true);
    await blocking.started.future;
    final second = orchestrator.check(manual: true, autoDownload: true);
    blocking.complete(
      DownloadOutcome.success(
        path: '${directory.path}${Platform.pathSeparator}package.msix.ready',
        sizeBytes: targetFixture.sizeBytes,
        sha256: targetFixture.sha256,
      ),
    );
    await first;
    await second;

    expect(source.calls, 1);
    expect(orchestrator.state.phase, UpdatePhase.ready);
  });

  test('点击就绪入口：助手确认后进入 waitingForExit 并请求退出', () async {
    final coordinator = FakeInstallCoordinator();
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
      installCoordinator: coordinator,
    );
    await orchestrator.check(manual: false, autoDownload: true);
    expect(orchestrator.state.phase, UpdatePhase.ready);

    await orchestrator.install();

    expect(coordinator.prepareCalls, 1);
    expect(coordinator.exitCalls, 1);
    expect(orchestrator.state.phase, UpdatePhase.waitingForExit);
    expect(orchestrator.state.transactionId, 'tx-1');
    expect(orchestrator.state.snapshotPath, isNotNull);
  });

  test('助手握手失败：退回就绪并保留安装包，不退出', () async {
    final coordinator = FakeInstallCoordinator(
      outcome: const InstallPreparationOutcome.failed(
        UpdateFailure(UpdateFailureCode.helperLaunchFailed),
      ),
    );
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
      installCoordinator: coordinator,
    );
    await orchestrator.check(manual: false, autoDownload: true);

    await orchestrator.install();

    expect(coordinator.exitCalls, 0);
    expect(orchestrator.state.phase, UpdatePhase.ready);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.helperLaunchFailed,
    );
  });

  test('没有装配安装链时点击就绪入口报告助手缺失', () async {
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );
    await orchestrator.check(manual: false, autoDownload: true);

    await orchestrator.install();

    expect(orchestrator.state.phase, UpdatePhase.failed);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.helperMissing,
    );
  });
  test('启动恢复：checking 回到 idle', () async {
    store.state = const UpdateState(phase: UpdatePhase.checking);
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    await orchestrator.initialize();

    expect(orchestrator.state.phase, UpdatePhase.idle);
  });

  test('启动恢复：已安装目标版本时把 installing 收敛成 succeeded', () async {
    store.state = const UpdateState(
      phase: UpdatePhase.installing,
      target: targetFixture,
    );
    installed.value = const InstalledPackage(
      identityName: appPackageIdentityName,
      publisher: appPublisher,
      familyName: appPackageFamilyName,
      architecture: PackageArchitecture.x64,
      version: MsixVersion(1, 9, 0, 0),
    );
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    await orchestrator.initialize();

    expect(orchestrator.state.phase, UpdatePhase.succeeded);
  });

  test('启动恢复：助手尚未启动的 preparingInstall 退回 ready', () async {
    store.state = const UpdateState(
      phase: UpdatePhase.preparingInstall,
      target: targetFixture,
    );
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
    );

    await orchestrator.initialize();

    expect(orchestrator.state.phase, UpdatePhase.ready);
  });

  test('未打包运行时给出明确原因，不发请求', () async {
    installed.value = null;
    final verified = await verifiedManifestFixture();
    final source = FakeManifestSource(ManifestFetchResult.verified(verified));
    final orchestrator = UpdateOrchestrator(
      manifestSource: source,
      stateStore: store,
      installedPackages: installed,
      downloader: downloader,
      verifier: verifier,
      layout: layout,
      safety: safety,
      log: log,
      clock: clock,
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    );

    final result = await orchestrator.check(manual: true);

    expect(source.calls, 0);
    expect(result.failure!.code, UpdateFailureCode.environmentNotPackaged);
    expect(result.isConfirmedUpToDate, isFalse);
  });

  test('检查通过后才开始的业务事务会阻止启动助手（二次检查，UPD-029）', () async {
    final coordinator = FakeInstallCoordinator();
    final verified = await verifiedManifestFixture();
    final sequenced = _SequencedSafety(safety);
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
      installCoordinator: coordinator,
      safetyOverride: sequenced,
    );
    await orchestrator.check(manual: false, autoDownload: true);
    expect(orchestrator.state.phase, UpdatePhase.ready);

    await orchestrator.install();

    expect(coordinator.prepareCalls, 0, reason: '第二次检查必须挡住启动');
    expect(orchestrator.state.phase, UpdatePhase.ready);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.blockedPlanApplying,
    );

    // 阻塞解除后直接重试即可，不需要重新检查清单或重新下载。
    await orchestrator.install();
    expect(coordinator.prepareCalls, 1);
    expect(orchestrator.state.phase, UpdatePhase.waitingForExit);
  });

  test('阻塞期间点击安装不启动助手，解除后入口自动恢复（UPD-029）', () async {
    final coordinator = FakeInstallCoordinator();
    final verified = await verifiedManifestFixture();
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(verified),
      installCoordinator: coordinator,
    );
    await orchestrator.check(manual: false, autoDownload: true);
    final lease = safety.begin(UpdateBlocker.importRunning);

    await orchestrator.install();
    expect(coordinator.prepareCalls, 0);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.blockedImportRunning,
    );

    lease.release();
    await orchestrator.install();
    expect(coordinator.prepareCalls, 1);
  });
}

final class _SequencedSafety implements UpdateSafetyCoordinator {
  _SequencedSafety(this._delegate);

  final InMemoryUpdateSafetyCoordinator _delegate;
  int _reads = 0;

  @override
  UpdateSafetyStatus get status {
    _reads++;
    if (_reads == 2) {
      return const UpdateSafetyStatus(blockers: {UpdateBlocker.planApplying});
    }
    return _delegate.status;
  }

  @override
  Stream<UpdateSafetyStatus> get changes => _delegate.changes;

  @override
  UpdateBlockerLease begin(UpdateBlocker blocker) => _delegate.begin(blocker);

  @override
  void setUnsavedChanges(bool active) => _delegate.setUnsavedChanges(active);

  @override
  void setDatabaseTransaction(bool active) =>
      _delegate.setDatabaseTransaction(active);

  @override
  void setPlanApplying(bool active) => _delegate.setPlanApplying(active);

  @override
  void setImportRunning(bool active) => _delegate.setImportRunning(active);

  @override
  void setBackupRunning(bool active) => _delegate.setBackupRunning(active);

  @override
  void setInstallerBusy(bool active) => _delegate.setInstallerBusy(active);

  @override
  void setRollbackNotReady(bool active) =>
      _delegate.setRollbackNotReady(active);

  @override
  void setDiskSpaceLow(bool active) => _delegate.setDiskSpaceLow(active);

  @override
  void dispose() {}
}
