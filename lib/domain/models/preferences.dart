import 'package:personal_planner/domain/models/planning_rules.dart';

final class PreferenceProfile {
  const PreferenceProfile({
    this.preferredFocusMinutes,
    this.preferredEnergyWindows,
    this.enabled = true,
  }) : assert(preferredFocusMinutes == null || preferredFocusMinutes > 0);

  final int? preferredFocusMinutes;
  final List<EnergyWindow>? preferredEnergyWindows;
  final bool enabled;

  PlanningRulesPatch asPatch() {
    if (!enabled) return const PlanningRulesPatch();
    return PlanningRulesPatch(
      defaultFocusMinutes: preferredFocusMinutes,
      energyWindows: preferredEnergyWindows,
    );
  }

  PreferenceProfile copyWith({
    int? preferredFocusMinutes,
    List<EnergyWindow>? preferredEnergyWindows,
    bool? enabled,
  }) => PreferenceProfile(
    preferredFocusMinutes: preferredFocusMinutes ?? this.preferredFocusMinutes,
    preferredEnergyWindows:
        preferredEnergyWindows ?? this.preferredEnergyWindows,
    enabled: enabled ?? this.enabled,
  );
}
