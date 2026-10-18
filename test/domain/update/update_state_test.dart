// 持久状态机（UPD-019 / UPD-020 / 规格 §9）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/domain/update/rollback_baseline.dart';

const _target = UpdateTarget(
  version: SemVer(1, 9, 0),
  buildNumber: 46,
  tag: 'v1.9.0',
  msixVersion: MsixVersion(1, 9, 0, 0),
  fileName: 'BestPlanning_1.9.0.0_x64.msix',
  downloadUrl:
      'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/BestPlanning_1.9.0.0_x64.msix',
  sizeBytes: 2048,
  sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  manifestDigest:
      'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
  keyId: 'best-planning-2026-10',
);

void main() {
  group('正常流', () {
    test('从 idle 一路推进到 succeeded', () {
      var state = const UpdateState();
      for (final next in [
        UpdatePhase.checking,
        UpdatePhase.updateAvailable,
        UpdatePhase.downloading,
        UpdatePhase.verifying,
        UpdatePhase.ready,
        UpdatePhase.preparingInstall,
        UpdatePhase.waitingForExit,
        UpdatePhase.installing,
        UpdatePhase.launchingNewVersion,
        UpdatePhase.waitingForHealth,
        UpdatePhase.succeeded,
      ]) {
        final result = state.transitionTo(next);
        expect(
          result.acceptedTransition,
          isTrue,
          reason: '${state.phase.wireName} -> ${next.wireName} 应当被允许',
        );
        state = result.state;
      }
      expect(state.phase, UpdatePhase.succeeded);
    });

    test('无更新流为 idle → checking → upToDate', () {
      var state = const UpdateState();
      state = state.transitionTo(UpdatePhase.checking).state;
      state = state.transitionTo(UpdatePhase.upToDate).state;
      expect(state.phase, UpdatePhase.upToDate);
    });
  });

  group('禁止跳转（UPD-020）', () {
    const forbidden = [
      (UpdatePhase.idle, UpdatePhase.downloading),
      (UpdatePhase.downloading, UpdatePhase.ready),
      (UpdatePhase.checking, UpdatePhase.installing),
      (UpdatePhase.failed, UpdatePhase.installing),
      (UpdatePhase.upToDate, UpdatePhase.ready),
      (UpdatePhase.temporarilyBlocked, UpdatePhase.installing),
      (UpdatePhase.idle, UpdatePhase.succeeded),
      (UpdatePhase.installing, UpdatePhase.succeeded),
      (UpdatePhase.ready, UpdatePhase.installing),
      (UpdatePhase.idle, UpdatePhase.rollingBack),
    ];

    for (final (from, to) in forbidden) {
      test('${from.wireName} → ${to.wireName} 被拒绝且状态不变', () {
        final state = UpdateState(phase: from);
        final result = state.transitionTo(to);
        expect(result.acceptedTransition, isFalse);
        expect(result.state.phase, from);
        expect(
          result.failure!.code,
          UpdateFailureCode.stateIllegalTransition,
        );
        // 非法跳转不写 updatedAtUtc，也不改变任何其它字段。
        expect(result.state.updatedAtUtc, isNull);
      });
    }
  });

  group('状态文件', () {
    test('完整字段可以 JSON 往返', () {
      final state = UpdateState(
        phase: UpdatePhase.waitingForHealth,
        currentMsixVersion: const MsixVersion(1, 8, 1, 0),
        target: _target,
        receivedBytes: 1024,
        totalBytes: 2048,
        etag: '"abc"',
        lastModified: 'Wed, 21 Oct 2026 07:28:00 GMT',
        retryAttempt: 2,
        targetFailureCount: 3,
        pausedTargetVersion: '1.9.0.0',
        nextAttemptUtc: DateTime.utc(2026, 10, 18, 1),
        lastCheckedUtc: DateTime.utc(2026, 10, 18, 0),
        lastCheckClassification: UpdateCheckClassification.updateAvailable,
        lastFailure: UpdateFailure(
          UpdateFailureCode.networkOffline,
          detail: 'attempt 2',
          occurredAtUtc: DateTime.utc(2026, 10, 18, 0, 30),
          attempt: 2,
        ),
        transactionId: 'tx-1',
        baseline: RollbackBaseline(
          version: const MsixVersion(1, 8, 1, 0),
          packagePath: 'C:/Updates/1.8.1.0/package.msix.ready',
          sha256: _target.sha256,
          sizeBytes: 2048,
          createdAtUtc: DateTime.utc(2026, 10, 18),
          snapshotPath: 'C:/Updates/snapshot.zip',
          snapshotSha256: _target.manifestDigest,
        ),
        snapshotPath: 'C:/Updates/snapshot.zip',
        healthDeadlineUtc: DateTime.utc(2026, 10, 18, 0, 5),
        helperStartedUtc: DateTime.utc(2026, 10, 18, 0, 1),
        updatedAtUtc: DateTime.utc(2026, 10, 18, 0, 2),
      );

      final restored = UpdateState.tryParse(state.toJson());
      expect(restored, isNotNull);
      expect(restored!.phase, UpdatePhase.waitingForHealth);
      expect(restored.target!.msixVersion.value, '1.9.0.0');
      expect(restored.baseline!.version.value, '1.8.1.0');
      expect(restored.lastFailure!.code, UpdateFailureCode.networkOffline);
      expect(restored.lastCheckClassification, UpdateCheckClassification.updateAvailable);
      expect(restored.targetFailureCount, 3);
      expect(restored.pausedTargetVersion, '1.9.0.0');
      expect(restored.downloadProgress, 0.5);
    });

    test('损坏或不支持的状态返回 null（由调用方重建，不安装任何文件）', () {
      final base = const UpdateState(phase: UpdatePhase.ready).toJson();
      final cases = <Map<String, Object?>>[
        {...base, 'schemaVersion': 2},
        {...base, 'phase': 'unknownPhase'},
        {...base, 'receivedBytes': -1},
        {...base, 'target': {'version': '1.9.0'}},
        {...base, 'lastFailure': {'code': 'UPDATE_NOT_A_REAL_CODE'}},
      ];
      for (final json in cases) {
        expect(UpdateState.tryParse(json), isNull, reason: '$json');
      }
      expect(UpdateState.tryParse('not a map'), isNull);
    });

    test('copyWith 传 null 表示清空可空字段', () {
      final state = UpdateState(
        phase: UpdatePhase.failed,
        lastFailure: const UpdateFailure(UpdateFailureCode.networkOffline),
        target: _target,
      );
      final cleared = state.copyWith(lastFailure: null, target: null);
      expect(cleared.lastFailure, isNull);
      expect(cleared.target, isNull);
      expect(cleared.phase, UpdatePhase.failed);
      // 未传的字段保留。
      expect(state.copyWith(retryAttempt: 3).target, isNotNull);
    });
  });

  group('崩溃恢复动作', () {
    test('每个阶段都有明确动作', () {
      expect(recoveryActionFor(UpdatePhase.checking), UpdateRecoveryAction.recheck);
      expect(
        recoveryActionFor(UpdatePhase.downloading),
        UpdateRecoveryAction.resumeDownload,
      );
      expect(
        recoveryActionFor(UpdatePhase.verifying),
        UpdateRecoveryAction.verifyFromScratch,
      );
      expect(
        recoveryActionFor(UpdatePhase.ready),
        UpdateRecoveryAction.verifyReadyPackage,
      );
      expect(
        recoveryActionFor(UpdatePhase.preparingInstall),
        UpdateRecoveryAction.returnToReady,
      );
      expect(
        recoveryActionFor(UpdatePhase.waitingForExit),
        UpdateRecoveryAction.inspectHelperAndProcess,
      );
      expect(
        recoveryActionFor(UpdatePhase.installing),
        UpdateRecoveryAction.queryInstalledPackage,
      );
      expect(
        recoveryActionFor(UpdatePhase.waitingForHealth),
        UpdateRecoveryAction.continueHealthWait,
      );
      expect(
        recoveryActionFor(UpdatePhase.succeeded),
        UpdateRecoveryAction.verifyAndCleanup,
      );
      expect(
        recoveryActionFor(UpdatePhase.rollingBack),
        UpdateRecoveryAction.resumeRollback,
      );
      expect(
        recoveryActionFor(UpdatePhase.failed),
        UpdateRecoveryAction.keepFailureAndWait,
      );
    });

    test('只有全部 18 个阶段都被映射到', () {
      for (final phase in UpdatePhase.values) {
        expect(recoveryActionFor(phase), isNotNull);
      }
      expect(UpdatePhase.values, hasLength(18));
    });
  });

  test('busy 阶段覆盖检查、下载、验证与安装链', () {
    final busy = UpdatePhase.values
        .where((phase) => UpdateState(phase: phase).isBusy)
        .toSet();
    expect(busy, containsAll([
      UpdatePhase.checking,
      UpdatePhase.downloading,
      UpdatePhase.verifying,
      UpdatePhase.preparingInstall,
      UpdatePhase.waitingForExit,
      UpdatePhase.installing,
      UpdatePhase.launchingNewVersion,
      UpdatePhase.waitingForHealth,
      UpdatePhase.rollingBack,
    ]));
    expect(busy.contains(UpdatePhase.ready), isFalse);
    expect(busy.contains(UpdatePhase.downloadPaused), isFalse);
  });
}


