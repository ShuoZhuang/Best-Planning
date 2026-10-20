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
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_adjustment_transaction.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';
import 'package:personal_planner/scheduling/schedule_proposal_codec.dart';
import 'package:drift/drift.dart' show Variable;

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

final class _BudgetExhaustedEngine implements ScheduleEngine {
  const _BudgetExhaustedEngine();

  @override
  ScheduleProposal generate(ScheduleProblem problem) => ScheduleProposal(
    proposalId: 'budget-proposal',
    inputHash: problem.inputHash,
    algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
    planningWindow: problem.planningWindow,
    blocks: const [],
    unscheduled: const [],
    conflicts: const [],
    explanations: const [],
    metrics: const ProposalMetrics(
      isFullyFeasible: false,
      scheduledMinutes: 0,
      unscheduledMinutes: 0,
    ),
    outcome: SearchOutcomeKind.budgetExhausted,
  );
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
  late RepositoryScheduleProblemSource source;

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
    source = RepositoryScheduleProblemSource(
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

  test('确认前硬约束校验失败：零计划写入、零回执，调整仍可重生', () async {
    const codec = ScheduleProposalCodec();
    final begun = await service.beginDefer(
      currentPlanVersionId: 'base-1',
      targetBlockId: 'base-1:block-1',
      amount: 10,
      unit: DeferUnit.minutes,
    );
    final generated = await service.generate(begun.adjustment!.adjustmentId);
    expect(generated.status, GenerateAdjustmentPreviewStatus.previewReady);

    // 把持久预览篡改成"新增一块与目标块重叠"的方案：令牌仍匹配（哈希一起改），
    // 只有硬约束不合法。确认必须被 validator 拦下。
    final bundle = await previews.active(
      PendingPreviewKind.deferAdjustment,
      operationId: begun.adjustment!.adjustmentId,
    );
    final proposal = codec.decode(bundle!.preview.proposalJson);
    final target = proposal.blocks.firstWhere(
      (block) => block.taskId == 'task-1',
    );
    final tampered = proposal.withBlocks([
      ...proposal.blocks,
      PlannedBlock(
        id: 'overlapping-dup',
        taskId: target.taskId,
        range: TimeRange(
          startUtc: target.range.startUtc.add(const Duration(minutes: 5)),
          endUtc: target.range.endUtc,
        ),
      ),
    ]);
    await harness.database.customUpdate(
      'UPDATE pending_plan_previews SET proposal_json = ?, '
      'proposal_sha256 = ? WHERE preview_id = ?',
      variables: [
        Variable.withString(codec.encodeCanonical(tampered)),
        Variable.withString(codec.sha256OfCanonical(tampered)),
        Variable.withString(generated.previewId!),
      ],
    );

    final confirmed = await service.confirmAdjustment(
      adjustmentId: begun.adjustment!.adjustmentId,
      previewId: generated.previewId!,
    );

    expect(confirmed.status, AdjustmentApplyStatus.invalid);
    expect((await plans.current())!.id, 'base-1');
    expect(
      (await adjustments.byId(begun.adjustment!.adjustmentId))!.status,
      PlanAdjustmentStatus.previewReady,
    );
    expect(
      (await previews.byId(generated.previewId!))!.status,
      PendingPreviewStatus.active,
    );
  });

  test('搜索预算耗尽：生成失败且零计划写入、零预览', () async {
    final capped = PlanAdjustmentService(
      plans: plans,
      tasks: harness.taskRepository,
      adjustments: adjustments,
      previews: previews,
      source: source,
      // 引擎返回 budgetExhausted：它**不能**被当作"有解"或被部分应用。
      engine: const _BudgetExhaustedEngine(),
      policy: DeferTimePolicy(zones),
      clock: harness.clock,
      ids: harness.ids,
      granularityForDate: (_) async => 5,
      zones: zones,
      timeZoneId: zoneId,
      applier: plans,
    );
    final begun = await capped.beginDefer(
      currentPlanVersionId: 'base-1',
      targetBlockId: 'base-1:block-1',
      amount: 10,
      unit: DeferUnit.minutes,
    );
    final generated = await capped.generate(begun.adjustment!.adjustmentId);

    expect(
      generated.status,
      isNot(GenerateAdjustmentPreviewStatus.previewReady),
    );
    expect((await plans.current())!.id, 'base-1');
    expect(
      await previews.active(
        PendingPreviewKind.deferAdjustment,
        operationId: begun.adjustment!.adjustmentId,
      ),
      isNull,
    );
    final status = (await adjustments.byId(begun.adjustment!.adjustmentId))!
        .status;
    expect([
      PlanAdjustmentStatus.failed,
      PlanAdjustmentStatus.stale,
    ], contains(status));
  });

  test('任务在窗口内不可安排：生成失败且零写入（局部/全局都无解）', () async {
    // 目标块仍在确认计划里，但任务的最早开始时间落在规划窗口之后：
    // 装配层会把它作为 futureOutsideWindow 排除，于是目标块没有任何延续者。
    final current = await harness.taskRepository.getById('task-1');
    await harness.taskRepository.save(
      PlannerTask(
        id: current!.id,
        areaId: current.areaId,
        title: current.title,
        priority: current.priority,
        estimatedMinutes: current.estimatedMinutes,
        remainingMinutes: current.remainingMinutes,
        energyLevel: current.energyLevel,
        splitMode: current.splitMode,
        minChunkMinutes: current.minChunkMinutes,
        maxChunkMinutes: current.maxChunkMinutes,
        status: TaskStatus.open,
        availableFromUtc: DateTime.utc(2026, 11, 1),
        createdAtUtc: current.createdAtUtc,
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );
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
      isNot(GenerateAdjustmentPreviewStatus.previewReady),
    );
    expect((await plans.current())!.id, 'base-1');
    expect(
      await previews.active(
        PendingPreviewKind.deferAdjustment,
        operationId: begun.adjustment!.adjustmentId,
      ),
      isNull,
    );
    expect(
      (await adjustments.byId(begun.adjustment!.adjustmentId))!.status,
      PlanAdjustmentStatus.failed,
    );
  });
}
