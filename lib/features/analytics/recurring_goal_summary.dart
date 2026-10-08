// 统计页上的周期目标摘要（路线图 §3.1 最后一条、§11 Task 9）。
//
// **这个件存在的唯一理由是"不要把它混进领域时间分配"**。周期目标的"已完成 80 分钟"来自
// 专注记录与手动补记，而领域时间分配统计的是**计划块**——两者是不同的事实。加在一起，
// 用户看到的那个"学业 12 小时"就不再是任何一个真实口径。
//
// 因此这里：① 单独一张卡；② 卡里明说它不计入上面的计划时长；③ 汇总项被限制在
// §11 Task 9 给定的五项（目标数量、达标、进行中、未达标、连续达标周数）——多一项就要问
// 它属于哪个口径。
import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_theme.dart';

/// 一个周期周（本地周一为起点）里各状态的数量。
///
/// 用"一周一行、按状态计数"而不是"一周一行、带分钟"：摘要要回答的是"我这一周的目标守住了
/// 吗"，而分钟数属于每个周期自己的详情页。摘要里放分钟会诱使界面把它与计划时长排在一起比较，
/// 那正是 §3.1 要避免的。
final class RecurringGoalWeek {
  const RecurringGoalWeek({
    required this.periodStartLocalDate,
    this.metCount = 0,
    this.inProgressCount = 0,
    this.missedCount = 0,
    this.skippedCount = 0,
  });

  /// 该周的本地周一。
  final DateTime periodStartLocalDate;

  final int metCount;
  final int inProgressCount;
  final int missedCount;
  final int skippedCount;

  int get consideredCount => metCount + inProgressCount + missedCount;
}

/// 汇总结果。字段与 §11 Task 9 的接口一一对应，不多不少。
final class RecurringGoalSummaryData {
  const RecurringGoalSummaryData({
    required this.goalCount,
    required this.metCount,
    required this.inProgressCount,
    required this.missedCount,
    required this.skippedCount,
    required this.consecutiveMetWeeks,
    required this.weeks,
  });

  final int goalCount;
  final int metCount;
  final int inProgressCount;
  final int missedCount;
  final int skippedCount;

  /// 从**最近一周**往回数的连续达标周数。
  final int consecutiveMetWeeks;

  final List<RecurringGoalWeek> weeks;

  bool get isEmpty => goalCount == 0 && weeks.isEmpty;
}

/// 把若干周汇总成摘要。
///
/// **连续周数的判据写在这里，因为它是一条产品判断而不是算数**：
/// - 按 `periodStartLocalDate` **降序**遍历（不依赖调用方的顺序）；
/// - 达标（`metCount > 0`）→ 计数 +1 继续；
/// - **跳过** → 既不加也不断（用户主动跳过不是失败，把它当断点等于惩罚一个正当决定）；
/// - **进行中** → 既不加也不断（这一周还没有结论，虚报连续数会让数字不可信）；
/// - 未达标 → 停止。
///
/// 明确写出"跳过不断、进行中不断"是因为两种写法都能自圆其说；不写下来，下一个人会按自己
/// 的直觉改掉，而用户看到的连续周数会在他没做错任何事的情况下变小。
RecurringGoalSummaryData summarizeRecurringGoals(
  List<RecurringGoalWeek> weeks,
) {
  if (weeks.isEmpty) {
    return const RecurringGoalSummaryData(
      goalCount: 0,
      metCount: 0,
      inProgressCount: 0,
      missedCount: 0,
      skippedCount: 0,
      consecutiveMetWeeks: 0,
      weeks: [],
    );
  }

  final sorted = [...weeks]
    ..sort((a, b) => b.periodStartLocalDate.compareTo(a.periodStartLocalDate));

  var met = 0;
  var inProgress = 0;
  var missed = 0;
  var skipped = 0;
  for (final week in sorted) {
    met += week.metCount;
    inProgress += week.inProgressCount;
    missed += week.missedCount;
    skipped += week.skippedCount;
  }

  var streak = 0;
  for (final week in sorted) {
    // **连续达标周数 = 从最近一周往回数，连续"达标"的周数。**
    // 判据刻意只有一条：这一周达标了吗？没有就停。
    //
    // 一次被我自己写歪、又被测试抓回来的经历值得留在这里：第一版让"跳过"和"进行中"都
    // **不算断点**，理由是"跳过不是失败、进行中还没有结论"。但那两个说法都在偷换概念——
    // 这个数字数的是**连续的达标**，跳过与进行中都不是达标。放宽之后用户会看到一个比事实
    // 更长的连胜（断言 3、实际 2），而这种"看起来更好"的错误数字最难被发现。
    if (week.metCount > 0) {
      streak++;
      continue;
    }
    break;
  }

  return RecurringGoalSummaryData(
    // **目标数量 = 四个状态之和**：跳过单列一项，因此它不在这四项里。
    // §11 Task 9 的接口给了五项计数，这里刻意保持一致。
    goalCount: met + inProgress + missed,
    metCount: met,
    inProgressCount: inProgress,
    missedCount: missed,
    skippedCount: skipped,
    consecutiveMetWeeks: streak,
    weeks: sorted,
  );
}

/// 统计页上的「周期目标」摘要卡。
final class AnalyticsRecurringGoalSummary extends StatelessWidget {
  const AnalyticsRecurringGoalSummary({
    required this.data,
    this.onOpenDetail,
    super.key,
  });

  final RecurringGoalSummaryData data;

  /// 点某一项时打开对应周期的详情。为空时不给入口（不显示死入口）。
  final VoidCallback? onOpenDetail;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('analytics-recurring-goals'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '周期目标',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (onOpenDetail case final open?)
                  TextButton(
                    key: const Key('recurring-goal-open'),
                    onPressed: open,
                    child: const Text('查看详情'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // §3.1 最后一条。这句话是这张卡的**口径声明**，不是装饰：上面那张「计划总时长」
            // 统计的是计划块，这里统计的是目标进度，两者不能相加。
            const Text('目标进度：只看周期目标的完成情况，不计入上面的计划时长。'),
            const SizedBox(height: 14),
            if (data.isEmpty)
              const Text(
                '还没有周期目标。在「任务 → 新建 → 周期目标」里建一个，'
                '这里会显示每周的达标情况。',
              )
            else
              Wrap(
                spacing: 20,
                runSpacing: 12,
                children: [
                  _Metric(
                    metricKey: const Key('recurring-goal-count'),
                    label: '目标数量',
                    value: '${data.goalCount}',
                  ),
                  _Metric(
                    metricKey: const Key('recurring-goal-met'),
                    label: '已达标',
                    value: '${data.metCount}',
                  ),
                  _Metric(
                    metricKey: const Key('recurring-goal-in-progress'),
                    label: '进行中',
                    value: '${data.inProgressCount}',
                  ),
                  _Metric(
                    metricKey: const Key('recurring-goal-missed'),
                    label: '未达标',
                    value: '${data.missedCount}',
                  ),
                  _Metric(
                    metricKey: const Key('recurring-goal-streak'),
                    label: '连续达标',
                    value: '${data.consecutiveMetWeeks} 周',
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

final class _Metric extends StatelessWidget {
  const _Metric({
    required this.metricKey,
    required this.label,
    required this.value,
  });

  final Key metricKey;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: metricKey,
    width: 130,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: PlannerPalette.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: PlannerPalette.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}
