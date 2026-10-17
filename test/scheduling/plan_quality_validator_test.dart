// `PlanQualityValidator` 的结构校验（算法 17，计划 Task 7 Step 3/4）。
//
// 它校验的是"方案自身是否自洽"，与 `PlanValidator` 的"块与固定日程/睡眠/上限
// 是否冲突"是两件事。分开的原因：`_improve` 的每次替换都是**局部**的，
// 局部最优完全可能造出一份结构上已经不成立的块集合，而 `PlanValidator` 看不出来。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/plan_quality_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';

  ScheduleProblem buildProblem({int requiredMinutes = 120}) {
    final window = TimeRange(
      startUtc: zones.localMidnightToUtc(DateTime(2026, 10, 5), zoneId),
      endUtc: zones.localMidnightToUtc(DateTime(2026, 10, 7), zoneId),
    );
    final rules = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 0, endMinute: 360),
      minimumSleepMinutes: 60,
      defaultFocusMinutes: 60,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
      granularityMinutes: 30,
    );
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: [
        SchedulableTask(
          id: 'alpha',
          requiredMinutes: requiredMinutes,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 90,
        ),
      ],
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
      preferences: const PreferenceProfile(),
      inputHash: 'quality-probe',
    );
  }

  DayCapacityLedger buildLedger(ScheduleProblem problem) {
    final availability = AvailabilityBuilder(zones).analyze(
      AvailabilityInput(
        planningWindow: problem.planningWindow,
        timeZoneId: zoneId,
        rules: problem.rules,
        dailyPolicies: problem.dailyPolicies,
      ),
    );
    return buildDayCapacityLedger(
      problem: problem,
      availability: availability,
      baselineBlocks: const [],
      zones: zones,
    );
  }

  PlannedBlock blockAt(String id, DateTime startUtc, int minutes) =>
      PlannedBlock(
        id: id,
        taskId: 'alpha',
        range: TimeRange(
          startUtc: startUtc,
          endUtc: startUtc.add(Duration(minutes: minutes)),
        ),
        explanationCode: 'priority',
      );

  test('**正常方案通过校验**', () {
    final problem = buildProblem();
    final blocks = [
      blockAt(
        'b1',
        zones
            .localMidnightToUtc(DateTime(2026, 10, 5), zoneId)
            .add(const Duration(hours: 8)),
        60,
      ),
      blockAt(
        'b2',
        zones
            .localMidnightToUtc(DateTime(2026, 10, 6), zoneId)
            .add(const Duration(hours: 8)),
        60,
      ),
    ];
    final violations = PlanQualityValidator.validate(
      problem: problem,
      blocks: blocks,
      ledger: buildLedger(problem),
      zones: zones,
      targets: const {'alpha': 120},
    );
    expect(violations, isEmpty, reason: '结构自洽的方案不应有违规：$violations');
  });

  test('**重复块 ID 被拦下**', () {
    final problem = buildProblem(requiredMinutes: 60);
    final start = zones
        .localMidnightToUtc(DateTime(2026, 10, 5), zoneId)
        .add(const Duration(hours: 8));
    final violations = PlanQualityValidator.validate(
      problem: problem,
      blocks: [
        blockAt('dup', start, 30),
        blockAt('dup', start.add(const Duration(hours: 2)), 30),
      ],
      ledger: buildLedger(problem),
      zones: zones,
      targets: const {'alpha': 60},
    );
    expect(
      violations.map((violation) => violation.code),
      contains(PlanQualityViolationCode.duplicateBlockId),
    );
  });

  test('**任务分钟超发被拦下**', () {
    final problem = buildProblem(requiredMinutes: 60);
    final start = zones
        .localMidnightToUtc(DateTime(2026, 10, 5), zoneId)
        .add(const Duration(hours: 8));
    final violations = PlanQualityValidator.validate(
      problem: problem,
      blocks: [blockAt('b1', start, 90)],
      ledger: buildLedger(problem),
      zones: zones,
      targets: const {'alpha': 60},
    );
    expect(
      violations.map((violation) => violation.code),
      contains(PlanQualityViolationCode.taskMinutesExceedTarget),
    );
  });

  test('**超过每日上限被拦下**', () {
    final problem = buildProblem(requiredMinutes: 600);
    final dayStart = zones.localMidnightToUtc(DateTime(2026, 10, 5), zoneId);
    // 同一天放 3 块 × 90 = 270 分钟，而每日上限是 600；先把上限压到 120 观察。
    final tightRules = PlanningRules(
      energyWindows: const [],
      sleepRange: problem.rules.sleepRange,
      minimumSleepMinutes: problem.rules.minimumSleepMinutes,
      defaultFocusMinutes: problem.rules.defaultFocusMinutes,
      breakMinutes: problem.rules.breakMinutes,
      dailyMovableTaskLimitMinutes: 120,
      weeklyLifeQuotaMinutes: 0,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
      granularityMinutes: 30,
    );
    final tight = ScheduleProblem(
      planningWindow: problem.planningWindow,
      timeZoneId: zoneId,
      tasks: problem.tasks,
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: tightRules,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: problem.planningWindow,
        rules: tightRules,
        timeZoneId: zoneId,
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: problem.planningWindow,
        rules: tightRules,
        timeZoneId: zoneId,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'tight-probe',
    );
    final violations = PlanQualityValidator.validate(
      problem: tight,
      blocks: [
        blockAt('b1', dayStart.add(const Duration(hours: 8)), 90),
        blockAt('b2', dayStart.add(const Duration(hours: 10)), 90),
      ],
      ledger: buildLedger(tight),
      zones: zones,
      targets: const {'alpha': 180},
    );
    expect(
      violations.map((violation) => violation.code),
      contains(PlanQualityViolationCode.exceedsDailyHardLimit),
      reason: '同一天 180 分钟超过上限 120，必须被拦下：$violations',
    );
  });

  test('**仍有合法余量却留下缺口 ⇒ 判为"没排好"**', () {
    final problem = buildProblem(requiredMinutes: 120);
    final violations = PlanQualityValidator.validate(
      problem: problem,
      blocks: const [],
      ledger: buildLedger(problem),
      zones: zones,
      targets: const {'alpha': 120},
    );
    expect(
      violations.map((violation) => violation.code),
      contains(PlanQualityViolationCode.unexplainedShortage),
      reason: '账本有余量却一块都没排，这是"没排好"而不是"排不下"',
    );
  });
}
