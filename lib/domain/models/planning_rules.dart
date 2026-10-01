import 'dart:collection';

import 'package:personal_planner/domain/models/time_range.dart';

enum EnergyLevel { low, medium, high }

enum DayKind { any, weekday, weekend }

final class EnergyWindow {
  EnergyWindow({
    required this.range,
    required this.level,
    this.dayKind = DayKind.any,
  });

  final LocalTimeRange range;
  final EnergyLevel level;
  final DayKind dayKind;

  EnergyWindow copyWith({
    LocalTimeRange? range,
    EnergyLevel? level,
    DayKind? dayKind,
  }) => EnergyWindow(
    range: range ?? this.range,
    level: level ?? this.level,
    dayKind: dayKind ?? this.dayKind,
  );
}

final class PlanningRules {
  PlanningRules({
    required List<EnergyWindow> energyWindows,
    required this.sleepRange,
    required this.minimumSleepMinutes,
    required this.defaultFocusMinutes,
    required this.breakMinutes,
    required this.dailyMovableTaskLimitMinutes,
    required this.weeklyLifeQuotaMinutes,
    this.granularityMinutes = 5,
  }) : energyWindows = UnmodifiableListView(energyWindows) {
    _requirePositive(minimumSleepMinutes, 'minimumSleepMinutes');
    _requirePositive(defaultFocusMinutes, 'defaultFocusMinutes');
    _requireNonNegative(breakMinutes, 'breakMinutes');
    _requirePositive(
      dailyMovableTaskLimitMinutes,
      'dailyMovableTaskLimitMinutes',
    );
    _requireNonNegative(weeklyLifeQuotaMinutes, 'weeklyLifeQuotaMinutes');
    _requirePositive(granularityMinutes, 'granularityMinutes');
    if (dailyMovableTaskLimitMinutes > LocalTimeRange.minutesPerDay) {
      throw ArgumentError('The daily movable task limit cannot exceed a day.');
    }
  }

  final List<EnergyWindow> energyWindows;
  final LocalTimeRange sleepRange;
  final int minimumSleepMinutes;
  final int defaultFocusMinutes;
  final int breakMinutes;
  final int dailyMovableTaskLimitMinutes;
  final int weeklyLifeQuotaMinutes;
  final int granularityMinutes;

  PlanningRules copyWith({
    List<EnergyWindow>? energyWindows,
    LocalTimeRange? sleepRange,
    int? minimumSleepMinutes,
    int? defaultFocusMinutes,
    int? breakMinutes,
    int? dailyMovableTaskLimitMinutes,
    int? weeklyLifeQuotaMinutes,
    int? granularityMinutes,
  }) => PlanningRules(
    energyWindows: energyWindows ?? this.energyWindows,
    sleepRange: sleepRange ?? this.sleepRange,
    minimumSleepMinutes: minimumSleepMinutes ?? this.minimumSleepMinutes,
    defaultFocusMinutes: defaultFocusMinutes ?? this.defaultFocusMinutes,
    breakMinutes: breakMinutes ?? this.breakMinutes,
    dailyMovableTaskLimitMinutes:
        dailyMovableTaskLimitMinutes ?? this.dailyMovableTaskLimitMinutes,
    weeklyLifeQuotaMinutes:
        weeklyLifeQuotaMinutes ?? this.weeklyLifeQuotaMinutes,
    granularityMinutes: granularityMinutes ?? this.granularityMinutes,
  );
}

final class PlanningRulesPatch {
  const PlanningRulesPatch({
    this.energyWindows,
    this.sleepRange,
    this.minimumSleepMinutes,
    this.defaultFocusMinutes,
    this.breakMinutes,
    this.dailyMovableTaskLimitMinutes,
    this.weeklyLifeQuotaMinutes,
    this.granularityMinutes,
  });

  final List<EnergyWindow>? energyWindows;
  final LocalTimeRange? sleepRange;
  final int? minimumSleepMinutes;
  final int? defaultFocusMinutes;
  final int? breakMinutes;
  final int? dailyMovableTaskLimitMinutes;
  final int? weeklyLifeQuotaMinutes;
  final int? granularityMinutes;

  PlanningRules applyTo(PlanningRules base) => base.copyWith(
    energyWindows: energyWindows,
    sleepRange: sleepRange,
    minimumSleepMinutes: minimumSleepMinutes,
    defaultFocusMinutes: defaultFocusMinutes,
    breakMinutes: breakMinutes,
    dailyMovableTaskLimitMinutes: dailyMovableTaskLimitMinutes,
    weeklyLifeQuotaMinutes: weeklyLifeQuotaMinutes,
    granularityMinutes: granularityMinutes,
  );

  PlanningRulesPatch copyWith({
    List<EnergyWindow>? energyWindows,
    LocalTimeRange? sleepRange,
    int? minimumSleepMinutes,
    int? defaultFocusMinutes,
    int? breakMinutes,
    int? dailyMovableTaskLimitMinutes,
    int? weeklyLifeQuotaMinutes,
    int? granularityMinutes,
  }) => PlanningRulesPatch(
    energyWindows: energyWindows ?? this.energyWindows,
    sleepRange: sleepRange ?? this.sleepRange,
    minimumSleepMinutes: minimumSleepMinutes ?? this.minimumSleepMinutes,
    defaultFocusMinutes: defaultFocusMinutes ?? this.defaultFocusMinutes,
    breakMinutes: breakMinutes ?? this.breakMinutes,
    dailyMovableTaskLimitMinutes:
        dailyMovableTaskLimitMinutes ?? this.dailyMovableTaskLimitMinutes,
    weeklyLifeQuotaMinutes:
        weeklyLifeQuotaMinutes ?? this.weeklyLifeQuotaMinutes,
    granularityMinutes: granularityMinutes ?? this.granularityMinutes,
  );
}

void _requirePositive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'Must be positive.');
}

void _requireNonNegative(int value, String name) {
  if (value < 0) throw ArgumentError.value(value, name, 'Cannot be negative.');
}
