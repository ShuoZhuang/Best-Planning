import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_progress_service.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';

import 'execution/execution_test_support.dart';

/// Task 1 特征测试：三个片段中只完成中间一个，另外两个不得被联动完成。
void main() {
  test('完成中间片段不会完成同 occurrence 的左右片段', () async {
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
    final start = harness.clock.nowUtc();
    for (final id in ['fragment-a', 'fragment-b', 'fragment-c']) {
      await repository.insertFragment(
        ExecutionFragment(
          fragmentId: id,
          dataEpoch: runtime.dataEpoch,
          occurrenceId: 'occurrence-1',
          cycleId: 'cycle-1',
          rootFragmentId: rootFragmentIdFor('occurrence-1'),
          sourceFragmentId: null,
          planVersionId: 'plan-1',
          blockId: 'block-$id',
          plannedStartUtc: start,
          plannedEndUtc: start.add(const Duration(minutes: 30)),
          plannedMinutes: 30,
          allocatedMicros: 30 * 60000000,
          completedMicros: 0,
          state: ExecutionFragmentState.planned,
          createdAtUtc: start,
          completedAtUtc: null,
          revision: 1,
        ),
      );
    }
    final result = await service.completeFragment(
      CompleteExecutionFragmentCommand(
        operationId: 'complete-b',
        dataEpoch: runtime.dataEpoch,
        fragmentId: 'fragment-b',
        planVersionId: 'plan-1',
        blockId: 'block-fragment-b',
        expectedFragmentRevision: 1,
        occurredAtUtc: start,
      ),
    );
    expect(result.status, FragmentCommandStatus.applied);
    expect(
      (await repository.findFragment('fragment-a'))!.state,
      ExecutionFragmentState.planned,
    );
    expect(
      (await repository.findFragment('fragment-b'))!.state,
      ExecutionFragmentState.completed,
    );
    expect(
      (await repository.findFragment('fragment-c'))!.state,
      ExecutionFragmentState.planned,
    );
  });
}
