import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 容量不足的**结构化缺口**（路线图 §3.4、§11 Task 8）。
///
/// **为什么必须是结构而不是一句"排不下"**：§3.4 要求"容量不足返回结构化缺口，不挤占保护
/// 时间，不在截止之后假装安排成功"，而缺口卡片要提供四个处理动作（调低本周目标、放宽期望
/// 时段、临时放宽每日上限、允许本周不完全安排）。这四个动作各自需要不同的数字，"排不下"
/// 三个字给不出任何一个。
///
/// **`protectedConstraint` 是刻意保留的**：它把"这次缺口是在哪一条保护约束下算出来的"一起
/// 交给用户看。不说清楚，用户只能猜是睡眠还是午餐挤掉了目标——而这两件事的处理方式完全不同
/// （一个该调低目标，一个该放宽期望时段）。
final class CapacityShortfall {
  const CapacityShortfall({
    required this.templateId,
    required this.title,
    required this.periodStartLocalDate,
    required this.targetMinutes,
    required this.schedulableMinutes,
    required this.shortfallMinutes,
    required this.protectedConstraint,
    required this.window,
  }) : assert(targetMinutes >= 0),
       assert(schedulableMinutes >= 0),
       assert(shortfallMinutes >= 0);

  /// 模板 id（缺口卡片据此找到"调低本周目标"要改哪一行）。
  final EntityId templateId;

  /// 给用户看的名字。缺口卡片上写"每周英语还差 60 分钟"，而不是一个 id。
  final String title;

  /// 这一周的本地周一。
  final DateTime periodStartLocalDate;

  /// 这一周的目标（含结转，即周期实例的有效目标）。
  final int targetMinutes;

  /// 在**不占用保护时间**的前提下，窗口内真正能安排给它的分钟。
  final int schedulableMinutes;

  /// 缺口＝目标 − 可安排，下界为 0。
  ///
  /// **它必须精确**：容量 120、目标 180 ⇒ 缺口正好 60（§7.2 的最后一条体验要求）。
  /// 用"大约排不下"之类的模糊说法，用户就没法判断该把目标调到多少。
  final int shortfallMinutes;

  /// 这次缺口是在哪条保护约束下算出来的（睡眠／用餐／自定义／无）。
  final ProtectedTimeKind? protectedConstraint;

  /// 计算出这个缺口时使用的规划窗口。
  final TimeRange window;

  bool get isEmpty => shortfallMinutes == 0;

  /// 用户可读的一句话。**只报事实，不给建议**：怎么处理由缺口卡片上的四个动作决定
  /// （§3.4），在这一层替用户选一个等于替他决定。
  String get message =>
      '「$title」本周目标 $targetMinutes 分钟，'
      '在不占用保护时间的前提下最多安排 $schedulableMinutes 分钟，'
      '还差 $shortfallMinutes 分钟。';
}

/// 计算某个周期目标在本周的容量缺口。
///
/// **它不碰保护时间**：`protectedIntervals` 只被用来**扣掉可用分钟**，不会被缩短、移动或
/// 覆盖。这正是 §3.4"容量不足时不得挤占保护时间"在代码里的落点——缺口是一份报告，
/// 不是一个"把保护时间挪开"的许可。
///
/// 扣除顺序与排程器一致：固定日程 → 保护时间 → 已锁定计划块。**顺序不影响结果**
/// （它们是纯扣减），但保持与引擎相同的口径可以让"缺口 60"与"引擎排不下 60"必然一致；
/// 两处口径如果不同，用户会看到"预览说能排下、计划里却少了 60 分钟"。
CapacityShortfall? capacityShortfallForRecurringGoal({
  required EntityId templateId,
  required String title,
  required DateTime periodStartLocalDate,
  required int targetMinutes,
  required TimeRange window,
  Iterable<TimeRange> fixedRanges = const [],
  Iterable<TimeRange> protectedRanges = const [],
  Iterable<TimeRange> lockedRanges = const [],
  ProtectedTimeKind? protectedConstraint,
}) {
  if (targetMinutes <= 0) return null;
  final capacity = schedulableMinutes(window, [
    ...fixedRanges,
    ...protectedRanges,
    ...lockedRanges,
  ]);
  final shortfall = targetMinutes - capacity;
  if (shortfall <= 0) {
    // **恰恰够用时不报缺口**：把 0 当成"有缺口"会在界面上留一张永远显示为空话的卡片。
    return null;
  }
  return CapacityShortfall(
    templateId: templateId,
    title: title,
    periodStartLocalDate: periodStartLocalDate,
    targetMinutes: targetMinutes,
    schedulableMinutes: capacity,
    shortfallMinutes: shortfall,
    protectedConstraint: protectedConstraint,
    window: window,
  );
}

/// 窗口内没有被任何忙碌区间覆盖的分钟数。
///
/// **公开**：预览页需要同一个数字来解释"为什么排不下"，而重算一遍必然会与这里漂移。
///
/// 实现方式是**区间合并**而不是逐分钟打点：窗口最长可以到 180 天（`CapacityModel` 的扩展
/// 上限），逐分钟会做出十多万次判断，而这个函数在每次生成计划时都要为每个周期目标跑一次。
int schedulableMinutes(TimeRange window, List<TimeRange> busy) {
  if (busy.isEmpty) return window.durationMinutes;
  final clipped = <({DateTime start, DateTime end})>[];
  for (final range in busy) {
    final start = range.startUtc.isBefore(window.startUtc)
        ? window.startUtc
        : range.startUtc;
    final end = range.endUtc.isAfter(window.endUtc)
        ? window.endUtc
        : range.endUtc;
    if (!end.isAfter(start)) continue;
    clipped.add((start: start, end: end));
  }
  if (clipped.isEmpty) return window.durationMinutes;
  clipped.sort((a, b) => a.start.compareTo(b.start));
  var total = 0;
  var cursor = window.startUtc;
  for (final range in clipped) {
    // 与上一段重叠的区间不再重复扣除：两条保护规则重叠（例如"午休"与"自定义"）
    // 是很常见的配置，重复扣会让容量凭空少一半。
    if (range.start.isAfter(cursor)) {
      total += range.start.difference(cursor).inMinutes;
      cursor = range.start;
    }
    if (range.end.isAfter(cursor)) cursor = range.end;
  }
  if (window.endUtc.isAfter(cursor)) {
    total += window.endUtc.difference(cursor).inMinutes;
  }
  return total;
}
