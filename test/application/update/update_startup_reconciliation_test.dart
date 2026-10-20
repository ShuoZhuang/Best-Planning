// 启动复核：状态只是线索，磁盘与已验证清单才是事实（1.11.1 修复 §5.2 / INV-05）。
//
// 事故后重启时，状态文件可能已被写坏或清空，但 `.ready` 包还在磁盘上。启动复核的职责是
// 枚举受控目录、用已签名清单证明身份、收养可用者、隔离无法证明者，并把阶段收敛成事实。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/rollback_baseline.dart';
import 'package:personal_planner/domain/update/update_baseline_status.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_doubles.dart';
import '../../support/update_fixtures.dart';

const InstalledPackage _installed1102 = InstalledPackage(
  identityName: appPackageIdentityName,
  publisher: appPublisher,
  familyName: appPackageFamilyName,
  architecture: PackageArchitecture.x64,
  version: MsixVersion(1, 10, 2, 0),
);

void main() {
  late Directory directory;
  late UpdateStorageLayout layout;
  late InMemoryStateStore store;
  late InMemoryUpdateSafetyCoordinator safety;
  late MemoryLogSink log;
  late FakeVerifier verifier;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('startup_reconcile_test_');
    layout = UpdateStorageLayout(root: directory);
    store = InMemoryStateStore();
    safety = InMemoryUpdateSafetyCoordinator();
    log = MemoryLogSink();
    verifier = FakeVerifier();
  });

  tearDown(() {
    safety.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<VerifiedManifest> manifest(String version, int build) =>
      verifiedManifestFixture(version: version, buildNumber: build);

  Future<File> writeReady(String version, {int bytes = 2048}) async {
    final target = layout.versionDirectory(MsixVersion.tryParse(version)!);
    await target.create(recursive: true);
    final ready = File(
      '${target.path}${Platform.pathSeparator}package.msix.ready',
    );
    await ready.writeAsBytes(List<int>.filled(bytes, 7));
    return ready;
  }

  UpdateOrchestrator build({required ManifestFetchResult fetchResult}) =>
      UpdateOrchestrator(
        manifestSource: FakeManifestSource(fetchResult),
        stateStore: store,
        installedPackages: FakeInstalledPackages(_installed1102),
        downloader: FakeDownloader(),
        verifier: verifier,
        layout: layout,
        safety: safety,
        log: log,
        clock: FakeClock(),
        diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
      );

  test('state 缺失 + 有效 ready：收养为 ready 并写入状态', () async {
    await writeReady('1.11.0.0');
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(await manifest('1.11.0', 52)),
    );

    await orchestrator.initialize();

    expect(orchestrator.state.phase, UpdatePhase.ready);
    expect(orchestrator.state.target!.msixVersion.value, '1.11.0.0');
    expect(store.state.target!.msixVersion.value, '1.11.0.0');
  });

  test('state upToDate + 有效更高 ready：仍然收养（状态不掩盖磁盘事实）', () async {
    store.state = const UpdateState(
      phase: UpdatePhase.upToDate,
      currentMsixVersion: MsixVersion(1, 10, 2, 0),
    );
    await writeReady('1.11.0.0');
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(await manifest('1.11.0', 52)),
    );

    await orchestrator.initialize();

    expect(orchestrator.state.phase, UpdatePhase.ready);
    expect(orchestrator.state.target!.msixVersion.value, '1.11.0.0');
  });

  test('state ready + 文件损坏：不得执行，阶段收敛为 failed', () async {
    final ready = await writeReady('1.11.0.0');
    store.state = UpdateState(
      phase: UpdatePhase.ready,
      currentMsixVersion: _installed1102.version,
      target: await _targetFor(await manifest('1.11.0', 52), ready),
      receivedBytes: 2048,
      totalBytes: 2048,
    );
    verifier.onVerify = () => const PackageVerification.invalid(
      UpdateFailure(UpdateFailureCode.downloadHashMismatch),
    );
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(await manifest('1.11.0', 52)),
    );

    await orchestrator.initialize();

    expect(orchestrator.state.phase, isNot(UpdatePhase.ready));
    expect(orchestrator.state.phase, UpdatePhase.failed);
    expect(orchestrator.state.target, isNotNull, reason: '目标保留以便重新下载');
    expect(await ready.exists(), isFalse, reason: '无法证明的包必须离开原位置');
    expect(await layout.quarantined(ready).exists(), isTrue);
  });

  test('多个 ready：收养最高且未撤回的版本，低版本包保留', () async {
    final oldReady = await writeReady('1.11.0.0');
    final newReady = await writeReady('1.11.1.0');
    final latest = await manifest('1.11.1', 53);
    store.state = UpdateState(
      phase: UpdatePhase.ready,
      currentMsixVersion: _installed1102.version,
      // 旧状态指向 1.11.0：它仍然可证明身份，因此不应被隔离，但不应压过更高的 1.11.1。
      target: await _targetFor(await manifest('1.11.0', 52), oldReady),
      receivedBytes: 2048,
      totalBytes: 2048,
    );
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(latest),
    );

    await orchestrator.initialize();

    expect(orchestrator.state.target!.msixVersion.value, '1.11.1.0');
    expect(await newReady.exists(), isTrue);
    expect(await oldReady.exists(), isTrue, reason: '低版本包保留给清理阶段');
  });

  test('已撤回的 ready 被隔离，且不会被收养', () async {
    final ready = await writeReady('1.11.0.0');
    final revoked = await verifiedManifestFixture(
      version: '1.11.0',
      buildNumber: 52,
      revokedVersions: ['1.11.0.0'],
    );
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(revoked),
    );

    await orchestrator.initialize();

    expect(orchestrator.state.target, isNull);
    expect(orchestrator.state.phase, isNot(UpdatePhase.ready));
    expect(await ready.exists(), isFalse);
    expect(await layout.quarantined(ready).exists(), isTrue);
  });

  test('无法证明身份的 ready 被隔离，而不是被静默删除', () async {
    final ready = await writeReady('1.12.0.0');
    // 只有 1.11.0 的清单，因此 1.12.0 无法证明身份。
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(await manifest('1.11.0', 52)),
    );

    await orchestrator.initialize();

    expect(await ready.exists(), isFalse);
    expect(await layout.quarantined(ready).exists(), isTrue);
    expect(orchestrator.state.target, isNull);
  });

  test('恢复过程幂等：连续两次 initialize 结果相同', () async {
    await writeReady('1.11.0.0');
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(await manifest('1.11.0', 52)),
    );

    await orchestrator.initialize();
    final firstTarget = orchestrator.state.target!.msixVersion.value;
    final firstPhase = orchestrator.state.phase;
    await orchestrator.initialize();

    expect(orchestrator.state.target!.msixVersion.value, firstTarget);
    expect(orchestrator.state.phase, firstPhase);
    expect(
      directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.quarantine'))
          .length,
      0,
    );
  });

  test('状态文件来自更新版本客户端时禁用更新，且不覆盖原文件', () async {
    store.sawFutureSchemaValue = true;
    final orchestrator = build(
      fetchResult: ManifestFetchResult.verified(await manifest('1.11.0', 52)),
    );

    await orchestrator.initialize();

    expect(orchestrator.updatesDisabled, isTrue);
    expect(orchestrator.state.phase, UpdatePhase.temporarilyBlocked);
    expect(
      orchestrator.state.lastFailure!.code,
      UpdateFailureCode.stateSchemaUnsupported,
    );
    final result = await orchestrator.check(manual: true, autoDownload: false);
    expect(result.isConfirmedUpToDate, isFalse);
    expect(store.saveCount, 0, reason: '不得用降级解析覆盖未来版本的状态文件');
  });

  test('基线成功但阻塞未清除（崩溃点）：启动复核恢复 ready 并解除阻塞', () async {
    final baselineFile = layout.baselinePackage(_installed1102.version);
    await baselineFile.parent.create(recursive: true);
    await baselineFile.writeAsBytes(List<int>.filled(2048, 0));
    final verified = await manifest('1.11.0', 52);
    final ready = await writeReady('1.11.0.0');
    store.state = UpdateState(
      phase: UpdatePhase.ready,
      currentMsixVersion: _installed1102.version,
      target: await _targetFor(verified, ready),
      receivedBytes: 2048,
      totalBytes: 2048,
      // 崩溃发生在"基线文件已落盘、blocker 尚未清除"之间：状态里还停在 preparing。
      baselinePreparation: const BaselinePreparationState(
        phase: BaselinePhase.preparing,
        requiredForInstalledVersion: MsixVersion(1, 10, 2, 0),
      ),
      baseline: RollbackBaseline(
        version: _installed1102.version,
        packagePath: baselineFile.path,
        sha256: testPackageSha256,
        sizeBytes: 2048,
        createdAtUtc: DateTime.utc(2026, 10, 20),
      ),
    );
    safety.setRollbackNotReady(true);
    final orchestrator = UpdateOrchestrator(
      manifestSource: FakeManifestSource(
        ManifestFetchResult.verified(verified),
      ),
      stateStore: store,
      installedPackages: FakeInstalledPackages(_installed1102),
      downloader: FakeDownloader(),
      verifier: verifier,
      layout: layout,
      safety: safety,
      log: log,
      clock: FakeClock(),
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
      baselineService: CountingBaselineFake(),
    );

    await orchestrator.initialize();

    expect(orchestrator.state.baselinePreparation.phase, BaselinePhase.ready);
    expect(orchestrator.state.phase, UpdatePhase.ready);
    expect(safety.status.canInstall, isTrue, reason: '严格校验通过后必须清除"回退基线未就绪"阻塞');
  });
}

Future<UpdateTarget> _targetFor(VerifiedManifest manifest, File ready) async {
  final m = manifest.manifest;
  return UpdateTarget(
    version: m.release.version,
    buildNumber: m.release.buildNumber,
    tag: m.tag,
    msixVersion: m.msixVersion,
    fileName: m.package.fileName,
    downloadUrl: m.package.downloadUrl,
    sizeBytes: m.package.sizeBytes,
    sha256: m.package.sha256,
    manifestDigest: manifest.canonicalDigest,
    keyId: m.signature.keyId,
  );
}
