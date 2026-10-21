import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide ExecutionFragment;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/application/pending_plan_preview_service.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/recurring_cycle_maintenance_service.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/internal_transport_task_guard.dart';
import 'package:personal_planner/application/recurring_progress_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/today/today_page.dart';

import '../test/application/execution/execution_test_support.dart';

final _dayStartUtc = DateTime.utc(2026, 10, 19, 16);
final _blockStartUtc = _dayStartUtc.add(const Duration(hours: 10));

final class _Source implements ScheduleViewSource {
  const _Source();

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      Stream.value([
        ScheduleViewItem(
          id: 'block:block-1',
          title: '每周阅读',
          kind: ScheduleItemKind.task,
          range: TimeRange(
            startUtc: _blockStartUtc,
            endUtc: _blockStartUtc.add(const Duration(minutes: 45)),
          ),
          categoryKey: 'area:study',
          categoryLabel: '学业',
          categoryColorArgb: 0xFF5B8DEF,
          categorySortOrder: 0,
          taskId: 'task-1',
          recurringGoal: const RecurringGoalBadge(
            templateId: 'template-1',
            title: '每周阅读',
            recordedMinutes: 0,
            targetMinutes: 180,
          ),
        ),
      ]);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('app-router /today 点完成本次只完成 fragment，不完成普通任务', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final harness = await ExecutionTestHarness.create(
      now: DateTime.utc(2026, 10, 20, 2, 30),
    );
    addTearDown(harness.close);
    await harness.database.customInsert(
      "INSERT INTO plan_versions "
      '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
      "VALUES ('plan-1', ?, 'hash', '20', 'confirmed', '{}')",
      variables: [
        Variable.withInt(harness.clock.nowUtc().microsecondsSinceEpoch),
      ],
    );
    await harness.seedOccurrence();
    final repository = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final start = _blockStartUtc;
    await repository.insertFragment(
      ExecutionFragment(
        fragmentId: 'fragment-1',
        dataEpoch: (await harness.repository.ensureRuntimeState()).dataEpoch,
        occurrenceId: 'occurrence-1',
        cycleId: 'cycle-1',
        rootFragmentId: 'root:occurrence-1',
        sourceFragmentId: null,
        planVersionId: 'plan-1',
        blockId: 'block-1',
        plannedStartUtc: start,
        plannedEndUtc: start.add(const Duration(minutes: 45)),
        plannedMinutes: 45,
        allocatedMicros: 45 * 60000000,
        completedMicros: 0,
        state: ExecutionFragmentState.planned,
        createdAtUtc: harness.clock.nowUtc(),
        completedAtUtc: null,
        revision: 1,
      ),
    );
    final progress = RecurringProgressService(
      repository: repository,
      executionRepository: harness.repository,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final cycles = DriftRecurringTaskRepository(
      harness.database,
      RecurringTaskDao(harness.database),
    );
    final router = createPlannerRouter(
      taskService: TaskService(
        repository: harness.taskRepository,
        clock: harness.clock,
        idGenerator: harness.ids,
        transportGuard: InternalTransportTaskGuard(cycles),
      ),
      settingsService: SettingsService(repository: MemorySettingsRepository()),
      appearance: AppearanceService(MemorySettingsRepository()),
      scheduleSource: const _Source(),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      todayStartUtc: _dayStartUtc,
      nowUtc: harness.clock.nowUtc(),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      recurringProgress: progress,
      recurringFragments: repository,
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go('/today');
    await tester.pumpAndSettle();

    expect(find.byType(TodayPage), findsOneWidget);
    expect(find.text('完成本次'), findsOneWidget);
    await tester.tap(find.byKey(const Key('today-complete-block:block-1')));
    await tester.pumpAndSettle();

    final fragment = await repository.findFragment('fragment-1');
    expect(fragment!.state, ExecutionFragmentState.completed);
    expect(await repository.evidenceForFragment('fragment-1'), hasLength(1));
    final task = await harness.taskRepository.getById('task-1');
    expect(task!.status, TaskStatus.open);
  });

  testWidgets('下一完整周预排持久化，重开可读', (tester) async {
    final harness = await ExecutionTestHarness.create();
    addTearDown(harness.close);
    final repository = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final recurring = RecurringTaskService(
      repository: DriftRecurringTaskRepository(
        harness.database,
        RecurringTaskDao(harness.database),
      ),
      clock: harness.clock,
      idGenerator: harness.ids,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      snapshots: repository,
    );
    final previews = PendingPlanPreviewService(
      repository: repository,
      plans: DriftPlanRepository(harness.database),
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final maintenance = RecurringCycleMaintenanceService(
      cycles: recurring,
      previews: previews,
      plans: DriftPlanRepository(harness.database),
      creator: _LookaheadCreator(),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: harness.clock,
    );
    await maintenance.maintain();
    final active = await repository.activePreview(
      PendingPreviewKind.recurringLookahead,
    );
    expect(active, isNotNull);
    expect(active!.blocks.single.blockId, 'next-block');
  });

  testWidgets('真实服务链：生成提案→持久预排→确认→SQLite 当前计划', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    const clock = SystemClock();
    final zones = TimeZoneDatabase();
    final taskRepository = DriftTaskRepository(database.taskDao);
    final planRepository = DriftPlanRepository(database, clock: clock);
    final settingsRepository = DriftSettingsRepository(database, clock);
    final settings = SettingsService(repository: settingsRepository);
    final calendar = DriftCalendarRepository(database);
    final source = RepositoryScheduleProblemSource(
      tasks: taskRepository,
      lifeAreas: DriftLifeAreaLookup(database),
      calendar: calendar,
      settings: settings,
      plans: planRepository,
      clock: clock,
      timeZoneId: 'Asia/Shanghai',
      zones: zones,
    );
    final planning = PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    );
    final taskService = TaskService(
      repository: taskRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
    );
    await database.customInsert(
      "INSERT INTO areas (id, name, color, sort_order) "
      "VALUES ('area-1', '学业', 0, 0)",
    );
    await taskService.saveDraft(
      const TaskDraft(
        title: 'EXE-42 全链路任务',
        estimatedMinutes: 90,
        areaId: 'area-1',
      ),
    );
    await database.customInsert(
      "INSERT INTO plan_versions (id, created_at_utc, input_hash, "
      "algorithm_version, status, summary_json) VALUES "
      "('base-plan', 1, 'base', '19', 'confirmed', '{}')",
    );
    final proposal = await planning.createProposal();
    expect(proposal.blocks, isNotEmpty);
    final previews = PendingPlanPreviewService(
      repository: DriftRecurringExecutionRepository(
        database,
        clock: clock,
        idGenerator: UuidIdGenerator(),
      ),
      plans: planRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
      applyProposal: (proposal) =>
          planRepository.applyProposal(proposal, proposal.inputHash),
    );
    final bundle = await previews.saveProposal(
      proposal: proposal,
      basePlanVersionId: 'base-plan',
      window: proposal.planningWindow,
      timeZoneId: 'Asia/Shanghai',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: PlanPreviewModel(
            proposalId: bundle.preview.previewId,
            changes: const [],
            issues: const [],
            isStale: false,
          ),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: (mode) async {
            final result = await previews.confirm(
              previewId: bundle.preview.previewId,
              expectedBasePlanVersionId: bundle.preview.basePlanVersionId,
              expectedInputHash: bundle.preview.inputHash,
              expectedAlgorithmVersion: bundle.preview.algorithmVersion,
              expectedPreviewRevision: bundle.preview.revision,
            );
            final current = await planRepository.current();
            if (result.status == PreviewApplyStatus.applied &&
                current != null) {
              return ApplyPlanResult.applied(current);
            }
            return ApplyPlanResult.invalid(const []);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apply-plan')));
    await tester.pumpAndSettle();
    final current = await planRepository.current();
    expect(current, isNotNull);
    expect(current!.blocks, isNotEmpty);

    final secondProposal = await planning.createProposal();
    final application = PlanApplicationService(
      source: source,
      repository: planRepository,
      zones: zones,
    );
    final router = createPlannerRouter(
      taskService: taskService,
      settingsService: settings,
      appearance: AppearanceService(settingsRepository),
      scheduleSource: const _EmptyScheduleSource(),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      todayStartUtc: DateTime.utc(2026, 10, 19, 16),
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
      planningService: planning,
      planApplication: application,
      plans: planRepository,
      planHistory: planRepository,
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.go('/planning/preview/${secondProposal.proposalId}');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('apply-plan')), findsOneWidget);
    await tester.tap(find.byKey(const Key('apply-plan')));
    await tester.pumpAndSettle();
    final rerouted = await planRepository.current();
    expect(rerouted, isNotNull);
    expect(rerouted!.blocks, isNotEmpty);
  });
}

final class _LookaheadCreator implements ProposalCreator {
  @override
  Future<ScheduleProposal> createProposal({
    ScheduleRuleOverride? override,
    TimeRange? window,
  }) async {
    final start = window?.startUtc ?? DateTime.utc(2026, 10, 25, 16);
    return ScheduleProposal(
      proposalId: 'lookahead-1',
      inputHash: 'hash',
      algorithmVersion: '20',
      planningWindow: TimeRange(
        startUtc: start,
        endUtc: start.add(const Duration(days: 7)),
      ),
      blocks: [
        PlannedBlock(
          id: 'next-block',
          taskId: 'task-1',
          range: TimeRange(
            startUtc: start.add(const Duration(hours: 1)),
            endUtc: start.add(const Duration(hours: 2)),
          ),
        ),
      ],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 60,
        unscheduledMinutes: 0,
      ),
    );
  }
}

final class _EmptyScheduleSource implements ScheduleViewSource {
  const _EmptyScheduleSource();
  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      Stream.value(const []);
}
