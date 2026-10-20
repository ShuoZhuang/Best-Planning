// 1.11.0（计划 Task 6 Step 1/6、DFR-024）：候选资格与统一硬约束判定器必须
// 对同一个候选给出**相同结论**。
//
// 候选资格保留了自己的快速路径（单次生成有数百万次判定，逐候选构造完整
// `HardConstraintViolation` 列表会显著拖慢放置阶段），因此这里用**等价性用例**
// 守住"两套实现语义一致"，而不是逐候选调用判定器。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/candidate_eligibility.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/plan_hard_constraint_evaluator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'UTC';
  final window = TimeRange(
    startUtc: DateTime.utc(2026, 10, 19),
    endUtc: DateTime.utc(2026, 10, 21),
  );
  final localDay = DateTime(2026, 10, 19);

  const task = SchedulableTask(
    id: 'task-a',
    requiredMinutes: 60,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 15,
    maxChunkMinutes: 90,
  );
  const other = SchedulableTask(
    id: 'task-b',
    requiredMinutes: 60,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 15,
    maxChunkMinutes: 90,
  );

  ScheduleProblem problem({int breakMinutes = 10, int dailyLimit = 240}) {
    final rules = DefaultSettings.v1().copyWith(
      breakMinutes: breakMinutes,
      dailyMovableTaskLimitMinutes: dailyLimit,
    );
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: const [task, other],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: rules,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: window,
        rules: rules,
        timeZoneId: zoneId,
      ),
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

  PlannedBlock block(String id, DateTime start, int minutes) => PlannedBlock(
    id: id,
    taskId: 'task-b',
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
  );

  CandidateEligibilityContext contextFor(
    ScheduleProblem p, {
    required List<PlannedBlock> blocks,
    int placedMinutes = 0,
  }) => CandidateEligibilityContext(
    problem: p,
    task: task,
    remainingMinutes: 60,
    blocks: blocks,
    movableMinutesByDate: {localDay: placedMinutes},
    plannedMinutesForTaskByDate: const {},
    policies: PolicyLookupCache.forProblem(p),
    allowUnschedulableLeftover: true,
  );

  SchedulingCandidate candidate(DateTime start, {int minutes = 60}) =>
      SchedulingCandidate(
        id: 'candidate',
        taskId: 'task-a',
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(Duration(minutes: minutes)),
        ),
        localDate: localDay,
      );

  bool eligibilityRejects(
    CandidateEligibilityContext context,
    SchedulingCandidate value,
    CandidateRejectionCode code,
  ) => evaluateCandidateEligibility(
    context,
    value,
  ).any((rejection) => rejection.code == code);

  test('紧贴已有块：候选资格报休息不足，判定器报 requiredBreakUnavailable', () {
    final p = problem();
    final existing = block('b1', DateTime.utc(2026, 10, 19, 9), 60);
    final context = contextFor(p, blocks: [existing]);
    final value = candidate(DateTime.utc(2026, 10, 19, 10));

    expect(
      eligibilityRejects(
        context,
        value,
        CandidateRejectionCode.violatesRequiredBreak,
      ),
      isTrue,
    );
    final violations = PlanHardConstraintEvaluator(zones).validatePlacement(
      task: task,
      block: PlannedBlock(
        id: 'candidate',
        taskId: 'task-a',
        range: value.range,
      ),
      context: HardConstraintContext(
        problem: p,
        nowUtc: p.planningWindow.startUtc,
      ),
      otherBlocks: [existing],
    );
    expect(
      violations.map((v) => v.code),
      contains(HardConstraintCode.requiredBreakUnavailable),
    );
  });

  test('间隔满足休息：两侧都接受', () {
    final p = problem();
    final existing = block('b1', DateTime.utc(2026, 10, 19, 9), 60);
    final context = contextFor(p, blocks: [existing]);
    final value = candidate(DateTime.utc(2026, 10, 19, 10, 10));

    expect(
      eligibilityRejects(
        context,
        value,
        CandidateRejectionCode.violatesRequiredBreak,
      ),
      isFalse,
    );
    final violations = PlanHardConstraintEvaluator(zones).validatePlacement(
      task: task,
      block: PlannedBlock(
        id: 'candidate',
        taskId: 'task-a',
        range: value.range,
      ),
      context: HardConstraintContext(
        problem: p,
        nowUtc: p.planningWindow.startUtc,
      ),
      otherBlocks: [existing],
    );
    expect(violations, isEmpty);
  });

  test('超过全局日上限：候选资格报 exceedsDailyMovableLimit，判定器报 taskDailyLimitReached', () {
    final p = problem(dailyLimit: 60);
    final existing = block('b1', DateTime.utc(2026, 10, 19, 9), 30);
    final context = contextFor(p, blocks: [existing], placedMinutes: 30);
    final value = candidate(DateTime.utc(2026, 10, 19, 11));

    expect(
      eligibilityRejects(
        context,
        value,
        CandidateRejectionCode.exceedsDailyMovableLimit,
      ),
      isTrue,
    );
    final violations = PlanHardConstraintEvaluator(zones).validatePlan(
      blocks: [
        existing,
        PlannedBlock(id: 'candidate', taskId: 'task-a', range: value.range),
      ],
      context: HardConstraintContext(
        problem: p,
        nowUtc: p.planningWindow.startUtc,
      ),
    );
    expect(
      violations.map((v) => v.code),
      contains(HardConstraintCode.taskDailyLimitReached),
    );
  });

  test('与已有块重叠：候选资格报 overlapsExistingBlock，判定器报 planBlockConflict', () {
    final p = problem();
    final existing = block('b1', DateTime.utc(2026, 10, 19, 9), 60);
    final context = contextFor(p, blocks: [existing]);
    final value = candidate(DateTime.utc(2026, 10, 19, 9, 30));

    expect(
      eligibilityRejects(
        context,
        value,
        CandidateRejectionCode.overlapsExistingBlock,
      ),
      isTrue,
    );
    final violations = PlanHardConstraintEvaluator(zones).validatePlacement(
      task: task,
      block: PlannedBlock(
        id: 'candidate',
        taskId: 'task-a',
        range: value.range,
      ),
      context: HardConstraintContext(
        problem: p,
        nowUtc: p.planningWindow.startUtc,
      ),
      otherBlocks: [existing],
    );
    expect(
      violations.map((v) => v.code),
      contains(HardConstraintCode.planBlockConflict),
    );
  });
}

