// 任务容量证据的分层用例（1.8.0 专项 §1.6 / §2.3 / Task 4 Step 2）。
//
// ## 这个文件为什么必须存在
//
// 用户报告"七日日历仍有可排空档，生成计划却把任务全部报为可用时间不足"。要修好它，
// 首先得让"可用时间"这件事**可核对**：四个量各有定义、层层收窄，任何一层都不许比上一层大。
//
// | 名称 | 定义 |
// | --- | --- |
// | `calendarGapMinutes` | 窗口扣除固定日程、保护时间、睡眠、锁定块并按粒度对齐后的空闲并集 |
// | `taskWindowMinutes` | 再应用最早开始、截止、允许星期后的并集 |
// | `taskPlaceableMinutes` | 其中满足连续/可拆分、最小/最大片段与粒度的可放置分钟 |
// | `remainingPlaceableMinutes` | 再扣除其它任务已占用后的可放置分钟 |
//
// **必须是区间并集，不能把重叠的候选时长相加**：候选按"起点 × 时长"展开，同一段空闲会
// 产生成百上千个候选；累加它们会把容量放大到没有意义（专项 §7 禁止的捷径之一）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/task_capacity_analyzer.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'UTC';
  // 目标日：2026-10-05 是**周一**。
  final day = DateTime.utc(2026, 10, 5);

  /// 只留出 [free] 这些窗口，其余全部用固定日程占住——这样"日历空闲"就是确定的数字。
  List<BusyInterval> busyExcept(List<TimeRange> free, TimeRange window) {
    final result = <BusyInterval>[];
    var cursor = window.startUtc;
    for (final range in free) {
      if (range.startUtc.isAfter(cursor)) {
        result.add(
          BusyInterval(
            id: 'busy-${cursor.millisecondsSinceEpoch}',
            range: TimeRange(startUtc: cursor, endUtc: range.startUtc),
          ),
        );
      }
      if (range.endUtc.isAfter(cursor)) cursor = range.endUtc;
    }
    if (cursor.isBefore(window.endUtc)) {
      result.add(
        BusyInterval(
          id: 'busy-tail',
          range: TimeRange(startUtc: cursor, endUtc: window.endUtc),
        ),
      );
    }
    return result;
  }

  PlanningRules rules() => PlanningRules(
    energyWindows: const [],
    protectedTimes: const [],
    // 睡眠写成"整天之外"：本文件要控制的是**日历空闲**，不是睡眠。
    sleepRange: LocalTimeRange(startMinute: 0, endMinute: 60),
    minimumSleepMinutes: 60,
    defaultFocusMinutes: 50,
    breakMinutes: 10,
    dailyMovableTaskLimitMinutes: 1440,
    weeklyLifeQuotaMinutes: 0,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
    granularityMinutes: 5,
  );

  SchedulableTask task({
    int requiredMinutes = 60,
    TaskSplitMode splitMode = TaskSplitMode.splittable,
    int minChunk = 30,
    int maxChunk = 90,
    DateTime? availableFromUtc,
    DateTime? dueAtUtc,
    int allowedWeekdaysMask = allWeekdaysMask,
  }) => SchedulableTask(
    id: 'ordinary-a',
    requiredMinutes: requiredMinutes,
    splitMode: splitMode,
    minChunkMinutes: minChunk,
    maxChunkMinutes: maxChunk,
    availableFromUtc: availableFromUtc,
    dueAtUtc: dueAtUtc,
    allowedWeekdaysMask: allowedWeekdaysMask,
  );

  /// 把夹具跑成证据。
  TaskCapacityEvidence evidenceFor({
    required SchedulableTask forTask,
    required TimeRange window,
    required List<TimeRange> free,
    List<PlannedBlock> allBlocks = const [],
  }) {
    final planningRules = rules();
    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: [forTask],
      fixedIntervals: busyExcept(free, window),
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: planningRules,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: window,
        rules: planningRules,
        timeZoneId: zoneId,
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: planningRules,
        timeZoneId: zoneId,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'capacity-evidence',
    );
    final availabilityWindow = problem.planningWindow;
    final availabilityZoneId = problem.timeZoneId;
    final availabilityRules = problem.rules;
    final availability = AvailabilityBuilder(zones).analyze(
      AvailabilityInput(
        planningWindow: availabilityWindow,
        timeZoneId: availabilityZoneId,
        rules: availabilityRules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: zones,
          window: availabilityWindow,
          rules: availabilityRules,
          timeZoneId: availabilityZoneId,
        ),
        fixedIntervals: problem.fixedIntervals.map((i) => i.range).toList(),
      ),
    );
    return analyzeTaskCapacity(
      task: forTask,
      problem: problem,
      availability: availability,
      allBlocks: allBlocks,
      zones: zones,
    );
  }

  /// 四个量的层级不变量（§2.5 第一条）。任何一层越界都必须让测试失败，
  /// **不得**用 `clamp` 静默掩盖。
  void expectLayered(TaskCapacityEvidence evidence) {
    expect(evidence.remainingPlaceableMinutes, greaterThanOrEqualTo(0));
    expect(
      evidence.remainingPlaceableMinutes,
      lessThanOrEqualTo(evidence.taskPlaceableMinutes),
      reason: '剩余可放置分钟不可能超过可放置分钟',
    );
    expect(
      evidence.taskPlaceableMinutes,
      lessThanOrEqualTo(evidence.taskWindowMinutes),
      reason: '可放置分钟不可能超过任务窗口',
    );
    expect(
      evidence.taskWindowMinutes,
      lessThanOrEqualTo(evidence.calendarGapMinutes),
      reason: '任务窗口不可能超过日历空闲',
    );
  }

  test('第一层：09:00–17:00 原始空闲 ⇒ 日历空闲 480 分钟', () {
    final window = TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    );
    final evidence = evidenceFor(
      forTask: task(requiredMinutes: 60),
      window: window,
      free: [
        TimeRange(
          startUtc: day.add(const Duration(hours: 9)),
          endUtc: day.add(const Duration(hours: 17)),
        ),
      ],
    );

    expect(evidence.calendarGapMinutes, 480);
    expect(evidence.taskWindowMinutes, 480);
    expectLayered(evidence);
  });

  test('第二层：availableFrom = 10:00 ⇒ 任务窗口收窄到 420', () {
    final window = TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    );
    final evidence = evidenceFor(
      forTask: task(
        requiredMinutes: 60,
        availableFromUtc: day.add(const Duration(hours: 10)),
      ),
      window: window,
      free: [
        TimeRange(
          startUtc: day.add(const Duration(hours: 9)),
          endUtc: day.add(const Duration(hours: 17)),
        ),
      ],
    );

    expect(evidence.calendarGapMinutes, 480);
    expect(evidence.taskWindowMinutes, 420);
    expectLayered(evidence);
  });

  test('第三层：due = 15:00 ⇒ 任务窗口收窄到 360（并集，不是候选求和）', () {
    final window = TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    );
    final evidence = evidenceFor(
      forTask: task(
        requiredMinutes: 60,
        dueAtUtc: day.add(const Duration(hours: 15)),
      ),
      window: window,
      free: [
        TimeRange(
          startUtc: day.add(const Duration(hours: 9)),
          endUtc: day.add(const Duration(hours: 17)),
        ),
      ],
    );

    // 09:00–15:00 = 360 分钟。**不是 480**：截止把 15:00 之后的两小时切掉了。
    expect(evidence.calendarGapMinutes, 480);
    expect(evidence.taskWindowMinutes, 360);
    expectLayered(evidence);
  });

  test('第四层：只允许周一 ⇒ 周二的空闲不进任务窗口', () {
    final window = TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 2)),
    );
    final free = [
      TimeRange(
        startUtc: day.add(const Duration(hours: 9)),
        endUtc: day.add(const Duration(hours: 17)),
      ),
      TimeRange(
        startUtc: day.add(const Duration(days: 1, hours: 9)),
        endUtc: day.add(const Duration(days: 1, hours: 17)),
      ),
    ];
    final all = evidenceFor(
      forTask: task(requiredMinutes: 60),
      window: window,
      free: free,
    );
    final mondayOnly = evidenceFor(
      forTask: task(
        requiredMinutes: 60,
        // 周一 = bit 0。
        allowedWeekdaysMask: 1,
      ),
      window: window,
      free: free,
    );

    expect(all.taskWindowMinutes, 960);
    expect(mondayOnly.taskWindowMinutes, 480, reason: '周二的 480 分钟被星期掩码裁掉');
    expectLayered(mondayOnly);
  });

  test('第五层：连续 120 分钟，但最长空档 90 ⇒ 可放置分钟为 0', () {
    final window = TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    );
    // 09:00–10:30 与 13:00–14:30 两段各 90 分钟。
    final free = [
      TimeRange(
        startUtc: day.add(const Duration(hours: 9)),
        endUtc: day.add(const Duration(hours: 10, minutes: 30)),
      ),
      TimeRange(
        startUtc: day.add(const Duration(hours: 13)),
        endUtc: day.add(const Duration(hours: 14, minutes: 30)),
      ),
    ];
    final splittable = evidenceFor(
      forTask: task(requiredMinutes: 120, minChunk: 30, maxChunk: 90),
      window: window,
      free: free,
    );
    final continuous = evidenceFor(
      forTask: task(
        requiredMinutes: 120,
        splitMode: TaskSplitMode.continuous,
        minChunk: 120,
        maxChunk: 120,
      ),
      window: window,
      free: free,
    );

    expect(splittable.taskWindowMinutes, 180);
    expect(splittable.taskPlaceableMinutes, 120, reason: '两段各能放 60（可拆分）');
    expect(
      continuous.taskWindowMinutes,
      180,
      reason: '总空闲足够——这正是"总容量"与"能放下"的区别',
    );
    expect(
      continuous.taskPlaceableMinutes,
      0,
      reason: '要求一次做完 120，最长空档只有 90 ⇒ 一个完整区间都没有',
    );
    expect(continuous.largestTaskWindowGapMinutes, 90);
    expectLayered(continuous);
  });

  test('第六层：另一任务先占 30 分钟 ⇒ 只影响剩余可放置分钟', () {
    final window = TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    );
    final free = [
      TimeRange(
        startUtc: day.add(const Duration(hours: 9)),
        endUtc: day.add(const Duration(hours: 10)),
      ),
    ];
    final forTask = task(requiredMinutes: 30);
    final withoutOther = evidenceFor(
      forTask: forTask,
      window: window,
      free: free,
    );
    final withOther = evidenceFor(
      forTask: forTask,
      window: window,
      free: free,
      allBlocks: [
        PlannedBlock(
          id: 'other-1',
          taskId: 'other-b',
          range: TimeRange(
            startUtc: day.add(const Duration(hours: 9)),
            endUtc: day.add(const Duration(hours: 9, minutes: 30)),
          ),
        ),
      ],
    );

    expect(withoutOther.remainingPlaceableMinutes, 30);
    expect(withOther.taskWindowMinutes, withoutOther.taskWindowMinutes);
    expect(
      withOther.taskPlaceableMinutes,
      withoutOther.taskPlaceableMinutes,
      reason: '别的任务的块不影响"这段形状能放多少"，只影响"还剩多少"',
    );
    // **片段间休息也算占用**（`breakMinutes = 10` ⇒ 块两侧各扩 5 分钟）：
    // 09:00–09:30 的块连同缓冲覆盖 08:55–09:35，剩下的 09:35–10:00 只有 25 分钟，
    // 不足一个 30 分钟的最小片段 —— 因此剩余可放置分钟为 0。
    // 这一条同时钉住"休息必须计入剩余容量"：漏掉它会高估容量，
    // 而高估的后果正是把"排不下"说成"排得下"。
    expect(
      withOther.remainingPlaceableMinutes,
      0,
      reason: '唯一的一段被别的任务（连同片段间休息）占走了',
    );
    expect(withOther.largestRemainingGapMinutes, 25);
    expectLayered(withOther);
  });

  test('每日上限余量：逐日剩余量的最大值', () {
    final window = TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 2)),
    );
    final problemLimitRules = rules().copyWith(
      dailyMovableTaskLimitMinutes: 360,
    );
    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: [task()],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: problemLimitRules,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: window,
        rules: problemLimitRules,
        timeZoneId: zoneId,
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: problemLimitRules,
        timeZoneId: zoneId,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'daily-limit',
    );

    // 一块都没有 ⇒ 一分上限没动。
    expect(
      dailyLimitRemainingFor(
        problem: problem,
        zones: zones,
        allBlocks: const [],
      ),
      360,
    );
    // 周一用了 300、周二用了 100 ⇒ 余量分别是 60 与 260，最大值 260。
    expect(
      dailyLimitRemainingFor(
        problem: problem,
        zones: zones,
        allBlocks: [
          PlannedBlock(
            id: 'b1',
            taskId: 'other',
            range: TimeRange(
              startUtc: day.add(const Duration(hours: 9)),
              endUtc: day.add(const Duration(hours: 14)),
            ),
          ),
          PlannedBlock(
            id: 'b2',
            taskId: 'other',
            range: TimeRange(
              startUtc: day.add(const Duration(days: 1, hours: 9)),
              endUtc: day.add(const Duration(days: 1, hours: 10, minutes: 40)),
            ),
          ),
        ],
      ),
      260,
    );
    // 上限不小于一天 ⇒ 整条规则不生效，余量报 0（调用方据此不去归因"每日上限"）。
    final unlimitedRules = rules().copyWith(dailyMovableTaskLimitMinutes: 1440);
    final unlimited = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: [task()],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: unlimitedRules,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: window,
        rules: unlimitedRules,
        timeZoneId: zoneId,
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: unlimitedRules,
        timeZoneId: zoneId,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'daily-limit-off',
    );
    expect(
      dailyLimitRemainingFor(
        problem: unlimited,
        zones: zones,
        allBlocks: const [],
      ),
      0,
    );
  });
}
