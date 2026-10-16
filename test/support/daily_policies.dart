// 测试夹具用的**逐日策略**工厂（算法 17，计划 Task 2）。
//
// ## 为什么需要一个共享工具
//
// `ScheduleProblem` 与 `AvailabilityInput` 都要求显式的逐日策略，而"窗口涉及的
// 每一个本地日期"必须逐值覆盖。让每个测试夹具各自手写一张 Map 会带来两个失败模式：
//
// 1. **少数一天** ⇒ 引擎在缺日时抛 `StateError`（好），但更糟的是有人为了让它跑起来
//    加一个"缺日回退首日"的兜底（坏）——那正是本计划要根除的缺陷；
// 2. **多算一天** ⇒ 装配层的覆盖校验拒绝它，而修法会被误认为"校验太严"。
//
// 因此这里提供**一个**函数：从规划窗口与一份规则算出精确覆盖该窗口的策略表，
// 以 `TimeZoneDatabase` 换算本地日期（与生产装配层同一套口径）。
//
// ## 为什么不放进 `lib/`
//
// 它不是生产代码：生产装配层从 `PlanningRuleResolver.resolveByDateForWindow` 取
// **真实解析**的逐日规则，而不是把同一份规则复制到每一天。测试夹具刻意用同一份规则
// 覆盖全部日期，因为那些用例钉的是**排程行为**，不是规则解析。
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';

/// 从 [window] 与 [rules] 造出精确覆盖窗口的逐日策略表。
///
/// [zones] 必须是调用方自己在用的那个 `TimeZoneDatabase` 实例：
/// 本地日期由它换算，而窗口"覆盖哪几天"完全取决于时区。
///
/// [softReserveTargetMinutes] 默认 0（本批次由 Task 3 的容量账本赋值）。
Map<DateTime, DailySchedulingPolicy> dailyPoliciesForWindow({
  required TimeZoneDatabase zones,
  required TimeRange window,
  required PlanningRules rules,
  required String timeZoneId,
  int softReserveTargetMinutes = 0,
}) {
  final dates = enumerateLocalDates(
    zones: zones,
    window: window,
    timeZoneId: timeZoneId,
  );
  return {
    for (final date in dates)
      date: DailySchedulingPolicy(
        localDate: date,
        resolvedRules: rules,
        softReserveTargetMinutes: softReserveTargetMinutes,
      ),
  };
}

/// 从 [window] 与 [rules] 造出覆盖窗口所涉**每个本地周一**的生活配额表。
///
/// 只覆盖窗口内的周一就够：`lifeQuotaForLocalWeek` 会把任意日期回退到它所在周的周一。
Map<DateTime, int> weeklyLifeQuotasForWindow({
  required TimeZoneDatabase zones,
  required TimeRange window,
  required PlanningRules rules,
  required String timeZoneId,
}) {
  final dates = enumerateLocalDates(
    zones: zones,
    window: window,
    timeZoneId: timeZoneId,
  );
  final mondays = <DateTime>{
    for (final date in dates)
      DateTime(date.year, date.month, date.day - (date.weekday - 1)),
  };
  return {for (final monday in mondays) monday: rules.weeklyLifeQuotaMinutes};
}

/// 枚举 [window] 覆盖到的本地日期，升序（与生产装配层同一套口径）。
///
/// 终点减一微秒：窗口是半开区间 `[start, end)`，因此"终点正好是本地午夜"这种形状
/// 必须把最后一天归到前一天，而不是多枚举出一天。
List<DateTime> enumerateLocalDates({
  required TimeZoneDatabase zones,
  required TimeRange window,
  required String timeZoneId,
}) {
  final first = _dateOnly(zones.toLocal(window.startUtc, timeZoneId));
  final last = _dateOnly(
    zones.toLocal(
      window.endUtc.subtract(const Duration(microseconds: 1)),
      timeZoneId,
    ),
  );
  final dates = <DateTime>[];
  for (var date = first; !date.isAfter(last); date = _nextLocalDate(date)) {
    dates.add(date);
  }
  return dates;
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _nextLocalDate(DateTime date) =>
    DateTime(date.year, date.month, date.day + 1);
