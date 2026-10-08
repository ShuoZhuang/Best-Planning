import 'dart:math' as math;

import 'package:personal_planner/domain/models/task.dart';

/// 排序一个周期目标所需的事实（路线图 §3.4）。
///
/// **为什么单独成类型而不是把七八个参数平铺**：这些量各自都有明确的"从哪来"，把它们绑成
/// 一个值对象之后，`rankRecurringTask` 就成为一个**纯函数**——同样的输入必然给同样的排序，
/// 而这正是 §7.2 最后一条（"三个以上周期目标竞争时，结果不依赖数据库返回顺序"）要靠的东西。
final class RecurringSchedulingContext {
  const RecurringSchedulingContext({
    required this.templateId,
    required this.priority,
    required this.energyLevel,
    required this.remainingMinutes,
    required this.targetMinutes,
    required this.daysUntilPeriodEnd,
    required this.allowedWeekdayCount,
    this.squeezedCount = 0,
  }) : assert(remainingMinutes >= 0),
       assert(targetMinutes > 0),
       assert(daysUntilPeriodEnd >= 0),
       assert(allowedWeekdayCount >= 1),
       assert(squeezedCount >= 0);

  final String templateId;
  final TaskPriority priority;
  final TaskEnergyLevel energyLevel;

  /// 这一周还差多少分钟（`RecurringProgress.remainingMinutes`）。
  final int remainingMinutes;

  /// 这一周的有效目标（含结转）。
  final int targetMinutes;

  /// 距本周结束还有几天。**0 表示今天就是最后一天**。
  final int daysUntilPeriodEnd;

  /// 模板允许的星期数（1..7）。"仅指定星期"越窄，可安排的窗口越少，越该早排。
  final int allowedWeekdayCount;

  /// **连续被挤压的次数**（路线图 §3.4 明确列出的排序依据）。
  ///
  /// 定义：这个目标在**最近几次生成里一次都没被排进去**的次数。它存在的理由是实测过的
  /// 一个现象——容量紧张时，只要排序规则只看优先级与剩余比例，同一个低优先级目标会
  /// **每一次都被挤掉**，而它永远不会变"更该被安排"，于是永远排不进去。把被挤压次数计入
  /// 排序是唯一的出路：被挤得越多，下一次越优先。
  final int squeezedCount;

  /// 剩余比例（0..1 以上）。**越低越该优先**：剩得少的目标更容易做完，先做完它
  /// 才能把后面的容量腾出来（与"尽早清空"一致）。
  double get remainingRatio =>
      targetMinutes == 0 ? 0 : remainingMinutes / targetMinutes;

  /// 剩余时间越紧越该优先：`daysUntilPeriodEnd == 0` 时权重最高。
  double get urgency =>
      daysUntilPeriodEnd == 0 ? 1 : 1 / (daysUntilPeriodEnd + 1);

  /// 允许星期越窄，可落点越少，越该早排。
  double get narrowness => (8 - allowedWeekdayCount) / 7;

  RecurringSchedulingContext copyWith({
    int? remainingMinutes,
    int? daysUntilPeriodEnd,
    int? squeezedCount,
  }) => RecurringSchedulingContext(
    templateId: templateId,
    priority: priority,
    energyLevel: energyLevel,
    remainingMinutes: remainingMinutes ?? this.remainingMinutes,
    targetMinutes: targetMinutes,
    daysUntilPeriodEnd: daysUntilPeriodEnd ?? this.daysUntilPeriodEnd,
    allowedWeekdayCount: allowedWeekdayCount,
    squeezedCount: squeezedCount ?? this.squeezedCount,
  );
}

/// 一个周期目标在排程中的名次（路线图 §3.4、§11 Task 8）。
///
/// **这是一个纯计算的结果，不是第二套排程器**：它只给出一个整数名次与"为什么是这个名次"
/// 的分解，真正的"排在哪一天、哪个片段"仍然由既有的 `DeterministicScheduleEngine` 决定。
/// 之所以要保留分解，是因为 §3.4 要求"计划说明至少能给出：本周剩余、距截止天数、精力匹配、
/// 均匀分布、容量不足"——而排序本身如果是个黑箱，说明就只能靠编。
final class RecurringTaskRank {
  const RecurringTaskRank({
    required this.templateId,
    required this.score,
    required this.priorityComponent,
    required this.urgencyComponent,
    required this.remainingComponent,
    required this.squeezedComponent,
    required this.narrownessComponent,
    required this.rationale,
  });

