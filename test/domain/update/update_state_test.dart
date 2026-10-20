// 持久状态机（UPD-019 / UPD-020 / 规格 §9；1.11.1 修复 §4.5）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/update_baseline_status.dart';
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
  downloadUrl: 'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/BestPlanning_1.9.0.0_x64.msix',
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
        expect(result.failure!.code, UpdateFailureCode.stateIllegalTransition);
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
        ),
        baselinePreparation: const BaselinePreparationState(
          phase: BaselinePhase.retryWaiting,
          requiredForInstalledVersion: MsixVersion(1, 8, 1, 0),
          attempt: 2,
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
      expect(
        restored.lastCheckClassification,
        UpdateCheckClassification.updateAvailable,
      );
      expect(restored.targetFailureCount, 3);
      expect(restored.pausedTargetVersion, '1.9.0.0');
      expect(restored.downloadProgress, 0.5);
    });

    test('损坏或不支持的状态返回 null（由调用方重建，不安装任何文件）', () {
      final base = const UpdateState(phase: UpdatePhase.ready).toJson();
      final cases = <Map<String, Object?>>[
        {...base, 'schemaVersion': 3},
        {...base, 'phase': 'unknownPhase'},
        {...base, 'receivedBytes': -1},
        {
          ...base,
          'target': {'version': '1.9.0'},
        },
        {
          ...base,
          'lastFailure': {'code': 'UPDATE_NOT_A_REAL_CODE'},
        },
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
      expect(
        recoveryActionFor(UpdatePhase.checking),
        UpdateRecoveryAction.recheck,
      );
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
    expect(
      busy,
      containsAll([
        UpdatePhase.checking,
        UpdatePhase.downloading,
        UpdatePhase.verifying,
        UpdatePhase.preparingInstall,
        UpdatePhase.waitingForExit,
        UpdatePhase.installing,
        UpdatePhase.launchingNewVersion,
        UpdatePhase.waitingForHealth,
        UpdatePhase.rollingBack,
      ]),
    );
    expect(busy.contains(UpdatePhase.ready), isFalse);
    expect(busy.contains(UpdatePhase.downloadPaused), isFalse);
  });

  group('v1 → v2 迁移（UPD-INC-027）', () {
    Map<String, Object?> v1Json({
      String phase = 'ready',
      Map<String, Object?>? target,
      Map<String, Object?>? baseline,
    }) => {
      'schemaVersion': 1,
      'phase': phase,
      'currentMsixVersion': '1.10.2.0',
      'target': target ?? _target.toJson(),
      'receivedBytes': 2048,
      'totalBytes': 2048,
      'etag': '"pkg"',
      'lastModified': 'Wed, 21 Oct 2026 07:28:00 GMT',
      'retryAttempt': 0,
      'targetFailureCount': 0,
      'pausedTargetVersion': null,
      'nextAttemptUtc': null,
      'lastCheckedUtc': '2026-10-20T00:00:00.000Z',
      'lastConfirmedUtc': '2026-10-20T00:00:00.000Z',
      'manifestEtag': '"latest-1"',
      'lastCheckClassification': 'updateAvailable',
      'lastFailure': null,
      'transactionId': null,
      'baseline': baseline,
      'snapshotPath': null,
      'healthDeadlineUtc': null,
      'helperStartedUtc': null,
      'updatedAtUtc': '2026-10-20T00:00:00.000Z',
    };

    test('完整 v1 迁移保留 target、进度与 phase，ETag 只作诊断', () {
      final migrated = UpdateState.tryMigrateV1(v1Json());

      expect(migrated, isNotNull);
      expect(migrated!.schemaVersion, updateStateSchemaVersion);
      expect(migrated.phase, UpdatePhase.ready);
      expect(migrated.target!.msixVersion.value, '1.9.0.0');
      expect(migrated.receivedBytes, 2048);
      expect(migrated.etag, '"pkg"');
      expect(migrated.manifestEtag, '"latest-1"');
      expect(migrated.migratedFromSchemaVersion, 1);
      expect(migrated.migrationDroppedFields, isEmpty);
      expect(migrated.baselinePreparation.phase, BaselinePhase.absent);
      // v1 迁移结果本身是合法 v2：可以写回并再次读回。
      final reloaded = UpdateState.tryParse(migrated.toJson());
      expect(reloaded, isNotNull);
      expect(reloaded!.target!.msixVersion.value, '1.9.0.0');
    });

    test('v1 有 baseline 时只给出 ready 候选值', () {
      final migrated = UpdateState.tryMigrateV1(
        v1Json(
          baseline: {
            'version': '1.8.1.0',
            'packagePath': 'C:/Updates/baseline/pkg.msix',
            'sha256': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
            'sizeBytes': 2048,
            'createdAtUtc': '2026-10-18T00:00:00.000Z',
            'snapshotPath': 'C:/Updates/snapshot.zip',
          },
        ),
      );

      expect(migrated!.baseline!.version.value, '1.8.1.0');
      expect(migrated.baselinePreparation.phase, BaselinePhase.ready);
      // 旧模型里的快照字段被忽略：快照属于安装事务。
      expect(migrated.baseline!.packagePath, 'C:/Updates/baseline/pkg.msix');
    });

    test('缺字段的 v1 只丢该字段，保留可独立验证的 target', () {
      final json = v1Json()..remove('receivedBytes');
      final migrated = UpdateState.tryMigrateV1(json);

      expect(migrated, isNotNull);
      expect(migrated!.target!.msixVersion.value, '1.9.0.0');
      expect(migrated.receivedBytes, 0);
      expect(migrated.migrationDroppedFields, contains('receivedBytes'));
    });

    test('损坏的 v1 target 只丢 target，phase 与基线线索保留', () {
      final migrated = UpdateState.tryMigrateV1(
        v1Json(target: {'version': '1.9.0'}),
      );

      expect(migrated, isNotNull);
      expect(migrated!.target, isNull);
      expect(migrated.phase, UpdatePhase.ready);
      expect(migrated.migrationDroppedFields, contains('target'));
    });

    test('v2 已含基线准备状态时往返一致', () {
      final state = UpdateState(
        phase: UpdatePhase.ready,
        target: _target,
        baselinePreparation: BaselinePreparationState(
          phase: BaselinePhase.retryWaiting,
          requiredForInstalledVersion: const MsixVersion(1, 8, 1, 0),
          attempt: 3,
          nextAttemptUtc: DateTime.utc(2026, 10, 20, 1),
          lastFailure: const UpdateFailure(UpdateFailureCode.networkOffline),
        ),
        migrationDroppedFields: const ['legacyField'],
      );

      final restored = UpdateState.tryParse(state.toJson());
      expect(restored, isNotNull);
      expect(restored!.baselinePreparation.phase, BaselinePhase.retryWaiting);
      expect(restored.baselinePreparation.attempt, 3);
      expect(
        restored.baselinePreparation.lastFailure!.code,
        UpdateFailureCode.networkOffline,
      );
      expect(restored.migrationDroppedFields, ['legacyField']);
      expect(restored.baselinePhase, BaselinePhase.retryWaiting);
    });

    test('未来版本 schema 不被当作当前结构解析', () {
      final future = {
        ...const UpdateState(phase: UpdatePhase.ready).toJson(),
        'schemaVersion': updateStateSchemaVersion + 1,
        'newField': true,
      };
      expect(UpdateState.tryParse(future), isNull);
      expect(UpdateState.tryMigrateV1(future), isNull);
    });
  });
}
