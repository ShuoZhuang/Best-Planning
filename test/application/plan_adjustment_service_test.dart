// 1.11.0（计划 Task 5）：持久调整服务的资格、生成、重生与取消。
//
// 这些用例使用**真实装配层**（`RepositoryScheduleProblemSource`）、真实内存 Drift
// 仓储与真实引擎，只替身时区库之外的数据源；因此它们证明的是"生产链路会这样做"，
// 而不是"服务的私有分支被调用过"。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/defer_time_policy.dart';
import 'package:personal_planner/application/pending_moves.dart';
import 'package:personal_planner/application/plan_adjustment_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_pending_plan_preview_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_adjustment_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../application/execution/execution_test_support.dart';

final class _FakeTasks implements TaskRepository {
  _FakeTasks(this.items);
  final List<PlannerTask> items;

  @override
  Future<PlannerTask?> getById(String id) async =>
      items.where((item) => item.id == id).firstOrNull;

  @override
  Future<void> save(PlannerTask task) async {}

  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(items);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(items);
}

final class _FakeCalendar implements CalendarRepository {
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

final class _FakePlans implements PlanRepository {
  _FakePlans(this.plan);

  ConfirmedPlan? plan;

  @override
  Future<ConfirmedPlan?> current() async => plan;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();
}

final class _StartedEvidence implements AdjustmentExecutionEvidence {
  const _StartedEvidence(this.blockIds);

  final Set<String> blockIds;

  @override
  Future<Set<String>> startedOrCompletedBlockIds(
    Iterable<String> blockIds,
  ) async => this.blockIds;
}

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';
  final created = DateTime.utc(2026, 10, 1);

  late ExecutionTestHarness harness;
  late DriftPlanAdjustmentRepository adjustments;
  late DriftPendingPlanPreviewRepository previews;
  late _FakePlans plans;
  late _FakeTasks tasks;
  late PlanAdjustmentService service;

  final research = PlannerTask(
    id: 'research',
    title: '科研实验',
    priority: TaskPriority.high,
    estimatedMinutes: 180,
    remainingMinutes: 180,
    energyLevel: TaskEnergyLevel.high,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
    status: TaskStatus.open,
    createdAtUtc: created,
    updatedAtUtc: created,
  );

  PlannedBlock block({
    String id = 'block-1',
    bool locked = false,
    DateTime? startUtc,
    DateTime? endUtc,
  }) => PlannedBlock(
    id: id,
    taskId: 'research',
    range: TimeRange(
      startUtc: startUtc ?? DateTime.utc(2026, 10, 5, 2),
      endUtc: endUtc ?? DateTime.utc(2026, 10, 5, 3, 30),
    ),
    locked: locked,
  );

  ConfirmedPlan confirmedPlan({
    List<PlannedBlock>? blocks,
    String id = 'plan-1',
  }) => ConfirmedPlan(
    id: id,
    inputHash: 'hash',
    algorithmVersion: '20',
    blocks: blocks ?? [block()],
  );

  Future<void> build({
    ConfirmedPlan? plan,
    PlannerTask? task,
    AdjustmentExecutionEvidence evidence =
        const NoAdjustmentExecutionEvidence(),
  }) async {
    harness = await ExecutionTestHarness.create(
      // 本地 09:00 的周一：目标块（本地 10:00）尚未开始。
      now: DateTime.utc(2026, 10, 5, 1),
      seedTask: false,
    );
    adjustments = DriftPlanAdjustmentRepository(
      harness.database,
      clock: harness.clock,
    );
    previews = DriftPendingPlanPreviewRepository(
      harness.database,
      clock: harness.clock,
    );
    plans = _FakePlans(plan ?? confirmedPlan());
    tasks = _FakeTasks([task ?? research]);
    final source = RepositoryScheduleProblemSource(
      tasks: tasks,
      lifeAreas: const _NoLifeAreas(),
      calendar: _FakeCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: plans,
      clock: harness.clock,
      timeZoneId: zoneId,
      zones: zones,
      adjustments: adjustments,
    );
    service = PlanAdjustmentService(
      plans: plans,
      tasks: tasks,
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
      executionEvidence: evidence,
    );
  }

  tearDown(() => harness.close());

