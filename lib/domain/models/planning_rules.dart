import 'dart:collection';

import 'package:personal_planner/domain/models/time_range.dart';

enum EnergyLevel { low, medium, high }

enum DayKind { any, weekday, weekend }

enum ProtectedTimeKind { lunch, dinner, fixedRest }

final class ProtectedTimeRule {
  ProtectedTimeRule({
    required this.kind,
    required this.range,
    this.dayKind = DayKind.any,
    this.enabled = true,
  });

  final ProtectedTimeKind kind;
  final LocalTimeRange range;
  final DayKind dayKind;
  final bool enabled;
}

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
    List<ProtectedTimeRule> protectedTimes = const [],
    required this.sleepRange,
    required this.minimumSleepMinutes,
    required this.defaultFocusMinutes,
    required this.breakMinutes,
    required this.dailyMovableTaskLimitMinutes,
    required this.weeklyLifeQuotaMinutes,
    this.minChunkMinutes = 30,
    this.maxChunkMinutes = 90,
    this.granularityMinutes = 5,
  }) : energyWindows = UnmodifiableListView(energyWindows),
       protectedTimes = UnmodifiableListView(protectedTimes) {
    _requirePositive(minimumSleepMinutes, 'minimumSleepMinutes');
    _requirePositive(defaultFocusMinutes, 'defaultFocusMinutes');
    _requireNonNegative(breakMinutes, 'breakMinutes');
    _requirePositive(
      dailyMovableTaskLimitMinutes,
      'dailyMovableTaskLimitMinutes',
    );
    _requireNonNegative(weeklyLifeQuotaMinutes, 'weeklyLifeQuotaMinutes');
    _requirePositive(minChunkMinutes, 'minChunkMinutes');
    _requirePositive(maxChunkMinutes, 'maxChunkMinutes');
    if (minChunkMinutes > maxChunkMinutes) {
      throw ArgumentError('Minimum chunk cannot exceed maximum chunk.');
    }
    _requirePositive(granularityMinutes, 'granularityMinutes');
    if (dailyMovableTaskLimitMinutes > LocalTimeRange.minutesPerDay) {
      throw ArgumentError('The daily movable task limit cannot exceed a day.');
    }
  }

  final List<EnergyWindow> energyWindows;
  final List<ProtectedTimeRule> protectedTimes;
  final LocalTimeRange sleepRange;
  final int minimumSleepMinutes;
  final int defaultFocusMinutes;
  final int breakMinutes;
  final int dailyMovableTaskLimitMinutes;
  final int weeklyLifeQuotaMinutes;
  final int minChunkMinutes;
  final int maxChunkMinutes;
  final int granularityMinutes;

  PlanningRules copyWith({
    List<EnergyWindow>? energyWindows,
    List<ProtectedTimeRule>? protectedTimes,
    LocalTimeRange? sleepRange,
    int? minimumSleepMinutes,
    int? defaultFocusMinutes,
    int? breakMinutes,
    int? dailyMovableTaskLimitMinutes,
    int? weeklyLifeQuotaMinutes,
    int? minChunkMinutes,
    int? maxChunkMinutes,
    int? granularityMinutes,
  }) => PlanningRules(
    energyWindows: energyWindows ?? this.energyWindows,
    protectedTimes: protectedTimes ?? this.protectedTimes,
    sleepRange: sleepRange ?? this.sleepRange,
    minimumSleepMinutes: minimumSleepMinutes ?? this.minimumSleepMinutes,
    defaultFocusMinutes: defaultFocusMinutes ?? this.defaultFocusMinutes,
    breakMinutes: breakMinutes ?? this.breakMinutes,
    dailyMovableTaskLimitMinutes:
        dailyMovableTaskLimitMinutes ?? this.dailyMovableTaskLimitMinutes,
    weeklyLifeQuotaMinutes:
        weeklyLifeQuotaMinutes ?? this.weeklyLifeQuotaMinutes,
    minChunkMinutes: minChunkMinutes ?? this.minChunkMinutes,
    maxChunkMinutes: maxChunkMinutes ?? this.maxChunkMinutes,
    granularityMinutes: granularityMinutes ?? this.granularityMinutes,
  );
}

final class PlanningRulesPatch {
  const PlanningRulesPatch({
    this.energyWindows,
    this.protectedTimes,
    this.sleepRange,
    this.minimumSleepMinutes,
    this.defaultFocusMinutes,
    this.breakMinutes,
    this.dailyMovableTaskLimitMinutes,
    this.weeklyLifeQuotaMinutes,
    this.minChunkMinutes,
    this.maxChunkMinutes,
    this.granularityMinutes,
  });

  final List<EnergyWindow>? energyWindows;
  final List<ProtectedTimeRule>? protectedTimes;
  final LocalTimeRange? sleepRange;
  final int? minimumSleepMinutes;
  final int? defaultFocusMinutes;
  final int? breakMinutes;
  final int? dailyMovableTaskLimitMinutes;
  final int? weeklyLifeQuotaMinutes;
  final int? minChunkMinutes;
  final int? maxChunkMinutes;
  final int? granularityMinutes;

  PlanningRules applyTo(PlanningRules base) => base.copyWith(
    energyWindows: energyWindows,
    protectedTimes: protectedTimes,
    sleepRange: sleepRange,
    minimumSleepMinutes: minimumSleepMinutes,
    defaultFocusMinutes: defaultFocusMinutes,
    breakMinutes: breakMinutes,
    dailyMovableTaskLimitMinutes: dailyMovableTaskLimitMinutes,
    weeklyLifeQuotaMinutes: weeklyLifeQuotaMinutes,
    minChunkMinutes: minChunkMinutes,
    maxChunkMinutes: maxChunkMinutes,
    granularityMinutes: granularityMinutes,
  );

  PlanningRulesPatch copyWith({
    List<EnergyWindow>? energyWindows,
    List<ProtectedTimeRule>? protectedTimes,
    LocalTimeRange? sleepRange,
    int? minimumSleepMinutes,
    int? defaultFocusMinutes,
    int? breakMinutes,
    int? dailyMovableTaskLimitMinutes,
    int? weeklyLifeQuotaMinutes,
    int? minChunkMinutes,
    int? maxChunkMinutes,
    int? granularityMinutes,
  }) => PlanningRulesPatch(
    energyWindows: energyWindows ?? this.energyWindows,
    protectedTimes: protectedTimes ?? this.protectedTimes,
    sleepRange: sleepRange ?? this.sleepRange,
    minimumSleepMinutes: minimumSleepMinutes ?? this.minimumSleepMinutes,
    defaultFocusMinutes: defaultFocusMinutes ?? this.defaultFocusMinutes,
    breakMinutes: breakMinutes ?? this.breakMinutes,
    dailyMovableTaskLimitMinutes:
        dailyMovableTaskLimitMinutes ?? this.dailyMovableTaskLimitMinutes,
    weeklyLifeQuotaMinutes:
        weeklyLifeQuotaMinutes ?? this.weeklyLifeQuotaMinutes,
    minChunkMinutes: minChunkMinutes ?? this.minChunkMinutes,
    maxChunkMinutes: maxChunkMinutes ?? this.maxChunkMinutes,
    granularityMinutes: granularityMinutes ?? this.granularityMinutes,
  );
}

void _requirePositive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'Must be positive.');
}

void _requireNonNegative(int value, String name) {
  if (value < 0) throw ArgumentError.value(value, name, 'Cannot be negative.');
}
