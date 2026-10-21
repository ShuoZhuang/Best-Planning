import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/recurring_template_scope_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';
import 'package:personal_planner/domain/models/recurring_cycle_snapshot.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';

import 'execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftRecurringTaskRepository repository;
  late DriftRecurringExecutionRepository snapshots;
  late RecurringTaskService recurring;
  late RecurringTemplateScopeService scope;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    repository = DriftRecurringTaskRepository(
      harness.database,
      RecurringTaskDao(harness.database),
    );
    snapshots = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    recurring = RecurringTaskService(
      repository: repository,
      clock: harness.clock,
      idGenerator: harness.ids,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      tasks: harness.taskRepository,
      snapshots: snapshots,
    );
    scope = RecurringTemplateScopeService(
      templates: repository,
      snapshots: snapshots,
      cycles: repository,
      tasks: harness.taskRepository,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: harness.clock,
    );
    await repository.saveTemplate(
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
      TimeRange(startUtc: now, endUtc: now.add(const Duration(days: 14))),
      now,
    );
  });

  tearDown(() => harness.close());

  Future<RecurringCycleSnapshot?> snapshot(String period) =>
      snapshots.findCycleSnapshotForPeriod('template-1', period);

  test('仅本周：只改当前开放快照，模板与下周不变', () async {
    await scope.updateScope(
      templateId: 'template-1',
      scope: RecurringTemplateScope.thisCycle,
      changes: const RecurringTemplateChanges(
        targetMinutes: 300,
        pace: RecurringPace.early,
        energyLevel: TaskEnergyLevel.high,
        allowedWeekdaysMask: 0x1F,
      ),
    );
    final current = await snapshot('2026-10-19');
    final next = await snapshot('2026-10-26');
    final template = await repository.findTemplate('template-1');
    expect(current!.targetMinutes, 300);
    expect(current.pace, RecurringPace.early);
    expect(current.energyLevel, TaskEnergyLevel.high);
    expect(current.allowedWeekdaysMask, 0x1F);
    expect(next!.targetMinutes, 180);
    expect(template!.targetMinutes, 180);
    expect(template.pace, RecurringPace.even);
  });

  test('从下周：改模板与未来快照，当前周不变', () async {
    await scope.updateScope(
      templateId: 'template-1',
      scope: RecurringTemplateScope.fromNextWeek,
      changes: const RecurringTemplateChanges(
        targetMinutes: 240,
        pace: RecurringPace.deadlineWeighted,
      ),
    );
    final current = await snapshot('2026-10-19');
    final next = await snapshot('2026-10-26');
    final template = await repository.findTemplate('template-1');
    expect(current!.targetMinutes, 180);
    expect(next!.targetMinutes, 240);
    expect(next.pace, RecurringPace.deadlineWeighted);
    expect(template!.targetMinutes, 240);
    expect(template.pace, RecurringPace.deadlineWeighted);
  });

  test('整个系列：模板、当前开放周与未来周一起改，历史周保留原快照', () async {
    final currentBefore = await snapshot('2026-10-19');
    await scope.updateScope(
      templateId: 'template-1',
      scope: RecurringTemplateScope.entireSeries,
      changes: const RecurringTemplateChanges(
        title: '改名后的阅读',
        targetMinutes: 300,
        allowedWeekdaysMask: 0x7F,
      ),
    );
    final current = await snapshot('2026-10-19');
    final next = await snapshot('2026-10-26');
    final template = await repository.findTemplate('template-1');
    expect(current!.title, '改名后的阅读');
    expect(current.targetMinutes, 300);
    expect(next!.targetMinutes, 300);
    expect(template!.title, '改名后的阅读');
    expect(template.targetMinutes, 300);
    // 旧快照对象没有被原地改写（审计事实不变）。
    expect(currentBefore!.targetMinutes, 180);
  });

  test('跳过本周写 skipped 与 settledAt，不写 met', () async {
    final skipped = await scope.skipCurrentCycle('template-1');
    expect(skipped!.state, RecurringCycleStatus.skipped);
    expect(skipped.settledAtUtc, isNotNull);
    final cycle = await repository.findCycle(
      'template-1',
      DateTime(2026, 10, 19),
    );
    expect(cycle!.status, RecurringCycleStatus.skipped);
  });

  test('暂停到指定日、恢复和归档都不删除历史快照', () async {
    await scope.pauseUntil('template-1', DateTime(2026, 10, 21));
    var template = await repository.findTemplate('template-1');
    expect(template!.pausedUntilLocalDate, DateTime(2026, 10, 21));
    await scope.resume('template-1');
    template = await repository.findTemplate('template-1');
    expect(template!.pausedUntilLocalDate, isNull);
    await scope.archive('template-1');
    template = await repository.findTemplate('template-1');
    expect(template!.status, RecurringTemplateStatus.archived);
    expect(await snapshot('2026-10-19'), isNotNull);
  });

  test('暂停撤回暂停区间内尚未开始的片段', () async {
    await harness.database.customInsert(
      "INSERT INTO plan_versions "
      '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
      "VALUES ('plan-1', ?, 'hash', '20', 'confirmed', '{}')",
      variables: [
        Variable.withInt(harness.clock.nowUtc().microsecondsSinceEpoch),
      ],
    );
    await harness.seedOccurrence();
    final start = harness.clock.nowUtc().add(const Duration(hours: 1));
    await snapshots.insertFragment(
      ExecutionFragment(
        fragmentId: 'pause-fragment',
        dataEpoch: (await harness.repository.ensureRuntimeState()).dataEpoch,
        occurrenceId: 'occurrence-1',
        cycleId: 'template-1:2026-10-19',
        rootFragmentId: 'root:occurrence-1',
        sourceFragmentId: null,
        planVersionId: 'plan-1',
        blockId: 'pause-block',
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
    await scope.pauseUntil('template-1', DateTime(2026, 10, 21));
    final fragment = await snapshots.findFragment('pause-fragment');
    expect(fragment!.state, ExecutionFragmentState.withdrawn);
  });
}
