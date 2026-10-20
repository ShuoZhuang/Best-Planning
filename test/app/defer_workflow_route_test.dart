// 1.11.0（DFR-012）：真实 router + 真实仓储的调整工作流。
//
// **为什么必须用 `tester.runAsync`**：`testWidgets` 默认在 FakeAsync 里运行，
// 而真实内存 Drift 的查询要靠真实事件循环完成；直接在测试体里 `await` 仓储会挂起。
// 这里把"装配 + 预览生成"放进 `runAsync`，页面加载与确认则用"短暂 runAsync + pump"
// 交替推进，直到页面进入目标状态。
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
import 'package:personal_planner/domain/models/defer_unit.dart';
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
  @override
  Future<PlannerTask?> getById(String id) async => null;

  @override
  Future<void> save(PlannerTask task) async {}

  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(const []);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(const []);
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

/// 让真实 DB 的异步工作推进，再交付一帧 UI。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 15));
  }
}

void main() {
  testWidgets('路由进入持久预览：确认后计划改变，撤销后恢复基线', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final zones = TimeZoneDatabase();
    late ExecutionTestHarness harness;
    late DriftPlanRepository plans;
    late DriftPlanAdjustmentRepository adjustments;
    late DriftPendingPlanPreviewRepository previews;
    late PlanAdjustmentService service;
    late String adjustmentId;

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
      expect(
        (await plans.applyProposal(base, 'hash-base')).status,
        ApplyPlanStatus.applied,
      );
      final begun = await service.beginDefer(
        currentPlanVersionId: 'base-1',
        targetBlockId: 'base-1:block-1',
        amount: 10,
        unit: DeferUnit.minutes,
      );
      adjustmentId = begun.adjustment!.adjustmentId;
      final generated = await service.generate(adjustmentId);
      expect(generated.status, GenerateAdjustmentPreviewStatus.previewReady);
    });
    addTearDown(() => tester.runAsync(harness.close));

    final router = createPlannerRouter(
      taskService: TaskService(
        repository: _Tasks(),
        clock: harness.clock,
        idGenerator: harness.ids,
      ),
      settingsService: SettingsService(repository: MemorySettingsRepository()),
      appearance: AppearanceService(MemorySettingsRepository()),
      scheduleSource: const EmptyScheduleViewSource(),
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
    router.go('/planning/adjustment/$adjustmentId');
    await _settle(tester);

    expect(find.byType(AdjustmentPreviewPage), findsOneWidget);
    expect(find.textContaining('蓝桥杯'), findsWidgets);
    expect(find.byKey(const Key('adjustment-confirm')), findsOneWidget);
    expect(find.textContaining('adj-'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('adjustment-confirm')));
    await _settle(tester);

    expect(find.text('计划已更新。'), findsOneWidget);
    final appliedId = await tester.runAsync(
      () async => (await plans.current())!.id,
    );
    expect(appliedId, isNot('base-1'));

    await tester.tap(find.byKey(const Key('adjustment-undo')));
    await _settle(tester);

    expect(find.text('已恢复调整前的计划。'), findsOneWidget);
    final restored = await tester.runAsync(() => plans.current());
    final target = restored!.blocks.firstWhere((b) => b.taskId == 'task-1');
    expect(target.startUtc, DateTime.utc(2026, 10, 19, 7));
  });
}
