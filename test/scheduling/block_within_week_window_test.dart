// **块是否落在渲染窗口内**（第 36 轮 §12.5 的收尾检验）。
//
// `week_view_test`「真实源跨页面」在接上跨日分配后，三个页面**一个计划块都没显示**。
// 已排除：引擎不收敛、重复块、isolate、装配层六处。
//
// 剩下的最简解释是：**块确实写进去了，但不在页面渲染的那一周里**。
//
// 该用例的页面周窗口是 `weekStart = todayStartUtc`（本地 2026-10-05 零点），
// 即 10-05 … 10-11 七天。而排程窗口是同一周的周一零点 → 下一个周一零点，
// 共 7 天。两者看似重合——但**跨日分配会改变块落在哪一天**：
// 若把 60 分钟排到窗口**最后一天**（10-11 本地，其 UTC 起点 = 10-11T16:00Z，
// 已接近窗口终点 10-12 本地零点 = 10-11T16:00Z），
// 那么区块间可能贴着窗口边界，页面按自己的周窗口过滤时就可能落到界外。
//
// 这条检验直接回答："块落在哪一天？"
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

  test('**单任务 60 分钟会落在窗口的哪一天**', () {
    final windowStart = zones.localMidnightToUtc(DateTime(2026, 10, 5), zoneId);
    final windowEnd = zones.localMidnightToUtc(DateTime(2026, 10, 12), zoneId);
    final window = TimeRange(startUtc: windowStart, endUtc: windowEnd);
    final rules = PlanningRules(
      energyWindows: const [],
      // 与 `week_view_test` 的生产默认同形：睡眠跨午夜。
      sleepRange: LocalTimeRange(startMinute: 0, endMinute: 6 * 60),
      minimumSleepMinutes: 60,
      defaultFocusMinutes: 60,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
      granularityMinutes: 5,
    );
    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: const [
        SchedulableTask(
          id: 'paper',
          requiredMinutes: 60,
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
      inputHash: 'window-probe',
    );

    final proposal = DeterministicScheduleEngine(zones).generate(problem);
    expect(proposal.blocks, isNotEmpty, reason: '前置条件：必须排出块');

    // 页面渲染的周窗口：本地 10-05 … 10-11（七天）。
    final weekStart = windowStart;
    final weekEnd = windowEnd;

    final outside = <String>[];
    for (final block in proposal.blocks) {
      final local = zones.toLocal(block.startUtc, zoneId);
      final insidePageWindow =
          !block.startUtc.isBefore(weekStart) &&
          block.startUtc.isBefore(weekEnd);
      if (!insidePageWindow) {
        outside.add(
          '${block.startUtc.toIso8601String()} (本地 ${local.month}-${local.day})',
        );
      }
    }

    expect(
      outside,
      isEmpty,
      reason:
          '有块落在页面周窗口之外 ⇒ 页面按自己的周窗口过滤时会把它们全部滤掉，'
          '表现就是"三个页面一个计划块都没有"。落在界外的块：$outside；'
          '全部块：${[for (final block in proposal.blocks) '${block.startUtc.toIso8601String()} +${block.durationMinutes}m']}',
    );
  });
}
