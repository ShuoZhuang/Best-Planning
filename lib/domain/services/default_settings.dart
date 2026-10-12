import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';

abstract final class DefaultSettings {
  /// 早餐保护的**建议**起止（07:30–08:00，课程与保护时间管理修复计划 §2.4）。
  ///
  /// **它们是公开常量，而早餐不在 [v1] 的 `protectedTimes` 里** —— 这两件事必须分开：
  /// - 设置页与首次引导都要显示"07:30–08:00"这个建议值，两处各写一遍 450/480 迟早漂移；
  /// - 但 `v1()` 是**既有用户升级后拿到的规则**，把早餐放进去等于"装完更新就悄悄改变
  ///   已经确认过的计划"，而计划 §2.4 明确要求既有用户默认关闭。
  ///
  /// 因此：常量在这里公开，规则由用户（或首次引导）显式写入。
  static const int breakfastStartMinute = 7 * 60 + 30;
  static const int breakfastEndMinute = 8 * 60;

  static PlanningRules v1() => PlanningRules(
    energyWindows: [
      EnergyWindow(
        range: LocalTimeRange(startMinute: 9 * 60, endMinute: 12 * 60),
        level: EnergyLevel.high,
      ),
      EnergyWindow(
        range: LocalTimeRange(startMinute: 14 * 60, endMinute: 17 * 60),
        level: EnergyLevel.medium,
      ),
      EnergyWindow(
        range: LocalTimeRange(startMinute: 19 * 60, endMinute: 22 * 60),
        level: EnergyLevel.low,
      ),
    ],
    protectedTimes: [
      ProtectedTimeRule(
        kind: ProtectedTimeKind.lunch,
        range: LocalTimeRange(startMinute: 12 * 60, endMinute: 13 * 60),
      ),
      ProtectedTimeRule(
        kind: ProtectedTimeKind.dinner,
        range: LocalTimeRange(startMinute: 18 * 60, endMinute: 19 * 60),
      ),
    ],
    sleepRange: LocalTimeRange(
      startMinute: 23 * 60 + 30,
      endMinute: 7 * 60 + 30,
    ),
    minimumSleepMinutes: 420,
    defaultFocusMinutes: 50,
    breakMinutes: 10,
    dailyMovableTaskLimitMinutes: 360,
    weeklyLifeQuotaMinutes: 360,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
  );

  static PlanningRules resolve({
    PreferenceProfile? confirmedPreferences,
    PlanningRulesPatch? userRules,
    PlanningRulesPatch? dateOverride,
  }) {
    var resolved = v1();
    if (confirmedPreferences != null) {
      resolved = confirmedPreferences.asPatch().applyTo(resolved);
    }
    if (userRules != null) resolved = userRules.applyTo(resolved);
    if (dateOverride != null) resolved = dateOverride.applyTo(resolved);
    return resolved;
  }
}
