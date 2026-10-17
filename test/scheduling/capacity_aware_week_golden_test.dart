// **容量感知黄金夹具**（计划 Task 13 Step 2）。
//
// 它冻结的是算法 17 的三件事**联合**起来的行为，单独任何一件都测不出来：
//
//   ① 逐日规则：周末的每日上限是 360，不是复制窗口首日（周一）的 180；
//   ② 单一账本：工作日真正的可用空档只有 12:00–13:20，去掉缓冲剩 70 分钟；
//   ③ 跨日分配：按方案级目标挑日期，于是**周末被用上**，而不是把工作日堆满。
//
// 为什么这条不能用 `golden_week.json` 承担：那份夹具的规则是**一套铺满整个窗口**，
// 而这里必须让工作日与周末有**不同的每日上限**——那正是算法 17 要修的东西。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();

  test('容量感知黄金周：工作日繁忙、周末空闲时，普通任务必须用上周末', () {
    final fixture = jsonDecode(
      File('test/fixtures/scheduling/capacity_aware_week.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;

    final zoneId = fixture['timeZoneId']! as String;
    final rulesJson = fixture['rules']! as Map<String, Object?>;
    final rules = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(
        startMinute: rulesJson['sleepStartMinute']! as int,
        endMinute: rulesJson['sleepEndMinute']! as int,
      ),
      minimumSleepMinutes: rulesJson['minimumSleepMinutes']! as int,
      defaultFocusMinutes: rulesJson['defaultFocusMinutes']! as int,
      breakMinutes: rulesJson['breakMinutes']! as int,
      dailyMovableTaskLimitMinutes: fixture['weekdayDailyLimitMinutes']! as int,
      weeklyLifeQuotaMinutes: rulesJson['weeklyLifeQuotaMinutes']! as int,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
      granularityMinutes: rulesJson['granularityMinutes']! as int,
    );

    DateTime localMidnight(String isoDate) {
      final date = DateTime.parse(isoDate);
      return zones.localMidnightToUtc(
        DateTime(date.year, date.month, date.day),
        zoneId,
      );
    }

    final window = TimeRange(
      startUtc: localMidnight(fixture['planningStartLocalDate']! as String),
      endUtc: localMidnight(fixture['planningEndLocalDate']! as String),
    );

    final busy = [
      for (final item
          in (fixture['busy']! as List<Object?>).cast<Map<String, Object?>>())
        BusyInterval(
          id: item['id']! as String,
          range: TimeRange(
            startUtc: localMidnight(item['localDate']! as String)
                .add(Duration(minutes: item['startMinute']! as int)),
            endUtc: item['endMinute']! as int == 1440
                ? localMidnight(
                    DateTime.parse(item['localDate']! as String)
                        .add(const Duration(days: 1))
                        .toIso8601String()
                        .substring(0, 10),
                  )
                : localMidnight(item['localDate']! as String)
                      .add(Duration(minutes: item['endMinute']! as int)),
          ),
        ),
    ];

    // **逐日策略**：工作日 180、周末 360。这是本夹具与 `golden_week.json` 的关键差异。
    final weekendLimit = fixture['weekendDailyLimitMinutes']! as int;
    final weekendRules = PlanningRules(
      energyWindows: const [],
      sleepRange: rules.sleepRange,
      minimumSleepMinutes: rules.minimumSleepMinutes,
      defaultFocusMinutes: rules.defaultFocusMinutes,
      breakMinutes: rules.breakMinutes,
      dailyMovableTaskLimitMinutes: weekendLimit,
      weeklyLifeQuotaMinutes: rules.weeklyLifeQuotaMinutes,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
      granularityMinutes: rules.granularityMinutes,
    );
    final basePolicies = dailyPoliciesForWindow(
      zones: zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    );
    final dailyPolicies = <DateTime, DailySchedulingPolicy>{
      for (final entry in basePolicies.entries)
        entry.key: DailySchedulingPolicy(
          localDate: entry.key,
          // 周六/周日（6/7）用周末规则，其余用工作日规则。
          resolvedRules: entry.key.weekday >= DateTime.saturday
              ? weekendRules
              : rules,
          softReserveTargetMinutes: 0,
        ),
    };

    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: [
        for (final item
            in (fixture['tasks']! as List<Object?>)
                .cast<Map<String, Object?>>())
          SchedulableTask(
            id: item['id']! as String,
            requiredMinutes: item['minutes']! as int,
            splitMode: TaskSplitMode.values.byName(
              item['splitMode']! as String,
            ),
            minChunkMinutes: item['minChunk']! as int,
            maxChunkMinutes: item['maxChunk']! as int,
            dueAtUtc: item['due'] == null
                ? null
                : DateTime.parse(item['due']! as String),
            priority: TaskPriority.values.byName(item['priority']! as String),
            energyLevel: TaskEnergyLevel.values.byName(
              item['energy']! as String,
            ),
            isLifeTask: item['life']! as bool,
          ),
      ],
      fixedIntervals: busy,
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: rules,
      dailyPolicies: dailyPolicies,
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: rules,
        timeZoneId: zoneId,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'capacity-aware-week-v1',
    );

    final proposal = DeterministicScheduleEngine(zones).generate(problem);
    final expected = fixture['expected']! as Map<String, Object?>;

    expect(proposal.algorithmVersion, expected['algorithmVersion']);

    final minutesByDay = <int, int>{};
    for (final block in proposal.blocks) {
      final local = zones.toLocal(block.startUtc, zoneId);
      minutesByDay[local.day] =
          (minutesByDay[local.day] ?? 0) + block.durationMinutes;
    }

    expect(
      minutesByDay.values.fold<int>(0, (sum, value) => sum + value),
      expected['totalScheduledMinutes'],
      reason: '工作日凑得下 150 分钟，因此目标必须完整排下；实际 $minutesByDay',
    );
    expect(
      proposal.unscheduled.fold<int>(
        0,
        (sum, item) => sum + item.shortageMinutes,
      ),
      expected['shortageMinutes'],
      reason: '排得下就不该有缺口；实际 $minutesByDay',
    );

    // **本夹具的核心判据**：至少一个块落在周末。
    //
    // 工作日单个只有 70 分钟空档、五天合计 300 分钟，所以"排得下"完全不要求用周末——
    // 只有方案级目标真的比较了跨日负载，周末才会被挑中。
    final weekendMinutes = (minutesByDay[10] ?? 0) + (minutesByDay[11] ?? 0);
    expect(
      weekendMinutes,
      greaterThan(0),
      reason:
          '周末负载 0%、工作日约 70%；至少一个块必须落在周末。'
          '算法 16 会把工作日堆满而周末保持为 0（实际 $minutesByDay）',
    );

    // 逐日上限逐日生效：任一工作日不得超过它自己的 180 分钟。
    final weekdayCap = expected['weekdayCapMinutes']! as int;
    for (final day in [5, 6, 7, 8, 9]) {
      expect(
        minutesByDay[day] ?? 0,
        lessThanOrEqualTo(weekdayCap),
        reason: '第 $day 天超过工作日上限 $weekdayCap；实际 $minutesByDay',
      );
    }
  });
}
