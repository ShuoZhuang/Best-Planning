import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';

import '../application/execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftPlanRepository plans;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    plans = DriftPlanRepository(harness.database);
    await harness.seedOccurrence();
    for (final (id, created) in [('v1', 1000), ('v2', 3000)]) {
      await harness.database.customInsert(
        'INSERT INTO plan_versions '
        '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString(id),
          Variable.withInt(created),
          Variable.withString('hash-$id'),
          Variable.withString('20'),
          Variable.withString('confirmed'),
          Variable.withString('{}'),
        ],
      );
    }
    Future<void> block(String id, String version, int start, int end) =>
        harness.database.customInsert(
          'INSERT INTO schedule_blocks '
          '(id, plan_version_id, task_id, start_at_utc, end_at_utc, locked, '
          'explanation_code, created_at_utc, updated_at_utc) '
          'VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)',
          variables: [
            Variable.withString(id),
            Variable.withString(version),
            Variable.withString('task-1'),
            Variable.withInt(start),
            Variable.withInt(end),
            Variable.withString('scheduled'),
            Variable.withInt(start),
            Variable.withInt(start),
          ],
        );
    await block('a-before', 'v1', 1200, 1800);
    await block('b-after', 'v1', 3500, 3900);
    await block('c-current', 'v2', 3000, 3400);
  });

  tearDown(() => harness.close());

  test('旧版本中在新版本生效后才发生的未开始块不进入历史投影', () async {
    final blocks = await plans.blocksInWindow(
      DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true),
      DateTime.fromMicrosecondsSinceEpoch(5000, isUtc: true),
    );
    expect(
      blocks.map((item) => item.block.id),
      containsAll(['a-before', 'c-current']),
    );
    expect(blocks, hasLength(2));
  });

  test('已开始的旧片段冻结，重排后仍保留为历史事实', () async {
    final repository = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    await repository.insertFragment(
      ExecutionFragment(
        fragmentId: 'fragment-b',
        dataEpoch: (await harness.repository.ensureRuntimeState()).dataEpoch,
        occurrenceId: 'occurrence-1',
        cycleId: null,
        rootFragmentId: 'root:occurrence-1',
        sourceFragmentId: null,
        planVersionId: 'v1',
        blockId: 'b-after',
        plannedStartUtc: DateTime.fromMicrosecondsSinceEpoch(3500, isUtc: true),
        plannedEndUtc: DateTime.fromMicrosecondsSinceEpoch(3900, isUtc: true),
        plannedMinutes: 40,
        allocatedMicros: 40 * 60000000,
        completedMicros: 0,
        state: ExecutionFragmentState.started,
        createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(3400, isUtc: true),
        completedAtUtc: null,
        revision: 1,
      ),
    );
    final blocks = await plans.blocksInWindow(
      DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true),
      DateTime.fromMicrosecondsSinceEpoch(5000, isUtc: true),
    );
    expect(
      blocks.map((item) => item.block.id),
      containsAll(['a-before', 'b-after', 'c-current']),
    );
  });
}
