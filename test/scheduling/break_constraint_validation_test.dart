// 1.11.0（计划 Task 6 Step 4、DFR-025/031）：任务块之间的休息是**硬约束**。
//
// 修复前 `breakMinutes` 只参与坏空档评分，从不阻止"两个不同任务的块紧贴"；
// 校验器也不检查它，于是局部放置可以把别的任务塞进本该留白的位置。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'UTC';
  final window = TimeRange(
    startUtc: DateTime.utc(2026, 10, 19),
    endUtc: DateTime.utc(2026, 10, 21),
  );

  PlannedBlock block({
    required String id,
    required String taskId,
    required DateTime start,
    required int minutes,
  }) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
  );

  ScheduleProblem problem({
    required List<SchedulableTask> tasks,
    required PlanningRules rules,
    int? day2BreakMinutes,
  }) {
    final policies = dailyPoliciesForWindow(
      zones: zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    );
    if (day2BreakMinutes != null) {
      final day2 = DateTime(2026, 10, 20);
      policies[day2] = DailySchedulingPolicy(
        localDate: day2,
        resolvedRules: rules.copyWith(breakMinutes: day2BreakMinutes),
        softReserveTargetMinutes: 0,
      );
    }
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: tasks,
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: rules,
      dailyPolicies: policies,
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: rules,
        timeZoneId: zoneId,
      ),
      existingBlocks: const [],
      preferences: const PreferenceProfile(),
      inputHash: 'hash',
    );
  }

  const taskA = SchedulableTask(
    id: 'task-a',
    requiredMinutes: 60,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 15,
    maxChunkMinutes: 90,
  );
  const taskB = SchedulableTask(
    id: 'task-b',
    requiredMinutes: 30,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 15,
    maxChunkMinutes: 90,
  );

  test('两个不同任务的块紧贴时报 requiredBreakUnavailable', () {
    final rules = DefaultSettings.v1().copyWith(breakMinutes: 10);
    final blocks = [
      block(
        id: 'b1',
        taskId: 'task-a',
        start: DateTime.utc(2026, 10, 19, 9),
        minutes: 60,
      ),
      block(
        id: 'b2',
        taskId: 'task-b',
        start: DateTime.utc(2026, 10, 19, 10),
        minutes: 30,
      ),
    ];

    final conflicts = PlanValidator(zones)
        .validate(problem(tasks: const [taskA, taskB], rules: rules), blocks);

    final breaks = conflicts
        .where((c) => c.code == ConflictCode.requiredBreakUnavailable)
        .toList();
    expect(breaks, hasLength(1));
    expect(breaks.single.details['gapMinutes'], 0);
    expect(breaks.single.details['breakMinutes'], 10);
  });

  test('间隔恰好满足当天 breakMinutes 时不报错', () {
    final rules = DefaultSettings.v1().copyWith(breakMinutes: 10);
    final blocks = [
      block(
        id: 'b1',
        taskId: 'task-a',
        start: DateTime.utc(2026, 10, 19, 9),
        minutes: 60,
      ),
      block(
        id: 'b2',
        taskId: 'task-b',
        start: DateTime.utc(2026, 10, 19, 10, 10),
        minutes: 30,
      ),
    ];

    final conflicts = PlanValidator(zones)
        .validate(problem(tasks: const [taskA, taskB], rules: rules), blocks);

    expect(
      conflicts.where((c) => c.code == ConflictCode.requiredBreakUnavailable),
      isEmpty,
    );
  });

  test('同一任务的连续片段不要求任务间休息', () {
    final rules = DefaultSettings.v1().copyWith(breakMinutes: 30);
    final continuous = SchedulableTask(
      id: 'task-a',
      requiredMinutes: 120,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 15,
      maxChunkMinutes: 90,
    );
    final blocks = [
      block(
        id: 'b1',
        taskId: 'task-a',
        start: DateTime.utc(2026, 10, 19, 9),
        minutes: 60,
      ),
      block(
        id: 'b2',
        taskId: 'task-a',
        start: DateTime.utc(2026, 10, 19, 10),
        minutes: 60,
      ),
    ];

    final conflicts = PlanValidator(zones)
        .validate(problem(tasks: [continuous], rules: rules), blocks);

    expect(
      conflicts.where((c) => c.code == ConflictCode.requiredBreakUnavailable),
      isEmpty,
    );
  });

  test('跨本地日时取两天中更严格的 breakMinutes', () {
    final rules = DefaultSettings.v1().copyWith(breakMinutes: 5);
    final blocks = [
      block(
        id: 'b1',
        taskId: 'task-a',
        start: DateTime.utc(2026, 10, 19, 23),
        minutes: 50,
      ),
      block(
        id: 'b2',
        taskId: 'task-b',
        start: DateTime.utc(2026, 10, 20, 0),
        minutes: 30,
      ),
    ];
    final crossDayA = SchedulableTask(
      id: 'task-a',
      requiredMinutes: 50,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 15,
      maxChunkMinutes: 90,
    );

    final conflicts = PlanValidator(zones).validate(
      problem(tasks: [crossDayA, taskB], rules: rules, day2BreakMinutes: 15),
      blocks,
    );

    final breaks = conflicts
        .where((c) => c.code == ConflictCode.requiredBreakUnavailable)
        .toList();
    expect(breaks, hasLength(1));
    expect(breaks.single.details['gapMinutes'], 10);
    expect(breaks.single.details['breakMinutes'], 15);
    expect(breaks.single.details['localDate'], '2026-10-20');
  });
}
