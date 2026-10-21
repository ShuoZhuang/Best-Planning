import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_progress_service.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/models/recurring_cycle_snapshot.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';

import 'execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftRecurringExecutionRepository repository;
  late RecurringProgressService service;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    repository = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    service = RecurringProgressService(
      repository: repository,
      executionRepository: harness.repository,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    await harness.repository.ensureRuntimeState();
    await _snapshot(repository, 'cycle-1', DateTime.utc(2026, 10, 12));
    await _snapshot(repository, 'cycle-2', DateTime.utc(2026, 10, 19));
  });

  tearDown(() => harness.close());

  test('23:50–00:20 跨本地周界拆成两段证据，每分钟只入账一次', () async {
    final runtime = await harness.repository.ensureRuntimeState();
    final result = await service.recordActivity(
      RecordRecurringActivityCommand(
        operationId: 'op-activity',
        dataEpoch: runtime.dataEpoch,
        startUtc: DateTime.utc(2026, 10, 18, 23, 50),
        endUtc: DateTime.utc(2026, 10, 19, 0, 20),
        occurredAtUtc: DateTime.utc(2026, 10, 19, 0, 20),
      ),
    );
    expect(result, hasLength(2));
    final byCycle = {
      for (final item in result) item.cycleId: item.amountMicros,
    };
    expect(byCycle['cycle-1'], 10 * 60000000);
    expect(byCycle['cycle-2'], 20 * 60000000);
    expect(
      result.fold<int>(0, (sum, item) => sum + item.amountMicros),
      30 * 60000000,
    );
    final entries = await harness.database
        .customSelect('SELECT id, task_id, ended_at_utc FROM time_entries')
        .get();
    expect(entries, hasLength(2));
    expect(
      entries.map((row) => row.read<String>('task_id')),
      everyElement('task-1'),
    );
    final credits = await harness.database
        .customSelect(
          'SELECT target_kind, target_id, amount_micros '
          'FROM execution_credit_allocations',
        )
        .get();
    expect(credits, hasLength(2));
    expect(
      credits.map((row) => row.read<String>('target_kind')),
      everyElement('recurringCycle'),
    );
  });

  test('重复提交同一 operationId 不重复生成证据', () async {
    final runtime = await harness.repository.ensureRuntimeState();
    final command = RecordRecurringActivityCommand(
      operationId: 'op-activity',
      dataEpoch: runtime.dataEpoch,
      startUtc: DateTime.utc(2026, 10, 18, 23, 50),
      endUtc: DateTime.utc(2026, 10, 19, 0, 20),
      occurredAtUtc: DateTime.utc(2026, 10, 19, 0, 20),
    );
    await service.recordActivity(command);
    final replay = await service.recordActivity(command);
    expect(replay, hasLength(2));
    expect(await repository.evidenceForCycle('cycle-1'), hasLength(1));
    expect(await repository.evidenceForCycle('cycle-2'), hasLength(1));
  });

  test('活动完全落在周期之外时拒绝，而不是硬塞进某一周', () async {
    final runtime = await harness.repository.ensureRuntimeState();
    await expectLater(
      service.recordActivity(
        RecordRecurringActivityCommand(
          operationId: 'op-outside',
          dataEpoch: runtime.dataEpoch,
          startUtc: DateTime.utc(2026, 11, 1),
          endUtc: DateTime.utc(2026, 11, 1, 1),
          occurredAtUtc: DateTime.utc(2026, 11, 1, 1),
        ),
      ),
      throwsStateError,
    );
  });
}

Future<void> _snapshot(
  DriftRecurringExecutionRepository repository,
  String cycleId,
  DateTime start,
) => repository.upsertCycleSnapshot(
  RecurringCycleSnapshot(
    cycleId: cycleId,
    templateId: 'template-1',
    transportTaskId: 'task-1',
    periodStartLocalDate: start,
    periodStartUtc: start,
    periodEndUtc: start.add(const Duration(days: 7)),
    effectiveStartUtc: start,
    effectiveEndUtc: start.add(const Duration(days: 7)),
    timeZoneId: 'UTC',
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
