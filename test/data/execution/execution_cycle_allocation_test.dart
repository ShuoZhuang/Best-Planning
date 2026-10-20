import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart'
    show TimeEntriesCompanion;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';

import '../../application/execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftRecurringTaskRepository repository;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    repository = DriftRecurringTaskRepository(
      harness.database,
      RecurringTaskDao(harness.database),
    );
  });

  tearDown(() => harness.close());

  Future<void> insertEntry({
    required String id,
    required DateTime startUtc,
    required DateTime endUtc,
    int pausedMinutes = 0,
  }) async {
    await harness.database
        .into(harness.database.timeEntries)
        .insert(
          TimeEntriesCompanion.insert(
            id: id,
            taskId: 'task-1',
            startedAtUtc: startUtc.microsecondsSinceEpoch,
            endedAtUtc: Value(endUtc.microsecondsSinceEpoch),
            pausedMinutes: Value(pausedMinutes),
            source: '{}',
            recoveryState: 'confirmed',
          ),
        );
  }

  test('跨周记录只把重叠部分计入各自周，先累计微秒再取整', () async {
    final boundary = DateTime.utc(2026, 10, 19); // 周一 00:00 UTC
    await insertEntry(
      id: 'cross-week',
      startUtc: boundary.subtract(const Duration(minutes: 10)),
      endUtc: boundary.add(const Duration(minutes: 10)),
    );

    final previousWeek = await repository.recordedMinutesForTask(
      'task-1',
      boundary.subtract(const Duration(days: 7)),
      boundary,
    );
    final currentWeek = await repository.recordedMinutesForTask(
      'task-1',
      boundary,
      boundary.add(const Duration(days: 7)),
    );
    expect(previousWeek, 10);
    expect(currentWeek, 10);
  });

  test('同一周内两段30秒累计为1分钟，不分别截断', () async {
    final day = DateTime.utc(2026, 10, 19, 8);
    await insertEntry(
      id: 'half-1',
      startUtc: day,
      endUtc: day.add(const Duration(seconds: 30)),
    );
    await insertEntry(
      id: 'half-2',
      startUtc: day.add(const Duration(hours: 1)),
      endUtc: day.add(const Duration(hours: 1, seconds: 30)),
    );
    expect(
      await repository.recordedMinutesForTask(
        'task-1',
        day,
        day.add(const Duration(days: 1)),
      ),
      1,
    );
  });

  test('两周各有30秒活动：每周各自保留30秒微秒，不跨周凑成1分钟', () async {
    final weekOne = DateTime.utc(2026, 10, 13, 8);
    final weekTwo = DateTime.utc(2026, 10, 20, 8);
    await insertEntry(
      id: 'week-one-half',
      startUtc: weekOne,
      endUtc: weekOne.add(const Duration(seconds: 30)),
    );
    await insertEntry(
      id: 'week-two-half',
      startUtc: weekTwo,
      endUtc: weekTwo.add(const Duration(seconds: 30)),
    );
    expect(
      await repository.recordedMicrosForTask(
        'task-1',
        DateTime.utc(2026, 10, 12),
        DateTime.utc(2026, 10, 19),
      ),
      30000000,
    );
    expect(
      await repository.recordedMicrosForTask(
        'task-1',
        DateTime.utc(2026, 10, 19),
        DateTime.utc(2026, 10, 26),
      ),
      30000000,
    );
  });
}
