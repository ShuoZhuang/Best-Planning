// 1.11.0（计划 Task 2 Step 3）：调整状态机只允许冻结的主路径。
//
// 这里不碰数据库：状态机的职责是"非法转换当场抛错"，而事件序列、preview
// supersede 与事务边界属于仓储（Task 3）与服务（Task 5）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';

void main() {
  final now = DateTime.utc(2026, 10, 12, 4);

  PlanAdjustment active() => PlanAdjustment(
    adjustmentId: 'adj-1',
    kind: PlanAdjustmentKind.defer,
    targetBlockId: 'block-1',
    targetTaskId: 'task-1',
    targetTitleSnapshot: '写周报',
    basePlanVersionId: 'plan-7',
    sourceStartUtc: DateTime.utc(2026, 10, 12, 2),
    sourceEndUtc: DateTime.utc(2026, 10, 12, 3),
    notBeforeUtc: DateTime.utc(2026, 10, 12, 2, 30),
    timeZoneId: 'Asia/Shanghai',
    requestedAmount: 30,
    requestedUnit: DeferUnit.minutes,
    status: PlanAdjustmentStatus.active,
    createdAtUtc: DateTime.utc(2026, 10, 12, 1),
    expiresAtUtc: DateTime.utc(2026, 10, 12, 13),
    revision: 1,
  );

  group('主路径', () {
    test('active -> generating -> previewReady -> applying -> applied', () {
      final generating = active().transitionTo(
        to: PlanAdjustmentStatus.generating,
        occurredAtUtc: now,
      );
      final previewReady = generating.transitionTo(
        to: PlanAdjustmentStatus.previewReady,
        occurredAtUtc: now,
        previewId: 'preview-1',
      );
      final applying = previewReady.transitionTo(
        to: PlanAdjustmentStatus.applying,
        occurredAtUtc: now,
      );
      final applied = applying.transitionTo(
        to: PlanAdjustmentStatus.applied,
        occurredAtUtc: now,
        appliedPlanVersionId: 'plan-8',
      );

      expect(applied.status, PlanAdjustmentStatus.applied);
      expect(applied.previewId, 'preview-1');
      expect(applied.appliedPlanVersionId, 'plan-8');
      expect(applied.revision, 1);
    });

    test('previewReady 缺少 previewId 时拒绝', () {
      final generating = active().transitionTo(
        to: PlanAdjustmentStatus.generating,
        occurredAtUtc: now,
      );

      expect(
        () => generating.transitionTo(
          to: PlanAdjustmentStatus.previewReady,
          occurredAtUtc: now,
        ),
        throwsArgumentError,
      );
    });

    test('applied 缺少 appliedPlanVersionId 时拒绝', () {
      final applying = active()
          .transitionTo(to: PlanAdjustmentStatus.generating, occurredAtUtc: now)
          .transitionTo(
            to: PlanAdjustmentStatus.previewReady,
            occurredAtUtc: now,
            previewId: 'preview-1',
          )
          .transitionTo(to: PlanAdjustmentStatus.applying, occurredAtUtc: now);

      expect(
        () => applying.transitionTo(
          to: PlanAdjustmentStatus.applied,
          occurredAtUtc: now,
        ),
        throwsArgumentError,
      );
    });

    test('failed 必须带稳定失败码', () {
      expect(
        () => active().transitionTo(
          to: PlanAdjustmentStatus.failed,
          occurredAtUtc: now,
        ),
        throwsArgumentError,
      );
      final failed = active().transitionTo(
        to: PlanAdjustmentStatus.failed,
        occurredAtUtc: now,
        failureCode: PlanAdjustmentFailureCode.noLegalSlot,
      );
      expect(failed.failureCode, PlanAdjustmentFailureCode.noLegalSlot);
    });
  });

  group('非主路径', () {
    test('活状态都可以取消/过期/判 stale', () {
      for (final to in [
        PlanAdjustmentStatus.cancelled,
        PlanAdjustmentStatus.expired,
        PlanAdjustmentStatus.stale,
        PlanAdjustmentStatus.failed,
      ]) {
        expect(
          active().canTransitionTo(to),
          isTrue,
          reason: 'active 应能进入 ${to.name}',
        );
      }

      final previewReady = active()
          .transitionTo(to: PlanAdjustmentStatus.generating, occurredAtUtc: now)
          .transitionTo(
            to: PlanAdjustmentStatus.previewReady,
            occurredAtUtc: now,
            previewId: 'preview-1',
          );
      for (final to in [
        PlanAdjustmentStatus.cancelled,
        PlanAdjustmentStatus.stale,
        PlanAdjustmentStatus.expired,
        PlanAdjustmentStatus.failed,
      ]) {
        expect(
          previewReady.canTransitionTo(to),
          isTrue,
          reason: 'previewReady 应能进入 ${to.name}',
        );
      }
    });

    test('applying 只能进入 applied/failed/stale', () {
      final applying = active()
          .transitionTo(to: PlanAdjustmentStatus.generating, occurredAtUtc: now)
          .transitionTo(
            to: PlanAdjustmentStatus.previewReady,
            occurredAtUtc: now,
            previewId: 'preview-1',
          )
          .transitionTo(to: PlanAdjustmentStatus.applying, occurredAtUtc: now);

      expect(applying.canTransitionTo(PlanAdjustmentStatus.applied), isTrue);
      expect(applying.canTransitionTo(PlanAdjustmentStatus.failed), isTrue);
      expect(applying.canTransitionTo(PlanAdjustmentStatus.stale), isTrue);
      expect(applying.canTransitionTo(PlanAdjustmentStatus.cancelled), isFalse);
      expect(applying.canTransitionTo(PlanAdjustmentStatus.expired), isFalse);
    });

    test('终态不可再转换', () {
      final applied = active()
          .transitionTo(to: PlanAdjustmentStatus.generating, occurredAtUtc: now)
          .transitionTo(
            to: PlanAdjustmentStatus.previewReady,
            occurredAtUtc: now,
            previewId: 'preview-1',
          )
          .transitionTo(to: PlanAdjustmentStatus.applying, occurredAtUtc: now)
          .transitionTo(
            to: PlanAdjustmentStatus.applied,
            occurredAtUtc: now,
            appliedPlanVersionId: 'plan-8',
          );

      for (final to in PlanAdjustmentStatus.values) {
        expect(applied.canTransitionTo(to), isFalse);
      }
      expect(
        () => applied.transitionTo(
          to: PlanAdjustmentStatus.cancelled,
          occurredAtUtc: now,
        ),
        throwsStateError,
      );
    });

    test('不允许跳步：active 不能直接 applied/previewReady', () {
      expect(
        () => active().transitionTo(
          to: PlanAdjustmentStatus.applied,
          occurredAtUtc: now,
          appliedPlanVersionId: 'plan-8',
        ),
        throwsStateError,
      );
      expect(
        () => active().transitionTo(
          to: PlanAdjustmentStatus.previewReady,
          occurredAtUtc: now,
          previewId: 'preview-1',
        ),
        throwsStateError,
      );
    });
  });

  group('重生', () {
    test('previewReady -> generating 保留身份与原意，revision +1 并清掉旧 preview', () {
      final previewReady = active()
          .transitionTo(to: PlanAdjustmentStatus.generating, occurredAtUtc: now)
          .transitionTo(
            to: PlanAdjustmentStatus.previewReady,
            occurredAtUtc: now,
            previewId: 'preview-1',
          );

      final regenerating = previewReady.transitionTo(
        to: PlanAdjustmentStatus.generating,
        occurredAtUtc: now,
        incrementRevision: true,
      );

      expect(regenerating.adjustmentId, 'adj-1');
      expect(regenerating.targetBlockId, 'block-1');
      expect(regenerating.requestedAmount, 30);
      expect(regenerating.requestedUnit, DeferUnit.minutes);
      expect(regenerating.notBeforeUtc, previewReady.notBeforeUtc);
      expect(regenerating.revision, 2);
      expect(
        regenerating.previewId,
        isNull,
        reason: '旧 preview 已被 supersede，不能让界面继续确认它',
      );
      expect(regenerating.status, PlanAdjustmentStatus.generating);
    });

    test('failed 可以重生，失败码被清掉', () {
      final failed = active().transitionTo(
        to: PlanAdjustmentStatus.failed,
        occurredAtUtc: now,
        failureCode: PlanAdjustmentFailureCode.searchBudgetExhausted,
      );

      final regenerating = failed.transitionTo(
        to: PlanAdjustmentStatus.generating,
        occurredAtUtc: now,
        incrementRevision: true,
      );

      expect(regenerating.failureCode, isNull);
      expect(regenerating.revision, 2);
    });

    test('取消后的调整不能重生（终态）', () {
      final cancelled = active().transitionTo(
        to: PlanAdjustmentStatus.cancelled,
        occurredAtUtc: now,
      );

      expect(
        cancelled.canTransitionTo(PlanAdjustmentStatus.generating),
        isFalse,
      );
    });
  });

  test('非 UTC 的转换时刻被拒绝', () {
    expect(
      () => active().transitionTo(
        to: PlanAdjustmentStatus.generating,
        occurredAtUtc: DateTime(2026, 10, 12, 4),
      ),
      throwsArgumentError,
    );
  });
}
