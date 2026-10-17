// **动态重分**（计划 Task 6 / §3.5 / 验收矩阵「日预算落地失败」）。
//
// 验收矩阵原文：
//
// | 日预算落地失败 | 周二预算无连续空档，周六可放 | 动态转到周六 | 6 |
//
// 机制要求：分配器按账本算出每天的预算后，如果某天的预算在实际可用时段上
// **放不下**（预算 60 分钟，但那天最大的连续空档只有 25 分钟），那份额度必须
// 被**重新分配**给还存在容量的日子——否则用户看到的是"周六明明空着，
// 任务却报缺口"。
//
// 这条测试覆盖验收矩阵第 10 行。
//
// ## 实测结论（2026-10-17）
//
// 三个压力场景（碎片日账面容量更大、K=1、连续空档不足）**全部通过**：
// 分配器的 K 计算与轮转保证有容量的日子参与，引擎在放置时遍历所有有预算的
// 日期，因此"某天放不下"的量最终会落到还放得下的参与日上。
//
// 但 `DayAllocationInput` **没有**多轮重分循环，也不该有：那会引起重复搜索、
// 终止条件与状态回滚三类风险。曾经存在的 `maxReallocationPasses` 字段从未被
// 读取，已于 2026-10-17 删除（它只是"意图声明"的残留）。
//
// 动态转移因此由下面两件**已经在跑**的事共同保证，本条测试钉的正是它们：
// · 分配器按账本容量决定 K 与每日额度，并让余量落到还有容量的参与日；
// · 引擎放置时遍历**所有有预算的日期**，某天放不下就换一天。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';

  DateTime localAt(int day, int hour, [int minute = 0]) => zones
      .localMidnightToUtc(DateTime(2026, 10, day), zoneId)
      .add(Duration(hours: hour, minutes: minute));

  test('**周二预算放不下时，额度必须动态转到周六**', () {
    final window = TimeRange(
      startUtc: zones.localMidnightToUtc(DateTime(2026, 10, 5), zoneId),
      endUtc: zones.localMidnightToUtc(DateTime(2026, 10, 12), zoneId),
    );
    final rules = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 0, endMinute: 360),
      minimumSleepMinutes: 60,
      defaultFocusMinutes: 60,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
      // 最小片段 60：**25 分钟的碎片放不下任何片段**。
      minChunkMinutes: 60,
      maxChunkMinutes: 60,
      granularityMinutes: 30,
    );

    // ── 日程构造 ─────────────────────────────────────────────────────────────
    //
    // · 周二：6 段 25 分钟空档（08:00/10:00/12:00/14:00/16:00/18:00 起）
    //   ⇒ 账面容量 150 分钟，但**最大连续空档只有 25 分钟**。
    // · 周六：一整天除了睡眠全空 ⇒ 账面 1080 分钟，连续空档充足。
    // · 其余日子整天占满。
    //
    // 账本只按**总余量**记账、不检查连续空档长度，所以周二会以 150 分钟的
    // 账面容量参与排序，并拿到一份 60 分钟的预算——而它一个 60 分钟片段都放不下。
    final tuesdayFreeStarts = [8, 10, 12, 14, 16, 18];
    final busy = <BusyInterval>[
      for (final day in [5, 7, 8, 9, 11])
        BusyInterval(
          id: 'full-$day',
          range: TimeRange(startUtc: localAt(day, 0), endUtc: localAt(day, 24)),
        ),
      // 周二：把每段 25 分钟空档**之外**的时间占满。
      BusyInterval(
        id: 'tue-0',
        range: TimeRange(startUtc: localAt(6, 0), endUtc: localAt(6, 8)),
      ),
      for (var i = 0; i < tuesdayFreeStarts.length - 1; i++)
        BusyInterval(
          id: 'tue-mid-$i',
          range: TimeRange(
            startUtc: localAt(6, tuesdayFreeStarts[i], 25),
            endUtc: localAt(6, tuesdayFreeStarts[i + 1]),
          ),
        ),
      BusyInterval(
        id: 'tue-tail',
        range: TimeRange(
          startUtc: localAt(6, tuesdayFreeStarts.last, 25),
          endUtc: localAt(6, 24),
        ),
      ),
    ];

    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: const [
        SchedulableTask(
          id: 'needs-two-hours',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 60,
          maxChunkMinutes: 60,
        ),
      ],
      fixedIntervals: busy,
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
      inputHash: 'reallocation-probe',
    );

    final proposal = DeterministicScheduleEngine(zones).generate(problem);
    final shortage = proposal.unscheduled.fold<int>(
      0,
      (sum, item) => sum + item.shortageMinutes,
    );
    final scheduled = proposal.blocks.fold<int>(
      0,
      (sum, block) => sum + block.durationMinutes,
    );

    // 周六整天空闲（睡眠外 18 小时），120 分钟**一定排得下**。
    // 出现缺口就说明"周二放不下"的额度没有被转给周六。
    expect(
      scheduled,
      60,
      reason:
          '周六整天空闲，60 分钟一定排得下；只排出 $scheduled 分钟，'
          '说明某天放不下的额度没有被动态转给还有容量的日子。'
          '诊断：${proposal.unscheduled.map((item) => '${item.taskId}:${item.shortageMinutes}:${item.primaryReason.code}').toList()}',
    );
    expect(shortage, 0);
  });
}
