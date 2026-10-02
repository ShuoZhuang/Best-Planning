import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';

abstract final class DefaultSettings {
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
