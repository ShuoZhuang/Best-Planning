import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_progress_service.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';
import 'package:personal_planner/domain/models/recurring_cycle_snapshot.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';

import 'execution/execution_test_support.dart';

/// Task 1 特征测试：补记/新活动不得改写已结束片段的历史状态。
void main() {
  test('补记活动后已完成片段保持完成，不被重开或覆盖', () async {
    final harness = await ExecutionTestHarness.create();
    addTearDown(harness.close);
    final repository = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final service = RecurringProgressService(
      repository: repository,
      executionRepository: harness.repository,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    await harness.database.customInsert(
      "INSERT INTO plan_versions "
      '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
      "VALUES ('plan-1', ?, 'hash', '19', 'confirmed', '{}')",
      variables: [
        Variable.withInt(harness.clock.nowUtc().microsecondsSinceEpoch),
      ],
    );
    await harness.seedOccurrence();
    final runtime = await harness.repository.ensureRuntimeState();
    final start = harness.clock.nowUtc().subtract(const Duration(hours: 2));
    await repository.upsertCycleSnapshot(
      RecurringCycleSnapshot(
        cycleId: 'cycle-1',
        templateId: 'template-1',
        transportTaskId: 'task-1',
        periodStartLocalDate: DateTime(2026, 10, 19),
        periodStartUtc: DateTime.utc(2026, 10, 19),
        periodEndUtc: DateTime.utc(2026, 10, 26),
        effectiveStartUtc: DateTime.utc(2026, 10, 19),
        effectiveEndUtc: DateTime.utc(2026, 10, 26),
        timeZoneId: 'Asia/Shanghai',
        templateRevision: 1,
        title: '每周阅读',
        notes: '',
        areaId: null,
        projectId: null,
        priority: TaskPriority.medium,
        energyLevel: TaskEnergyLevel.medium,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 25,
        maxChunkMinutes: 90,
        preferredStartMinute: null,
        preferredEndMinute: null,
        pace: RecurringPace.even,
        allowedWeekdaysMask: 0x7F,
        targetMinutes: 180,
        carryInMinutes: 0,
        state: RecurringCycleStatus.open,
        revision: 1,
        createdAtUtc: start,
        updatedAtUtc: start,
        settledAtUtc: null,
      ),
    );
    await repository.insertFragment(
      ExecutionFragment(
        fragmentId: 'fragment-done',
        dataEpoch: runtime.dataEpoch,
        occurrenceId: 'occurrence-1',
        cycleId: 'cycle-1',
        rootFragmentId: rootFragmentIdFor('occurrence-1'),
        sourceFragmentId: null,
        planVersionId: 'plan-1',
        blockId: 'block-done',
        plannedStartUtc: start,
        plannedEndUtc: start.add(const Duration(minutes: 30)),
        plannedMinutes: 30,
        allocatedMicros: 30 * 60000000,
        completedMicros: 30 * 60000000,
        state: ExecutionFragmentState.completed,
        createdAtUtc: start,
        completedAtUtc: start.add(const Duration(minutes: 30)),
        revision: 2,
      ),
    );
    final before = await repository.findFragment('fragment-done');
    await service.recordActivity(
      RecordRecurringActivityCommand(
        operationId: 'history-activity',
        dataEpoch: runtime.dataEpoch,
        startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 20)),
        endUtc: harness.clock.nowUtc(),
        occurredAtUtc: harness.clock.nowUtc(),
      ),
    );
    final after = await repository.findFragment('fragment-done');
    expect(after!.state, ExecutionFragmentState.completed);
    expect(after.completedAtUtc, before!.completedAtUtc);
    expect(after.revision, before.revision);
  });
}
