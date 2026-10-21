// 1.11.0（计划 Task 6 Step 1、DFR-024）：同一放置必须在统一判定器与最终校验
// 之间得到**相同结论**。这里对每个夹具同时跑两者并比对首要原因。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_hard_constraint_evaluator.dart';
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

  const task = SchedulableTask(
    id: 'task-a',
    requiredMinutes: 120,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 15,
    maxChunkMinutes: 90,
  );

  PlannedBlock block({
    String id = 'b1',
    String taskId = 'task-a',
    required DateTime start,
    int minutes = 60,
    bool locked = false,
  }) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
    locked: locked,
  );

  ScheduleProblem problem({
    List<SchedulableTask> tasks = const [task],
    PlanningRules? rules,
    List<BusyInterval> fixed = const [],
    List<BusyInterval> protected = const [],
    List<PlannedBlock> locked = const [],
  }) {
    final resolved = rules ?? DefaultSettings.v1().copyWith(breakMinutes: 10);
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: tasks,
      fixedIntervals: fixed,
      protectedIntervals: protected,
      lockedBlocks: locked,
      rules: resolved,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: window,
        rules: resolved,
        timeZoneId: zoneId,
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: resolved,
        timeZoneId: zoneId,
      ),
      existingBlocks: const [],
      preferences: const PreferenceProfile(),
      inputHash: 'hash',
    );
  }

  test('固定日程冲突：判定器与 validator 都报固定冲突', () {
    final p = problem(
      fixed: [
        BusyInterval(
          id: 'fixed-1',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 19, 9),
            endUtc: DateTime.utc(2026, 10, 19, 9, 30),
          ),
        ),
      ],
    );
    final placement = block(start: DateTime.utc(2026, 10, 19, 9));

    final violations = PlanHardConstraintEvaluator(zones).validatePlacement(
      task: task,
      block: placement,
      context: HardConstraintContext(
        problem: p,
        nowUtc: p.planningWindow.startUtc,
      ),
    );
    final conflicts = PlanValidator(zones).validate(p, [placement]);

    expect(violations.first.code, HardConstraintCode.fixedConflict);
    expect(
      conflicts.map((c) => c.code),
      contains(ConflictCode.fixedEventOverlap),
    );
  });

  test('保护时间冲突：判定器 protectedConflict，validator protectedTimeOverlap', () {
    final p = problem(
      protected: [
        BusyInterval(
          id: 'p-1',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 19, 12),
            endUtc: DateTime.utc(2026, 10, 19, 13),
          ),
        ),
      ],
    );
    final placement = block(start: DateTime.utc(2026, 10, 19, 12, 30));

    final violations = PlanHardConstraintEvaluator(zones).validatePlacement(
      task: task,
      block: placement,
      context: HardConstraintContext(
        problem: p,
        nowUtc: p.planningWindow.startUtc,
      ),
    );
    final conflicts = PlanValidator(zones).validate(p, [placement]);

    expect(violations.first.code, HardConstraintCode.protectedConflict);
    expect(
      conflicts.map((c) => c.code),
      contains(ConflictCode.protectedTimeOverlap),
    );
  });

  test('窗口外、早于 availableFrom、晚于截止、禁止星期各自给出独立码', () {
    final evaluator = PlanHardConstraintEvaluator(zones);
    final restrictive = SchedulableTask(
      id: 'task-a',
      requiredMinutes: 120,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 15,
      maxChunkMinutes: 90,
      availableFromUtc: DateTime.utc(2026, 10, 19, 10),
      dueAtUtc: DateTime.utc(2026, 10, 19, 11),
      // 只允许周一（2026-10-19 是周一），10-20 是周二。
      allowedWeekdaysMask: 1 << (DateTime.monday - DateTime.monday),
    );
    final p = problem(tasks: [restrictive]);
    final context = HardConstraintContext(
      problem: p,
      nowUtc: p.planningWindow.startUtc,
    );

    expect(
      evaluator
          .validatePlacement(
            task: restrictive,
            block: block(start: DateTime.utc(2026, 10, 18, 9)),
            context: context,
          )
          .first
          .code,
      HardConstraintCode.outsidePlanningWindow,
    );
    expect(
      evaluator
          .validatePlacement(
            task: restrictive,
            block: block(start: DateTime.utc(2026, 10, 19, 9)),
            context: context,
          )
          .first
          .code,
      HardConstraintCode.beforeAvailableFrom,
    );
    expect(
      evaluator
          .validatePlacement(
            task: restrictive,
            block: block(start: DateTime.utc(2026, 10, 19, 10, 30)),
            context: context,
          )
          .first
          .code,
      HardConstraintCode.afterDeadline,
    );
    expect(
      evaluator
          .validatePlacement(
            task: restrictive,
            block: block(start: DateTime.utc(2026, 10, 20, 11)),
            context: context,
          )
          .map((v) => v.code),
      contains(HardConstraintCode.disallowedWeekday),
    );
  });

  test('片段超长与不在网格上分别报 invalidChunkDuration / offGrid', () {
    final evaluator = PlanHardConstraintEvaluator(zones);
    final p = problem();
    final context = HardConstraintContext(
      problem: p,
      nowUtc: p.planningWindow.startUtc,
    );

    expect(
      evaluator
          .validatePlacement(
            task: task,
            block: block(start: DateTime.utc(2026, 10, 19, 9), minutes: 120),
            context: context,
          )
          .map((v) => v.code),
      contains(HardConstraintCode.invalidChunkDuration),
    );
    expect(
      evaluator
          .validatePlacement(
            task: task,
            block: block(start: DateTime.utc(2026, 10, 19, 9, 3)),
            context: context,
          )
          .map((v) => v.code),
      contains(HardConstraintCode.offGrid),
    );
  });

  test('与其他计划块重叠报 planBlockConflict', () {
    final other = block(
      id: 'b2',
      taskId: 'task-b',
      start: DateTime.utc(2026, 10, 19, 9, 30),
    );
    final placement = block(start: DateTime.utc(2026, 10, 19, 9));
    final p = problem(
      tasks: const [
        task,
        SchedulableTask(
          id: 'task-b',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 15,
          maxChunkMinutes: 90,
        ),
      ],
    );

    final violations = PlanHardConstraintEvaluator(zones).validatePlacement(
      task: task,
      block: placement,
      context: HardConstraintContext(
        problem: p,
        nowUtc: p.planningWindow.startUtc,
      ),
      otherBlocks: [other],
    );

    expect(
      violations.map((v) => v.code),
      contains(HardConstraintCode.planBlockConflict),
    );
  });

  test('整份计划的每日上限与休息由同一判定器给出（validator 只做码翻译）', () {
    final p = problem(
      rules: DefaultSettings.v1().copyWith(
        dailyMovableTaskLimitMinutes: 60,
        breakMinutes: 20,
      ),
    );
    final blocks = [
      block(id: 'b1', start: DateTime.utc(2026, 10, 19, 9), minutes: 60),
      block(
        id: 'b2',
        taskId: 'task-b',
        start: DateTime.utc(2026, 10, 19, 10, 5),
        minutes: 60,
      ),
    ];
    final pWithTaskB = problem(
      tasks: const [
        task,
        SchedulableTask(
          id: 'task-b',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 15,
          maxChunkMinutes: 90,
        ),
      ],
      rules: p.rules,
    );

    final violations = PlanHardConstraintEvaluator(zones).validatePlan(
      blocks: blocks,
      context: HardConstraintContext(
        problem: pWithTaskB,
        nowUtc: pWithTaskB.planningWindow.startUtc,
      ),
    );
    final conflicts = PlanValidator(zones).validate(pWithTaskB, blocks);

    expect(
      violations.map((v) => v.code),
      containsAll([
        HardConstraintCode.taskDailyLimitReached,
        HardConstraintCode.requiredBreakUnavailable,
      ]),
    );
    expect(
      conflicts.map((c) => c.code),
      containsAll([
        ConflictCode.dailyLimitExceeded,
        ConflictCode.requiredBreakUnavailable,
      ]),
    );
  });
}
