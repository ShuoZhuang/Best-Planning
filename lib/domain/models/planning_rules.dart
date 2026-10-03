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

/// 只对某一天生效、且**不落库**的规则覆盖。
///
/// 与 `SettingsService.saveDateOverride` 的关键区别是生命周期：这里是排程输入的一部分，
/// 随一次提案生成而存在，用完即弃，不会写入设置。特殊日恢复使用它，因为
/// FR-RECOVERY-05 要求处理"针对单次事件"、FR-RECOVERY-06 要求特殊日数据不直接更新
/// 长期作息偏好，且技术设计 §12 要求"取消编辑不会污染数据库"——预览过的恢复方案
/// 即使随后被取消，也不得留下任何持久痕迹。
///
/// [localDate] 指明覆盖作用于哪一天：该日是工作日还是周末决定按哪一套规则解析。
/// 注意 `ScheduleProblem.rules` 是覆盖整个窗口的单一对象，因此睡眠与最低睡眠这类
/// "整窗口唯一"的字段只有在 [localDate] 是窗口首日时才可能生效；这是既有限制，
/// 不是本类型引入的。
final class ScheduleRuleOverride {
  const ScheduleRuleOverride({required this.localDate, required this.patch});

  /// 覆盖生效的本地日期（只比较年月日，不比较时刻）。
  final DateTime localDate;

  final PlanningRulesPatch patch;

  /// 该覆盖是否作用于 [date]。
  ///
  /// 逐字段比较年月日而不是使用 `==`：`DateTime` 的相等还要求时刻与 UTC 标志一致，
  /// 而日期来源既有 `DateTime(y, m, d)` 也有 `zones.toLocal(...)`，后者带有时刻。
  /// 沿用这一刻度会让"同一天"被判为不同，从而静默丢弃覆盖。
  bool appliesTo(DateTime date) =>
      localDate.year == date.year &&
      localDate.month == date.month &&
      localDate.day == date.day;
}

void _requirePositive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'Must be positive.');
}

void _requireNonNegative(int value, String name) {
  if (value < 0) throw ArgumentError.value(value, name, 'Cannot be negative.');
}
