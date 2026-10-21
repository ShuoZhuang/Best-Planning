// 1.11.0（计划 Task 9/13、DFR-012）：自定义延后量与拒绝路径的 router 证据。
//
// 与 `defer_workflow_route_test.dart` 同一套真实装配（内存 Drift + 真实引擎 + 真实路由），
// 这里补三条：2 小时、1 天、以及"任务不可安排 ⇒ 结构化拒绝、零写入"。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/defer_time_policy.dart';
import 'package:personal_planner/application/plan_adjustment_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_pending_plan_preview_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_adjustment_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/planning/adjustment_preview_page.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../application/execution/execution_test_support.dart';

final class _Tasks implements TaskRepository {
  _Tasks(this._inner);

  final TaskRepository _inner;

  @override
  Future<PlannerTask?> getById(String id) => _inner.getById(id);

  @override
  Future<void> save(PlannerTask task) => _inner.save(task);

  @override
  Stream<List<PlannerTask>> watchAllTasks() => _inner.watchAllTasks();

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => _inner.watchOpenTasks();
}

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

final class _DeferSource implements ScheduleViewSource {
  const _DeferSource();

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      Stream.value([
        ScheduleViewItem(
          id: 'block:base-1:block-1',
          title: '蓝桥杯竞赛课',
          kind: ScheduleItemKind.task,
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 19, 7),
            endUtc: DateTime.utc(2026, 10, 19, 7, 45),
          ),
          categoryKey: 'area:study',
          categoryLabel: '学业',
          categoryColorArgb: 0xff456789,
          categorySortOrder: 0,
          taskId: 'task-1',
        ),
      ]);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 15));
  }
}

final class _Ctx {
  _Ctx({
    required this.harness,
    required this.plans,
    required this.adjustments,
    required this.previews,
    required this.service,
    required this.router,
  });

  final ExecutionTestHarness harness;
  final DriftPlanRepository plans;
  final DriftPlanAdjustmentRepository adjustments;
  final DriftPendingPlanPreviewRepository previews;
  final PlanAdjustmentService service;
  final dynamic router;
}

