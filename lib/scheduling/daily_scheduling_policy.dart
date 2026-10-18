import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';

/// **某个本地日期**完整解析后的排程规则快照（计划
/// `2026-10-16-capacity-aware-hierarchical-scheduler-repair.md` §3.1 / §6）。
///
/// ## 为什么必须是一个值对象而不是"再传一个 PlanningRules"
///
/// 算法 16 的排程输入只有一个 `ScheduleProblem.rules`，而它要覆盖整个规划窗口。
/// `PlanningRuleResolver.resolveForWindow` 因此只能把工作日与周末的**精力区间与保护时间**
/// 取并集，而**睡眠、每日可移动上限、生活配额仍然取窗口首日**（计划 §1.2 第 1 条）。
/// 于是一个"周一开窗、周末上限更高"的窗口会给周末套上周一的上限——用户看到的是
/// "周末明明空着，却只排进和周中一样多的量"。
///
/// 修复不是"多传几个字段"，而是**让每一天带走自己那一份完整规则**：
///
/// - 保存完整的不可变 [resolvedRules] 快照，而不是只抄当前碰巧用到的几个字段。
///   只抄用得到的字段，下一个"又用到某个日期敏感字段"的人就会再次漏传——
///   这正是本缺陷的历史成因（睡眠漏传 → 容量与校验两套口径，见
///   `availability_builder.dart` 的注释）。
/// - [localDate] 归一为 `DateTime(y, m, d)`：日期是这张表的**键**，带时分秒的键会让
///   同一个本地日被拆成两个（`even_distribution_allocator_test.dart` 的
///   "带时间部分的日期键被归一化到当天"钉住同一件事）。
///
/// ## 恢复余量为什么在这里
///
/// [softReserveTargetMinutes] 由当天的许可容量算出（计划 §3.7：
/// `min(30, floor(licensedCapacityMinutes * 0.10 / granularity) * granularity)`）。
/// 它是**软目标**，不从可用容量里硬扣；放在这里是因为它同样是"逐日"的量，
/// 而算法 16 没有任何地方能表达它。
final class DailySchedulingPolicy {
  DailySchedulingPolicy({
    required DateTime localDate,
    required this.resolvedRules,
    required this.softReserveTargetMinutes,
    this.dayException,
  }) : localDate = normalizeLocalDate(localDate) {
    if (softReserveTargetMinutes < 0) {
      throw ArgumentError.value(
        softReserveTargetMinutes,
        'softReserveTargetMinutes',
        '恢复余量不能为负',
      );
    }
    if (dayException != null &&
        normalizeLocalDate(dayException!.localDate) != this.localDate) {
      throw ArgumentError('特殊日事实必须与策略的本地日期一致');
    }
  }

  /// 这一份规则服务于哪个**本地**日期（时间部分恒为 0）。
  final DateTime localDate;

  /// 该日完整解析后的规则快照。
  ///
  /// **不是"窗口首日的规则"**：睡眠、每日可移动上限、精力区间、保护时间、休息、
  /// 粒度与课程过渡都取自这一天自己的解析结果。
  final PlanningRules resolvedRules;

  /// 当天先作为软目标保留的恢复余量分钟。
  final int softReserveTargetMinutes;

  /// 当天已确认的特殊日 / 临时延长日事实（规范 §8.1）。
  ///
  /// **只有 confirmed 且日期匹配的事实**才会被装配到这里；它只覆盖当天的睡眠开始，
  /// 不扩散到邻日，也不改变固定起床。
  final DayException? dayException;

  @override
  bool operator ==(Object other) =>
      other is DailySchedulingPolicy &&
      other.localDate == localDate &&
      identical(other.resolvedRules, resolvedRules) &&
      other.softReserveTargetMinutes == softReserveTargetMinutes &&
      other.dayException == dayException;

  @override
  int get hashCode => Object.hash(
    localDate,
    identityHashCode(resolvedRules),
    softReserveTargetMinutes,
    dayException,
  );

  @override
  String toString() =>
      'DailySchedulingPolicy(${localDate.year}-${localDate.month}-${localDate.day}, '
      'reserve=$softReserveTargetMinutes)';
}

/// 按本地日期取当天策略。**缺失即装配不变量破坏**，不得回退到窗口首日。
typedef DailyPolicyLookup = DailySchedulingPolicy Function(DateTime localDate);

/// 把一个可能带时分秒（甚至带 UTC 标志）的时刻归一成**本地自然日**。
///
/// 用 `DateTime(y, m, d)` 构造而不是 `DateUtils.dateOnly` 或 `subtract`：
/// 后者在 DST 切换日会得到前一天的 23:00 或当天的 01:00，于是同一个本地日
/// 被拆成两个键（`even_distribution_allocator_test.dart` 的 DST 用例是同一类证据）。
DateTime normalizeLocalDate(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 从一份规则快照算出当天的**软恢复余量**目标（计划 §3.7）。
///
/// `min(30, floor(licensedCapacityMinutes * 10% / granularity) * granularity)`。
/// 全部用整数运算并向下取整到粒度：计划 §3.3 要求所有除法"使用整数取整、
/// 不使用浮点数，确保跨平台逐值一致"，而这里是**可用量**，向下取整才不会承诺
/// 一个排不出来的余量。
///
/// 许可容量为 0 时返回 0（不除零，也不凭空要余量）。
int softReserveTargetFor({
  required int licensedCapacityMinutes,
  required int granularityMinutes,
  int maxReserveMinutes = 30,
}) {
  if (licensedCapacityMinutes <= 0 || granularityMinutes <= 0) return 0;
  // 先算"许可容量的 10%"（整数、向下取整），再向下取整到粒度，最后压到上限。
  final tenPercent = licensedCapacityMinutes * 10 ~/ 100;
  final floored = (tenPercent ~/ granularityMinutes) * granularityMinutes;
  if (floored <= 0) return 0;
  return floored < maxReserveMinutes ? floored : maxReserveMinutes;
}
