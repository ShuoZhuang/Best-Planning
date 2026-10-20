import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';

import '../../application/execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    await harness.seedOccurrence();
    await harness.service.start(
      await harness.startCommand(
        operationId: 'op-start',
        occurrenceId: 'occurrence-1',
        occurrenceRevision: 1,
      ),
    );
    harness.clock.advance(const Duration(minutes: 5));
    await harness.service.finish(await harness.finishCommand('op-finish'));
  });

  tearDown(() => harness.close());

  Future<int> count(String table) async {
    final row = await harness.database
        .customSelect('SELECT COUNT(*) AS c FROM $table')
        .getSingle();
    return row.read<int>('c');
  }

  test('清除执行元数据默认保留 time_entries 并标成 legacyUnlinked', () async {
    final before = await harness.repository.ensureRuntimeState();
    final sessions = await harness.database
        .customSelect('SELECT id FROM time_entries')
        .get();
    expect(sessions, isNotEmpty);

    await harness.repository.clearExecutionData(deleteTimeEntries: false);

    expect(await count('execution_occurrences'), 0);
    expect(await count('execution_events'), 0);
    expect(await count('execution_session_links'), 0);
    expect(await count('execution_activity_segments'), 0);
    expect(await count('execution_credit_allocations'), 0);
    expect(await count('execution_progress_anchors'), 0);
    expect(await count('execution_reminder_intents'), 0);
    expect(await count('execution_block_links'), 0);
    expect(await count('time_entries'), sessions.length);
    final state = await harness.database
        .customSelect('SELECT recovery_state FROM time_entries')
        .getSingle();
    expect(state.read<String>('recovery_state'), 'legacyUnlinked');

    final after = await harness.repository.ensureRuntimeState();
    expect(after.dataEpoch, isNot(before.dataEpoch));
    expect(after.activeSessionId, isNull);
  });

  test('显式同时删除实际投入时 time_entries 也被清空', () async {
    expect(await count('time_entries'), 1);
    await harness.repository.clearExecutionData(deleteTimeEntries: true);
    expect(await count('time_entries'), 0);
    expect(await count('execution_occurrences'), 0);
  });

  test('清除后旧 dataEpoch 的恢复命令失效', () async {
    final oldCommand = await harness.startCommand(operationId: 'op-old');
    await harness.repository.clearExecutionData(deleteTimeEntries: false);
    final result = await harness.service.start(oldCommand);
    expect(result.status, ExecutionResultStatus.stale);
  });
}