  group('beginDefer 资格', () {
    test('合法块创建持久调整：快照、下界与兄弟块来自仓储事实', () async {
      await build();

      final result = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );

      expect(result.status, BeginDeferStatus.created);
      final adjustment = result.adjustment!;
      expect(adjustment.targetTitleSnapshot, '科研实验');
      expect(adjustment.requestedAmount, 10);
      expect(adjustment.requestedUnit, DeferUnit.minutes);
      expect(adjustment.sourceStartUtc, DateTime.utc(2026, 10, 5, 2));
      expect(adjustment.notBeforeUtc, DateTime.utc(2026, 10, 5, 2, 10));
      expect(adjustment.basePlanVersionId, 'plan-1');
      expect(adjustment.status, PlanAdjustmentStatus.active);
      expect(await adjustments.byId(adjustment.adjustmentId), isNotNull);
    });

    test('计划版本与页面不一致返回 targetChanged，不创建调整', () async {
      await build();

      final result = await service.beginDefer(
        currentPlanVersionId: 'plan-older',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );

      expect(result.status, BeginDeferStatus.targetChanged);
      expect(result.failureCode, PlanAdjustmentFailureCode.basePlanChanged);
      expect(await adjustments.recoverable(harness.clock.nowUtc()), isEmpty);
    });

    test('块不存在返回 targetMissing，不退回普通生成', () async {
      await build();

      final result = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'missing-block',
        amount: 10,
        unit: DeferUnit.minutes,
      );

      expect(result.status, BeginDeferStatus.targetMissing);
      expect(result.adjustment, isNull);
    });