  final String templateId;

  /// 总分。**越大越该先安排**（与 `_compareTasks` 里"优先级 index 降序"同一方向）。
  final int score;

  final int priorityComponent;
  final int urgencyComponent;
  final int remainingComponent;
  final int squeezedComponent;
  final int narrownessComponent;

  /// 人类可读的排序理由，直接进计划说明。
  final String rationale;
}

/// 给周期目标打分排序（路线图 §3.4）。
///
/// 五项按 §3.4 列出的顺序：**优先级、剩余比例、周期剩余时间、连续被挤压次数、精力与允许
/// 星期**。精力这一项在本函数里**只影响说明文本**，不影响名次：它真正的用武之地是
/// `SchedulableTask.energyLevel`——引擎会把它与候选时段所在精力区间比对，那才是"精力匹配"
/// 的落点。在排序里再算一次会让同一件事被计两次分，而两次的口径一旦不同就会互相抵消。
RecurringTaskRank rankRecurringTask(RecurringSchedulingContext context) {
  final priorityComponent = switch (context.priority) {
    TaskPriority.urgent => 400,
    TaskPriority.high => 300,
    TaskPriority.medium => 200,
    TaskPriority.low => 100,
  };
  // 剩余时间紧：0 天给满，7 天给 0 附近。乘 200 让它能与"优先级"平起平坐，而不是
  // 只当一个同分时的次级依据——§3.4 把"周期剩余时间"列为独立依据。
  final urgencyComponent = (context.urgency * 200).round();
  // 剩余比例低 => 分高。
  final remainingComponent = ((1 - context.remainingRatio).clamp(0, 1) * 150)
      .round();
  // 每被挤压一次加 60 分。**上界 5 次**：再往上加会让"被挤了很多次"压过优先级与截止，
  // 变成"谁被挤得久谁先做"，而那会让一个长期低优先级目标长期霸占容量。
  final squeezedComponent = math.min(context.squeezedCount, 5) * 60;
  final narrownessComponent = (context.narrowness * 80).round();

  final score =
      priorityComponent +
      urgencyComponent +
      remainingComponent +
      squeezedComponent +
      narrownessComponent;

  return RecurringTaskRank(
    templateId: context.templateId,
    score: score,
    priorityComponent: priorityComponent,
    urgencyComponent: urgencyComponent,
    remainingComponent: remainingComponent,
    squeezedComponent: squeezedComponent,
    narrownessComponent: narrownessComponent,
    rationale: buildRecurringRankRationale(context),
  );
}

/// 计划说明里那句话（§3.4："计划说明至少能给出：本周剩余、距截止天数、精力匹配、
/// 均匀分布、容量不足"）。
String buildRecurringRankRationale(RecurringSchedulingContext context) {
  final parts = <String>[
    '本周剩余 ${context.remainingMinutes} 分钟',
    context.daysUntilPeriodEnd == 0
        ? '今天是本周最后一天'
        : '距本周结束 ${context.daysUntilPeriodEnd} 天',
    _energyLabel(context.energyLevel),
  ];
  if (context.squeezedCount > 0) {
    parts.add('已连续 ${context.squeezedCount} 次未排入');
  }
  if (context.allowedWeekdayCount < 7) {
    parts.add('仅允许 ${context.allowedWeekdayCount} 天');
  }
  parts.add('均匀分布');
  return parts.join('　·　');
}

/// 按名次排序一组周期目标。
///
/// **同分时用 `templateId` 兜底**，与引擎的 `_compareTasks` 最后一句完全同型：结果因此
/// 与输入顺序无关（§7.2 最后一条）。
List<RecurringTaskRank> rankRecurringTasks(
  Iterable<RecurringSchedulingContext> contexts,
) {
  final ranked = [for (final context in contexts) rankRecurringTask(context)];
  ranked.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return a.templateId.compareTo(b.templateId);
  });
  return List.unmodifiable(ranked);
}

String _energyLabel(TaskEnergyLevel level) => switch (level) {
  TaskEnergyLevel.high => '适合高精力时段',
  TaskEnergyLevel.medium => '适合中等精力时段',
  TaskEnergyLevel.low => '低精力时段也能做',
};
