import 'dart:collection';

import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';

/// 解析覆盖整个规划窗口的规则。
///
/// ## 兼容入口：`resolveForWindow`（**不要**给排程用）
///
/// `SettingsService.resolveForDate` 会按当天的 `DayKind` 过滤精力区间与保护时间，
/// 但排程输入此前只有一个 `PlanningRules` 对象、要覆盖七天，因此这里分别解析窗口
/// 首日与一个周末日，再把两类日间规则取并集，交给引擎按当天类型自行筛选。
///
/// 睡眠、每日可移动上限、生活配额等"整窗口唯一"的字段取窗口首日的解析
/// 结果。`ScheduleProblem.rules` 是单一对象，无法表达这几项按天不同的取值；
/// 跨工作日与周末的窗口不会为周末单独取一份上限。
///
/// **这正是算法 17 要修的结构缺口**（计划 §1.2 第 1 条），但日历读取路径仍在用它，
/// 因此**签名与返回类型保持不变**（计划 §6 兼容规则第 1 条）。新代码一律走
/// [resolveByDateForWindow]，它逐日给出一份完整规则。
final class PlanningRuleResolver {
  const PlanningRuleResolver(this.settings);

  final SettingsService settings;

  Future<PlanningRules> resolveForWindow(
    DateTime startLocalDate, {
    ScheduleRuleOverride? override,
  }) async {
    final startRules = await _rulesFor(startLocalDate, override);
    final weekendRules = await _rulesFor(
      _nextWeekend(startLocalDate),
      override,
    );

    return startRules.copyWith(
      energyWindows: _mergeDistinct(
        startRules.energyWindows,
        weekendRules.energyWindows,
        (window) =>
            '${window.dayKind.name}|${window.range.startMinute}|'
            '${window.range.endMinute}|${window.level.name}',
      ),
      protectedTimes: _mergeDistinct(
        startRules.protectedTimes,
        weekendRules.protectedTimes,
        (item) =>
            '${item.dayKind.name}|${item.kind.name}|'
            '${item.range.startMinute}|${item.range.endMinute}',
      ),
    );
  }

  /// **逐日**解析窗口内每一天的规则（计划 §6 兼容规则第 2 条）。
  ///
  /// 与 [resolveForWindow] 的分工是**明确的**：那个是给尚未迁移的日历读取路径的
  /// 兼容入口，这个是**排程输入装配的唯一入口**。两者并存而不是替换，因为
  /// 直接改 [resolveForWindow] 的返回类型会同时改动日历视图，而本计划不碰界面
  /// （Global Constraints）。
  ///
  /// 契约（逐条由 `planning_rule_resolver_test.dart` 钉住）：
  /// - 范围**两端均包含**；
  /// - 键按本地日期**升序**插入，且**去时分秒**（`DateTime(y, m, d)`）；
  /// - 返回**不可修改**的 Map；
  /// - 一次性覆盖 [override] 只作用于它命中(= [ScheduleRuleOverride.appliesTo]) 的那一天；
  /// - 枚举日期**按本地日推进**，因此 DST 切换日不会错位（不能用"UTC 每 24 小时递增"）。
  Future<Map<DateTime, PlanningRules>> resolveByDateForWindow(
    DateTime startLocalDate,
    DateTime endLocalDate, {
    ScheduleRuleOverride? override,
  }) async {
    final start = normalizeLocalDate(startLocalDate);
    final end = normalizeLocalDate(endLocalDate);
    if (end.isBefore(start)) {
      throw ArgumentError.value(endLocalDate, 'endLocalDate', '逐日解析的终点不得早于起点');
    }
    final result = <DateTime, PlanningRules>{};
    var date = start;
    while (!date.isAfter(end)) {
      result[date] = await _rulesFor(date, override);
      date = _nextLocalDate(date);
    }
    return UnmodifiableMapView(result);
  }

  /// 解析某一天的规则，并在该天被 [override] 命中时叠加一次性覆盖。
  ///
  /// 覆盖叠加在 `resolveForDate` 的结果之上，因此用户**显式保存**的当日例外仍然优先，
  /// 一次性覆盖只是本次生成计划时多出来的一层，不会覆盖用户的持久设置。
  Future<PlanningRules> _rulesFor(
    DateTime date,
    ScheduleRuleOverride? override,
  ) async {
    final rules = (await settings.resolveForDate(date)).rules;
    if (override == null || !override.appliesTo(date)) return rules;
    return override.patch.applyTo(rules);
  }
}

/// 下一个**本地自然日**。
///
/// 用 `DateTime(y, m, d + 1)` 而不是 `add(Duration(days: 1))`：后者加的是绝对 24 小时，
/// 在 DST 切换日会落在前一天的 23:00 或当天的 01:00，于是同一天被枚举两次、
/// 而另一天被跳过。`DateTime` 的构造器按日历规则进位，跨月、跨年与 DST 都正确。
DateTime _nextLocalDate(DateTime localDate) =>
    DateTime(localDate.year, localDate.month, localDate.day + 1);

DateTime _nextWeekend(DateTime localDate) {
  if (localDate.weekday == DateTime.saturday ||
      localDate.weekday == DateTime.sunday) {
    return localDate;
  }
  return localDate.add(
    Duration(days: (DateTime.saturday - localDate.weekday + 7) % 7),
  );
}

List<T> _mergeDistinct<T>(
  List<T> first,
  List<T> second,
  String Function(T item) key,
) {
  final seen = <String>{};
  final merged = <T>[];
  for (final item in [...first, ...second]) {
    if (seen.add(key(item))) merged.add(item);
  }
  return merged;
}