    test('已完成任务返回 targetIneligible', () async {
      final completed = PlannerTask(
        id: 'research',
        title: '科研实验',
        priority: TaskPriority.high,
        estimatedMinutes: 180,
        remainingMinutes: 0,
        energyLevel: TaskEnergyLevel.high,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
        status: TaskStatus.completed,
        createdAtUtc: created,
        updatedAtUtc: created,
      );
      await build(task: completed);

      final result = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );

      expect(result.status, BeginDeferStatus.targetIneligible);
      expect(result.adjustment, isNull);
    });

    test('锁定块返回 targetIneligible', () async {
      await build(plan: confirmedPlan(blocks: [block(locked: true)]));

      final result = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );

      expect(result.status, BeginDeferStatus.targetIneligible);
    });

    test('已有执行开始事实的块返回 targetIneligible', () async {
      await build(evidence: const _StartedEvidence({'block-1'}));

      final result = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );

      expect(result.status, BeginDeferStatus.targetIneligible);
    });

    test('同一块上已有进行中的调整返回 operationConflict，不覆盖它', () async {
      await build();
      final first = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );

      final second = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 2,
        unit: DeferUnit.hours,
      );

      expect(second.status, BeginDeferStatus.operationConflict);
      expect(
        (await adjustments.byId(first.adjustment!.adjustmentId))!
            .requestedAmount,
        10,
        reason: '第二个操作不得改动第一个',
      );
    });

    test('块已开始（开始时刻等于现在）同样被拒绝', () async {
      await build();
      plans.plan = confirmedPlan(
        blocks: [
          block(
            startUtc: harness.clock.nowUtc(),
            endUtc: harness.clock.nowUtc().add(const Duration(minutes: 90)),
          ),
        ],
      );

      final result = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );

      expect(result.status, BeginDeferStatus.targetIneligible);
    });

    test('非法延后量在创建前就被拒绝', () async {
      await build();

      final result = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 8,
        unit: DeferUnit.days,
      );

      expect(result.status, BeginDeferStatus.invalidAmount);
      expect(await adjustments.recoverable(harness.clock.nowUtc()), isEmpty);
    });
  });

  group('生成与持久预览', () {
    test('延后生成后请求仍存在直到确认：状态 previewReady、预览持久化', () async {
      await build();
      final begun = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );

      final generated = await service.generate(begun.adjustment!.adjustmentId);

      expect(
        generated.status,
        GenerateAdjustmentPreviewStatus.previewReady,
        reason: generated.failureCode?.name,
      );
      final persisted = await adjustments.byId(begun.adjustment!.adjustmentId);
      expect(persisted!.status, PlanAdjustmentStatus.previewReady);
      expect(persisted.previewId, generated.previewId);
      final bundle = await previews.active(
        PendingPreviewKind.deferAdjustment,
        operationId: begun.adjustment!.adjustmentId,
      );
      expect(bundle, isNotNull);
      expect(bundle!.preview.proposalJson, isNot('{}'));
      expect(bundle.preview.proposalSha256, isNotEmpty);
      expect(bundle.blocks, isNotEmpty);
      expect(
        bundle.blocks.where((b) => b.title == '科研实验'),
        isNotEmpty,
        reason: '标题快照必须进入预览',
      );
      expect(
        bundle.blocks.any(
          (b) => b.startUtc.isBefore(DateTime.utc(2026, 10, 5, 2, 10)),
        ),
        isFalse,
        reason: '预览块不得早于下界',
      );
    });

    test('目标块在生成前被移动：标记 stale，不产出普通生成', () async {
      await build();
      final begun = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );
      plans.plan = confirmedPlan(
        blocks: [
          block(
            startUtc: DateTime.utc(2026, 10, 5, 5),
            endUtc: DateTime.utc(2026, 10, 5, 6, 30),
          ),
        ],
      );

      final generated = await service.generate(begun.adjustment!.adjustmentId);

      expect(generated.status, GenerateAdjustmentPreviewStatus.stale);
      expect(
        (await adjustments.byId(begun.adjustment!.adjustmentId))!.status,
        PlanAdjustmentStatus.stale,
      );
      expect(
        await previews.active(
          PendingPreviewKind.deferAdjustment,
          operationId: begun.adjustment!.adjustmentId,
        ),
        isNull,
      );
    });

    test('重生保留原意：revision +1、数量与单位不变、旧预览被 supersede', () async {
      await build();
      final begun = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 2,
        unit: DeferUnit.hours,
      );
      final first = await service.generate(begun.adjustment!.adjustmentId);
      expect(first.status, GenerateAdjustmentPreviewStatus.previewReady);

      final regenerated = await service.regenerate(
        begun.adjustment!.adjustmentId,
      );

      expect(regenerated.status, GenerateAdjustmentPreviewStatus.previewReady);
      expect(regenerated.adjustment!.revision, 2);
      expect(regenerated.adjustment!.requestedAmount, 2);
      expect(regenerated.adjustment!.requestedUnit, DeferUnit.hours);
      expect(regenerated.adjustment!.targetBlockId, 'block-1');
      expect(regenerated.previewId, isNot(first.previewId));
      final old = await previews.byId(first.previewId!);
      expect(old!.status, PendingPreviewStatus.superseded);
      final active = await previews.active(
        PendingPreviewKind.deferAdjustment,
        operationId: begun.adjustment!.adjustmentId,
      );
      expect(active!.preview.previewId, regenerated.previewId);
    });
  });

  group('取消与恢复', () {
    test('取消只终结自己的调整，不影响另一个调整', () async {
      await build(
        plan: confirmedPlan(
          blocks: [
            block(),
            block(
              id: 'block-2',
              startUtc: DateTime.utc(2026, 10, 6, 2),
              endUtc: DateTime.utc(2026, 10, 6, 3, 30),
            ),
          ],
        ),
      );
      final first = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );
      final second = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-2',
        amount: 10,
        unit: DeferUnit.minutes,
      );

      expect(await service.cancel(first.adjustment!.adjustmentId), isTrue);

      expect(
        (await adjustments.byId(first.adjustment!.adjustmentId))!.status,
        PlanAdjustmentStatus.cancelled,
      );
      expect(
        (await adjustments.byId(second.adjustment!.adjustmentId))!.status,
        PlanAdjustmentStatus.active,
      );
      expect(await service.cancel(first.adjustment!.adjustmentId), isTrue);
    });

    test('取消后的调整不能再生效（生成返回 terminal）', () async {
      await build();
      final begun = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );
      await service.cancel(begun.adjustment!.adjustmentId);

      final generated = await service.generate(begun.adjustment!.adjustmentId);

      expect(generated.status, GenerateAdjustmentPreviewStatus.terminal);
    });

    test('重启后可以恢复待确认延后', () async {
      await build();
      final begun = await service.beginDefer(
        currentPlanVersionId: 'plan-1',
        targetBlockId: 'block-1',
        amount: 30,
        unit: DeferUnit.minutes,
      );

      final recoverable = await service.recoverable();

      expect(recoverable.map((a) => a.adjustmentId), [
        begun.adjustment!.adjustmentId,
      ]);
      expect(recoverable.single.requestedAmount, 30);
    });
  });
}
