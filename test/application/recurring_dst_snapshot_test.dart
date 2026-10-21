import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/time_range.dart';

import 'execution/execution_test_support.dart';

void main() {
  test('DST 结束周按本地周一至下周一生成 169 小时周界，快照不按 168 小时硬编码', () async {
    final harness = await ExecutionTestHarness.create(
      now: DateTime.utc(2026, 10, 28, 12),
    );
    addTearDown(harness.close);
    const timeZoneId = 'America/New_York';
    final repository = DriftRecurringTaskRepository(
      harness.database,
      RecurringTaskDao(harness.database),
    );
    final snapshots = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final service = RecurringTaskService(
      repository: repository,
      clock: harness.clock,
      idGenerator: harness.ids,
      zones: TimeZoneDatabase(),
      timeZoneId: timeZoneId,
      tasks: harness.taskRepository,
      snapshots: snapshots,
    );
    await repository.saveTemplate(
      RecurringTaskTemplate(
        id: 'template-dst',
        title: 'DST 阅读',
        targetMinutes: 120,
        startsOnLocalDate: DateTime(2026, 10, 26),
        timeZoneId: timeZoneId,
        createdAtUtc: harness.clock.nowUtc(),
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );
    final now = harness.clock.nowUtc();
    await service.ensureCycles(
      TimeRange(startUtc: now, endUtc: now.add(const Duration(days: 7))),
      now,
    );
    final snapshot = await snapshots.findCycleSnapshotForPeriod(
      'template-dst',
      '2026-10-26',
    );
    expect(snapshot, isNotNull);
    expect(
      snapshot!.periodEndUtc.difference(snapshot.periodStartUtc),
      const Duration(hours: 169),
    );
    final zones = TimeZoneDatabase();
    expect(
      snapshot.periodStartUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 26), timeZoneId),
    );
    expect(
      snapshot.periodEndUtc,
      zones.localMidnightToUtc(DateTime(2026, 11, 2), timeZoneId),
    );
  });
}
