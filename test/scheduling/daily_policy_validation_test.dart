// 1.11.0（计划 Task 6 Step 3、DFR-027/031）：逐日上限必须按块所在本地日校验。
//
// 修复前 `PlanValidator` 用 `problem.rules.dailyMovableTaskLimitMinutes`（窗口首日）
// 检查所有日期：周末上限更高时会被误判超限，上限更低时会被放过。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
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
    int minutes = 60,
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
    bool dropDay2Policy = false,
  }) {
    final policies = dailyPoliciesForWindow(
      zones: zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    );
    final day2 = DateTime(2026, 10, 20);
    if (dropDay2Policy) {
      policies.remove(day2);
    } else {
      policies[day2] = DailySchedulingPolicy(
        localDate: day2,
        resolvedRules: rules.copyWith(dailyMovableTaskLimitMinutes: 240),
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
    requiredMinutes: 60,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 15,
    maxChunkMinutes: 90,
  );
  const taskC = SchedulableTask(
    id: 'task-c',
    requiredMinutes: 60,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 15,
    maxChunkMinutes: 90,
  );

  test('同一天超过当天上限被报告，另一天按它自己的更高上限放行', () {
    final rules = DefaultSettings.v1().copyWith(
      dailyMovableTaskLimitMinutes: 60,
      breakMinutes: 0,
    );
    final blocks = [
      block(id: 'b1', taskId: 'task-a', start: DateTime.utc(2026, 10, 19, 9)),
      block(id: 'b2', taskId: 'task-b', start: DateTime.utc(2026, 10, 19, 11)),
      block(id: 'b3', taskId: 'task-c', start: DateTime.utc(2026, 10, 20, 9)),
    ];

    final conflicts = PlanValidator(zones).validate(
      problem(tasks: const [taskA, taskB, taskC], rules: rules),
      blocks,
    );

    final daily = conflicts
        .where((c) => c.code == ConflictCode.dailyLimitExceeded)
        .toList();
    expect(daily, hasLength(1), reason: '只应报告 10-19，10-20 的上限更高');
    expect(daily.single.details['localDate'], '2026-10-19');
    expect(daily.single.details['limitMinutes'], 60);
  });

  test('上限更高的那天不会被窗口首日上限误判', () {
    final rules = DefaultSettings.v1().copyWith(
      dailyMovableTaskLimitMinutes: 60,
      breakMinutes: 0,
    );
    final blocks = [
      block(id: 'b1', taskId: 'task-a', start: DateTime.utc(2026, 10, 20, 9)),
      block(id: 'b2', taskId: 'task-a', start: DateTime.utc(2026, 10, 20, 11)),
    ];

    final conflicts = PlanValidator(zones).validate(
      problem(
        tasks: const [
          SchedulableTask(
            id: 'task-a',
            requiredMinutes: 120,
            splitMode: TaskSplitMode.splittable,
            minChunkMinutes: 15,
            maxChunkMinutes: 90,
          ),
        ],
        rules: rules,
      ),
      blocks,
    );

    expect(
      conflicts.where((c) => c.code == ConflictCode.dailyLimitExceeded),
      isEmpty,
      reason: '10-20 的当天上限是 240，120 分钟合法',
    );
  });

  test('缺少某天策略时报输入错误，而不是套用首日上限', () {
    final rules = DefaultSettings.v1().copyWith(
      dailyMovableTaskLimitMinutes: 60,
      breakMinutes: 0,
    );
    final blocks = [
      block(id: 'b1', taskId: 'task-a', start: DateTime.utc(2026, 10, 20, 9)),
    ];

    final conflicts = PlanValidator(zones).validate(
      problem(tasks: const [taskA], rules: rules, dropDay2Policy: true),
      blocks,
    );

    expect(
      conflicts.where((c) => c.blockingInput == 'missingDailyPolicy'),
      hasLength(1),
    );
    expect(
      conflicts.where((c) => c.code == ConflictCode.dailyLimitExceeded),
      isEmpty,
      reason: '没有当天策略时不得回退首日上限',
    );
  });
}
