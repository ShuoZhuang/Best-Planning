import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_progress_service.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';

import '../../application/execution/execution_test_support.dart';

/// Task 1 特征测试：完成/撤销只作用于单个 fragment。
void main() {
  test('完成并撤销同一个片段，片段状态与证据成对变化', () async {
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
    await repository.insertFragment(
      ExecutionFragment(
        fragmentId: 'fragment-1',
        dataEpoch: runtime.dataEpoch,
        occurrenceId: 'occurrence-1',
        cycleId: 'cycle-1',
        rootFragmentId: rootFragmentIdFor('occurrence-1'),
        sourceFragmentId: null,
        planVersionId: 'plan-1',
        blockId: 'block-1',
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
    final completed = await service.completeFragment(
      CompleteExecutionFragmentCommand(
        operationId: 'complete-1',
        dataEpoch: runtime.dataEpoch,
        fragmentId: 'fragment-1',
        planVersionId: 'plan-1',
        blockId: 'block-1',
        expectedFragmentRevision: 1,
        occurredAtUtc: start,
      ),
    );
    expect(completed.status, FragmentCommandStatus.applied);
    final undone = await service.undoFragmentCompletion(
      UndoFragmentCompletionCommand(
        operationId: 'undo-1',
        dataEpoch: runtime.dataEpoch,
        fragmentId: 'fragment-1',
        expectedFragmentRevision: 2,
        occurredAtUtc: start,
      ),
    );
    expect(undone.status, FragmentCommandStatus.applied);
    final fragment = await repository.findFragment('fragment-1');
    expect(fragment!.state, ExecutionFragmentState.planned);
    expect(fragment.completedMicros, 0);
  });
}
