// T4 的剩余部分：真正**能判别**时区换算的场景。
//
// 上一轮我用"把 golden fixture 换个时区"的做法加了一条非 UTC 不变量用例，但变异验证证明它
// 没有判别力——把 `availability_builder` 的"本地钟点 → UTC"换算改成忽略时区后，那条用例
// 照样通过，因为 golden fixture 容量宽裕，引擎把块放进"两种解释都允许"的区间就够了。
// 结论：**不变量只有在场景强迫出差异时才有判别力**。本文件就构造这样一个场景。
//
// 场景（全部绝对时刻，便于对照）：
//   * 规划窗口：2026-11-02T00:00Z – 2026-11-03T00:00Z（纽约已回到 EST，UTC-5）
//   * 睡眠规则：本地 20:00–08:00（**本地钟点**，跨零点）
//   * 固定日程：13:00Z – 次日 01:00Z
//
//   正确语义（本地 → UTC，睡眠 = 01:00Z–13:00Z）：
//       空闲 = 13:00Z–01:00Z，而固定日程正好盖住它 → **当天无任何空闲**，任务排不下。
//   变异语义（把本地钟点当 UTC，睡眠 = 20:00Z–08:00Z）：
//       空闲 = 08:00Z–20:00Z，固定日程只盖住其中 13:00Z–20:00Z → 剩 08:00Z–13:00Z 可排。
//
// 两种语义对"这个任务当天能不能排"给出**相反结论**，因此这条用例天然能判别换算是否正确。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final zones = TimeZoneDatabase();
  final engine = DeterministicScheduleEngine(zones);

  ScheduleProblem problem(String timeZoneId) => ScheduleProblem(
    planningWindow: TimeRange(
      // 起点取 01:00Z：纽约 EST 下本地 20:00（睡眠开始）恰好是 01:00Z，因此窗口内除睡眠与
      // 固定日程外**没有**余量。首版我用了 00:00Z，结果 00:00Z–01:00Z（本地 19:00–20:00）
      // 仍是空闲，引擎把块排在那里——那说明引擎正确、我的场景不够紧，故收紧一小时。
      startUtc: DateTime.utc(2026, 11, 2, 1),
      endUtc: DateTime.utc(2026, 11, 3, 1),
    ),
    timeZoneId: timeZoneId,
    tasks: const [
      SchedulableTask(
        id: 'task-1',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
        priority: TaskPriority.medium,
        energyLevel: TaskEnergyLevel.medium,
        isLifeTask: false,
      ),
    ],
    fixedIntervals: [
      BusyInterval(
        id: 'blocked',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 11, 2, 13),
          endUtc: DateTime.utc(2026, 11, 3, 1),
        ),
      ),
    ],
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: PlanningRules(
      energyWindows: [
        EnergyWindow(
          range: LocalTimeRange(startMinute: 8 * 60, endMinute: 20 * 60),
          level: EnergyLevel.high,
        ),
      ],
      sleepRange: LocalTimeRange(startMinute: 20 * 60, endMinute: 8 * 60),
      minimumSleepMinutes: 420,
      defaultFocusMinutes: 50,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 360,
      weeklyLifeQuotaMinutes: 60,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'time-zone-discriminator-v1',
  );

  test('纽约时区下每天毫无空闲，任务必须报出缺口', () {
    final proposal = engine.generate(problem('America/New_York'));

    // 睡眠（01:00Z–13:00Z）与固定日程（13:00Z–01:00Z）合起来占满整天，因此没有块可排，
    // 缺口必须如实报出，而不是"排进去了但落在睡眠里"。
    expect(proposal.blocks, isEmpty);
    expect(
      proposal.unscheduled.single.shortageMinutes,
      60,
      reason: '排不下时必须如实报告缺口',
    );
    expect(proposal.metrics.isFullyFeasible, isFalse);
  });

  test('同一问题换成 UTC 时区后可以排下——证明结论确实取决于时区', () {
    final proposal = engine.generate(problem('UTC'));

    // UTC 下睡眠是 20:00Z–08:00Z，空闲为 08:00Z–20:00Z，固定日程只占 13:00Z–20:00Z，
    // 于是 08:00Z–13:00Z 可排下这 60 分钟。若引擎无视时区，上一条用例就会变成这一条的结果。
    expect(proposal.unscheduled, isEmpty);
    expect(
      proposal.blocks.fold<int>(0, (sum, b) => sum + b.range.durationMinutes),
      60,
    );
  });
}
