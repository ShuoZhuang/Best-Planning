import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/internal_transport_task_guard.dart';
import 'package:personal_planner/application/recurring_progress_service.dart';
import 'package:personal_planner/application/settings_service.dart';
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

import '../application/execution/execution_test_support.dart';

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
}
