import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';

/// 解析覆盖整个规划窗口的规则。
///
/// `SettingsService.resolveForDate` 会按当天的 `DayKind` 过滤精力区间与保护时间，
/// 但排程输入只有一个 `PlanningRules` 对象、要覆盖七天，因此这里分别解析窗口
/// 首日与一个周末日，再把两类日间规则取并集，交给引擎按当天类型自行筛选。
///
/// 注意：睡眠、每日可移动上限、生活配额等"整窗口唯一"的字段取窗口首日的解析
/// 结果。`ScheduleProblem.rules` 是单一对象，无法表达这几项按天不同的取值；
/// 跨工作日与周末的窗口不会为周末单独取一份上限。
final class PlanningRuleResolver {
  const PlanningRuleResolver(this.settings);

  final SettingsService settings;

  Future<PlanningRules> resolveForWindow(
    DateTime startLocalDate, {
    ScheduleRuleOverride? override,
  }) async {
    final startRules = await _rulesFor(startLocalDate, override);
    final weekendRules = await _rulesFor(_nextWeekend(startLocalDate), override);

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
