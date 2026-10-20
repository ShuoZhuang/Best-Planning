// 1.11.0（计划 Task 9/10/11 服务层证据链）：今日页服务入口 → 持久预览 → 原子确认 → 精确撤销。
//
// 这条链路使用**真实内存 Drift 库、真实装配源、真实引擎与真实事务仓储**，
// 只替身界面与通知——它证明的是"延后确实改变了当前计划，且能精确恢复"。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/defer_time_policy.dart';
import 'package:personal_planner/application/plan_adjustment_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_pending_plan_preview_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_adjustment_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_adjustment_transaction.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../application/execution/execution_test_support.dart';

final class _NoCalendar implements CalendarRepository {
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _NoLifeAreas implements LifeAreaLookup {
  const _NoLifeAreas();

  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';

  late ExecutionTestHarness harness;
  late DriftPlanRepository plans;
  late DriftPlanAdjustmentRepository adjustments;
  late DriftPendingPlanPreviewRepository previews;
  late PlanAdjustmentService service;

  final sourceStart = DateTime.utc(2026, 10, 19, 7);
  var sideEffectCalls = 0;
  var failSideEffect = false;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    sideEffectCalls = 0;
    failSideEffect = false;
    plans = DriftPlanRepository(harness.database, clock: harness.clock);
    adjustments = DriftPlanAdjustmentRepository(
      harness.database,
      clock: harness.clock,
    );
    previews = DriftPendingPlanPreviewRepository(
      harness.database,
      clock: harness.clock,
    );
    final source = RepositoryScheduleProblemSource(
      tasks: harness.taskRepository,
      lifeAreas: const _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: plans,
      clock: harness.clock,
      timeZoneId: zoneId,
      zones: zones,
      adjustments: adjustments,
    );
    service = PlanAdjustmentService(
      plans: plans,
      tasks: harness.taskRepository,
      adjustments: adjustments,
      previews: previews,
      source: source,
      engine: DeterministicScheduleEngine(zones),
      policy: DeferTimePolicy(zones),
      clock: harness.clock,
      ids: harness.ids,
      granularityForDate: (_) async => 5,
      zones: zones,
      timeZoneId: zoneId,
      applier: plans,
      onAppliedSideEffects: () async {
        sideEffectCalls++;
        if (failSideEffect) throw StateError('notification down');
      },
    );
    final base = ScheduleProposal(
      proposalId: 'base-1',
      inputHash: 'hash-base',
      algorithmVersion: '20',
      planningWindow: TimeRange(
        startUtc: DateTime.utc(2026, 10, 19),
        endUtc: DateTime.utc(2026, 10, 26),
      ),
      blocks: [
        PlannedBlock(
          id: 'block-1',
          taskId: 'task-1',
          range: TimeRange(
            startUtc: sourceStart,
            endUtc: sourceStart.add(const Duration(minutes: 45)),
          ),
        ),
      ],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 45,
        unscheduledMinutes: 0,
      ),
    );
    final applied = await plans.applyProposal(base, 'hash-base');
    expect(applied.status, ApplyPlanStatus.applied);
  });

  tearDown(() => harness.close());

  test('延后 10 分钟：先生成持久预览，确认后计划改变，撤销后精确恢复', () async {
    final begun = await service.beginDefer(
      currentPlanVersionId: 'base-1',
      targetBlockId: 'base-1:block-1',
      amount: 10,
      unit: DeferUnit.minutes,
    );
    expect(begun.status, BeginDeferStatus.created);

    final generated = await service.generate(begun.adjustment!.adjustmentId);
    expect(
      generated.status,
      GenerateAdjustmentPreviewStatus.previewReady,
      reason: generated.failureCode?.name,
    );

    final confirmed = await service.confirmAdjustment(
      adjustmentId: begun.adjustment!.adjustmentId,
      previewId: generated.previewId!,
    );
    expect(confirmed.status, AdjustmentApplyStatus.applied);
    expect(sideEffectCalls, 1, reason: '应用成功后应消费一次 outbox');
    final appliedPlan = await plans.current();
    expect(appliedPlan!.id, confirmed.planVersionId);
    final target = appliedPlan.blocks.firstWhere(
      (block) => block.taskId == 'task-1',
    );
    expect(
      target.startUtc.isBefore(sourceStart.add(const Duration(minutes: 10))),
      isFalse,
      reason: '确认后的块不得早于下界',
    );

    final undone = await service.undoAdjustment(begun.adjustment!.adjustmentId);
    expect(undone.status, PlanUndoStatus.undone);
    final restored = await plans.current();
    final restoredTarget = restored!.blocks.firstWhere(
      (block) => block.taskId == 'task-1',
    );
    expect(restoredTarget.startUtc, sourceStart);
    expect(
      (await adjustments.byId(begun.adjustment!.adjustmentId))!.status,
      PlanAdjustmentStatus.applied,
      reason: '撤销不倒退调整历史',
    );
  });

  test('提交后副作用失败不改变已应用结果', () async {
    failSideEffect = true;
    final begun = await service.beginDefer(
      currentPlanVersionId: 'base-1',
      targetBlockId: 'base-1:block-1',
      amount: 10,
      unit: DeferUnit.minutes,
    );
    final generated = await service.generate(begun.adjustment!.adjustmentId);
    expect(generated.status, GenerateAdjustmentPreviewStatus.previewReady);

    final confirmed = await service.confirmAdjustment(
      adjustmentId: begun.adjustment!.adjustmentId,
      previewId: generated.previewId!,
    );

    expect(confirmed.status, AdjustmentApplyStatus.applied);
    expect((await plans.current())!.id, confirmed.planVersionId);
    expect(sideEffectCalls, 1);
  });

  test('生成后取消：不产出可确认预览，当前计划不变', () async {
    final begun = await service.beginDefer(
      currentPlanVersionId: 'base-1',
      targetBlockId: 'base-1:block-1',
      amount: 2,
      unit: DeferUnit.hours,
    );
    await service.generate(begun.adjustment!.adjustmentId);
    await service.cancel(begun.adjustment!.adjustmentId);

    final current = await plans.current();
    expect(current!.id, 'base-1');
    expect(
      (await adjustments.byId(begun.adjustment!.adjustmentId))!.status,
      PlanAdjustmentStatus.cancelled,
    );
  });
}
