import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_progress_service.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/tasks/recurring/recurring_task_detail_page.dart';

import '../../application/execution/execution_test_support.dart';

void main() {
  testWidgets('周期详情列出本周片段，完成本次只完成所选片段', (tester) async {
    final harness = await ExecutionTestHarness.create();
    addTearDown(harness.close);
    final taskRepository = DriftRecurringTaskRepository(
      harness.database,
      RecurringTaskDao(harness.database),
    );
    final fragments = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final recurring = RecurringTaskService(
      repository: taskRepository,
      clock: harness.clock,
      idGenerator: harness.ids,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      tasks: harness.taskRepository,
      snapshots: fragments,
    );
    await taskRepository.saveTemplate(
      RecurringTaskTemplate(
        id: 'template-1',
        title: '每周阅读',
        targetMinutes: 180,
        startsOnLocalDate: DateTime(2026, 10, 19),
        timeZoneId: 'Asia/Shanghai',
        createdAtUtc: harness.clock.nowUtc(),
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );
    final now = harness.clock.nowUtc();
    await recurring.ensureCycles(
      TimeRange(startUtc: now, endUtc: now.add(const Duration(days: 7))),
      now,
    );
    await harness.database.customInsert(
      "INSERT INTO plan_versions "
      '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
      "VALUES ('plan-1', ?, 'hash', '20', 'confirmed', '{}')",
      variables: [Variable.withInt(now.microsecondsSinceEpoch)],
    );
    await harness.seedOccurrence();
    final start = now.add(const Duration(hours: 2));
    await fragments.insertFragment(
      ExecutionFragment(
        fragmentId: 'fragment-1',
        dataEpoch: (await harness.repository.ensureRuntimeState()).dataEpoch,
        occurrenceId: 'occurrence-1',
        cycleId: 'template-1:2026-10-19',
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
        createdAtUtc: now,
        completedAtUtc: null,
        revision: 1,
      ),
    );
    final progress = RecurringProgressService(
      repository: fragments,
      executionRepository: harness.repository,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RecurringTaskDetailPage(
          service: recurring,
          templateId: 'template-1',
          nowUtc: now,
          recurringProgress: progress,
          recurringFragments: fragments,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本周片段'), findsOneWidget);
    expect(
      find.byKey(const Key('recurring-fragment-complete-fragment-1')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('recurring-fragment-complete-fragment-1')),
    );
    await tester.pumpAndSettle();
    final fragment = await fragments.findFragment('fragment-1');
    expect(fragment!.state, ExecutionFragmentState.completed);
    expect(await fragments.evidenceForFragment('fragment-1'), hasLength(1));
  });
}