Future<_Ctx> _boot(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final zones = TimeZoneDatabase();
  late ExecutionTestHarness harness;
  late DriftPlanRepository plans;
  late DriftPlanAdjustmentRepository adjustments;
  late DriftPendingPlanPreviewRepository previews;
  late PlanAdjustmentService service;

  await tester.runAsync(() async {
    harness = await ExecutionTestHarness.create();
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
      timeZoneId: 'Asia/Shanghai',
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
      timeZoneId: 'Asia/Shanghai',
      applier: plans,
    );
    final sourceStart = DateTime.utc(2026, 10, 19, 7);
    final base = ScheduleProposal(
      proposalId: 'base-1',
      inputHash: 'hash-base',
      algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
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
    expect(
      (await plans.applyProposal(base, 'hash-base')).status,
      ApplyPlanStatus.applied,
    );
  });
  addTearDown(() => tester.runAsync(harness.close));

  final router = createPlannerRouter(
    taskService: TaskService(
      repository: _Tasks(harness.taskRepository),
      clock: harness.clock,
      idGenerator: harness.ids,
    ),
    settingsService: SettingsService(repository: MemorySettingsRepository()),
    appearance: AppearanceService(MemorySettingsRepository()),
    scheduleSource: const _DeferSource(),
    moveController: const DisabledWeekMoveController(),
    autoAdjustStore: MemoryAutoAdjustStore(),
    adjustmentService: service,
    plans: plans,
    todayStartUtc: DateTime.utc(2026, 10, 19),
    nowUtc: harness.clock.nowUtc(),
    zones: zones,
    timeZoneId: 'Asia/Shanghai',
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  router.go('/today');
  await _settle(tester);
  return _Ctx(
    harness: harness,
    plans: plans,
    adjustments: adjustments,
    previews: previews,
    service: service,
    router: router,
  );
}

Future<void> _openDeferDialog(WidgetTester tester) async {
  expect(
    find.byKey(const Key('today-more-block:base-1:block-1')),
    findsOneWidget,
  );
  await tester.tap(find.byKey(const Key('today-more-block:base-1:block-1')));
  await _settle(tester);
  await tester.tap(find.text('延后本次'));
  await _settle(tester);
  expect(find.text('延后当前计划'), findsOneWidget);
}

void main() {
  testWidgets('自定义 2 小时：下界 = 原开始 + 2 小时，落库单位是 hours', (tester) async {
    final ctx = await _boot(tester);
    await _openDeferDialog(tester);

    await tester.tap(find.text('小时'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('defer-current-2-hours')));
    await _settle(tester);

    expect(find.byType(AdjustmentPreviewPage), findsOneWidget);
    final stored = await tester.runAsync(() async {
      final rows = await ctx.harness.database
          .customSelect(
            'SELECT requested_amount, requested_unit, not_before_utc '
            'FROM plan_adjustments ORDER BY created_at_utc DESC LIMIT 1',
          )
          .getSingle();
      return rows;
    });
    expect(stored!.read<int>('requested_amount'), 2);
    expect(stored.read<String>('requested_unit'), 'hours');
    expect(
      DateTime.fromMicrosecondsSinceEpoch(
        stored.read<int>('not_before_utc'),
        isUtc: true,
      ),
      DateTime.utc(2026, 10, 19, 9),
    );
  });

  testWidgets('自定义 1 天：保持本地钟面，下界是次日同一时刻', (tester) async {
    final ctx = await _boot(tester);
    await _openDeferDialog(tester);

    await tester.tap(find.text('天'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('defer-current-1-days')));
    await _settle(tester);

    expect(find.byType(AdjustmentPreviewPage), findsOneWidget);
    final stored = await tester.runAsync(() async {
      return ctx.harness.database
          .customSelect(
            'SELECT requested_amount, requested_unit, not_before_utc '
            'FROM plan_adjustments ORDER BY created_at_utc DESC LIMIT 1',
          )
          .getSingle();
    });
    expect(stored!.read<int>('requested_amount'), 1);
    expect(stored.read<String>('requested_unit'), 'days');
    // 上海无 DST：次日 15:00 本地 = 07:00Z。
    expect(
      DateTime.fromMicrosecondsSinceEpoch(
        stored.read<int>('not_before_utc'),
        isUtc: true,
      ),
      DateTime.utc(2026, 10, 20, 7),
    );
  });

  testWidgets('任务不可安排：结构化拒绝、停留今日页、零写入', (tester) async {
    final ctx = await _boot(tester);
    await tester.runAsync(() async {
      final task = await ctx.harness.taskRepository.getById('task-1');
      await ctx.harness.taskRepository.save(
        PlannerTask(
          id: task!.id,
          areaId: task.areaId,
          title: task.title,
          priority: task.priority,
          estimatedMinutes: task.estimatedMinutes,
          remainingMinutes: task.remainingMinutes,
          energyLevel: task.energyLevel,
          splitMode: task.splitMode,
          minChunkMinutes: task.minChunkMinutes,
          maxChunkMinutes: task.maxChunkMinutes,
          status: TaskStatus.open,
          availableFromUtc: DateTime.utc(2026, 11, 1),
          createdAtUtc: task.createdAtUtc,
          updatedAtUtc: ctx.harness.clock.nowUtc(),
        ),
      );
    });

    await _openDeferDialog(tester);
    await tester.tap(find.byKey(const Key('defer-current-10-minutes')));
    await _settle(tester);

    expect(find.byType(AdjustmentPreviewPage), findsNothing);
    expect(find.textContaining('当前计划未改变'), findsWidgets);
    final planId = await tester.runAsync(
      () async => (await ctx.plans.current())!.id,
    );
    expect(planId, 'base-1');
  });
}
