import 'dart:convert';

import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';

final class UserPlanningRules {
  const UserPlanningRules({
    this.common = const PlanningRulesPatch(),
    this.weekday = const PlanningRulesPatch(),
    this.weekend = const PlanningRulesPatch(),
  });

  final PlanningRulesPatch common;
  final PlanningRulesPatch weekday;
  final PlanningRulesPatch weekend;
}

final class NotificationPreferences {
  NotificationPreferences({
    this.taskStartEnabled = true,
    this.taskStartLeadMinutes = 10,
    this.calendarStartEnabled = true,
    this.calendarStartLeadMinutes = 10,
    this.deadlineEnabled = true,
    this.deadlineLeadMinutes = 24 * 60,
    this.conflictEnabled = true,
    LocalTimeRange? quietHours,
  }) : quietHours =
           quietHours ??
           LocalTimeRange(startMinute: 23 * 60 + 30, endMinute: 7 * 60 + 30);

  final bool taskStartEnabled;
  final int taskStartLeadMinutes;
  final bool calendarStartEnabled;
  final int calendarStartLeadMinutes;
  final bool deadlineEnabled;
  final int deadlineLeadMinutes;
  final bool conflictEnabled;
  final LocalTimeRange quietHours;
}

final class ResolvedPlanningSettings {
  const ResolvedPlanningSettings({
    required this.rules,
    required this.notifications,
    required this.trustAutoAdjust,
  });

  final PlanningRules rules;
  final NotificationPreferences notifications;
  final bool trustAutoAdjust;

  EnergyLevel? energyLevelAt(int minute) {
    if (minute < 0 || minute >= LocalTimeRange.minutesPerDay) {
      throw RangeError.range(minute, 0, LocalTimeRange.minutesPerDay - 1);
    }
    for (final window in rules.energyWindows) {
      final range = window.range;
      final contains = range.crossesMidnight
          ? minute >= range.startMinute || minute < range.endMinute
          : minute >= range.startMinute && minute < range.endMinute;
      if (contains) return window.level;
    }
    return null;
  }
}

final class SettingsValidationException implements Exception {
  const SettingsValidationException(this.fieldErrors);

  final Map<String, String> fieldErrors;
}

final class SettingsService {
  SettingsService({required this.repository});

  static const _userRulesKey = 'planning.userRules.v1';
  static const _learnedPreferencesKey = 'planning.learnedPreferences.v1';
  static const _notificationsKey = 'notifications.v1';
  static const _trustAutoAdjustKey = 'planning.trustAutoAdjust.v1';

  final SettingsRepository repository;

  Future<ResolvedPlanningSettings> resolveForDate(DateTime localDate) async {
    final user = await loadUserRules();
    final learned = await loadLearnedPreferences();
    final dateOverride = await _loadPatch(_overrideKey(localDate));
    final isWeekend =
        localDate.weekday == DateTime.saturday ||
        localDate.weekday == DateTime.sunday;

    var rules = DefaultSettings.resolve(confirmedPreferences: learned);
    rules = user.common.applyTo(rules);
    rules = (isWeekend ? user.weekend : user.weekday).applyTo(rules);
    if (dateOverride != null) rules = dateOverride.applyTo(rules);

    final relevantKind = isWeekend ? DayKind.weekend : DayKind.weekday;
    rules = rules.copyWith(
      energyWindows: rules.energyWindows
          .where(
            (window) =>
                window.dayKind == DayKind.any || window.dayKind == relevantKind,
          )
          .toList(growable: false),
      protectedTimes: rules.protectedTimes
          .where(
            (item) =>
                item.enabled &&
                (item.dayKind == DayKind.any || item.dayKind == relevantKind),
          )
          .toList(growable: false),
    );

    return ResolvedPlanningSettings(
      rules: rules,
      notifications: await loadNotificationPreferences(),
      trustAutoAdjust: (await repository.read(_trustAutoAdjustKey)) == 'true',
    );
  }

  Future<UserPlanningRules> loadUserRules() async {
    final raw = await repository.read(_userRulesKey);
    if (raw == null) return const UserPlanningRules();
    final json = jsonDecode(raw) as Map<String, Object?>;
    return UserPlanningRules(
      common: _patchFromJson(json['common']),
      weekday: _patchFromJson(json['weekday']),
      weekend: _patchFromJson(json['weekend']),
    );
  }

  Future<void> saveUserRules(UserPlanningRules rules) async {
    final errors = <String, String>{};
    _validatePatch(rules.common, errors);
    _validatePatch(rules.weekday, errors);
    _validatePatch(rules.weekend, errors);
    if (errors.isNotEmpty) throw SettingsValidationException(errors);
    await repository.write(
      _userRulesKey,
      jsonEncode({
        'common': _patchToJson(rules.common),
        'weekday': _patchToJson(rules.weekday),
        'weekend': _patchToJson(rules.weekend),
      }),
    );
  }

  Future<void> clearUserRules() => repository.remove(_userRulesKey);

  Future<void> saveDateOverride(
    DateTime localDate,
    PlanningRulesPatch override,
  ) async {
    final errors = <String, String>{};
    _validatePatch(override, errors);
    if (errors.isNotEmpty) throw SettingsValidationException(errors);
    await repository.write(
      _overrideKey(localDate),
      jsonEncode(_patchToJson(override)),
    );
  }

  Future<void> saveLearnedPreferences(PreferenceProfile profile) =>
      repository.write(
        _learnedPreferencesKey,
        jsonEncode({
          'enabled': profile.enabled,
          'preferredFocusMinutes': profile.preferredFocusMinutes,
          'preferredEnergyWindows': profile.preferredEnergyWindows
              ?.map(_energyWindowToJson)
              .toList(),
        }),
      );

  Future<void> clearLearnedPreferences() =>
      repository.remove(_learnedPreferencesKey);

  Future<NotificationPreferences> loadNotificationPreferences() async {
    final raw = await repository.read(_notificationsKey);
    if (raw == null) return NotificationPreferences();
    final value = jsonDecode(raw) as Map<String, Object?>;
    return NotificationPreferences(
      taskStartEnabled: value['taskStartEnabled'] as bool,
      taskStartLeadMinutes: value['taskStartLeadMinutes'] as int,
      calendarStartEnabled: value['calendarStartEnabled'] as bool,
      calendarStartLeadMinutes: value['calendarStartLeadMinutes'] as int,
      deadlineEnabled: value['deadlineEnabled'] as bool,
      deadlineLeadMinutes: value['deadlineLeadMinutes'] as int,
      conflictEnabled: value['conflictEnabled'] as bool,
      quietHours: _rangeFromJson(value['quietHours']),
    );
  }

  Future<void> saveNotificationPreferences(
    NotificationPreferences preferences,
  ) async {
    final leadTimes = [
      preferences.taskStartLeadMinutes,
      preferences.calendarStartLeadMinutes,
      preferences.deadlineLeadMinutes,
    ];
    if (leadTimes.any((value) => value < 0)) {
      throw const SettingsValidationException({
        'notificationLeadMinutes': '不能小于 0',
      });
    }
    await repository.write(
      _notificationsKey,
      jsonEncode({
        'taskStartEnabled': preferences.taskStartEnabled,
        'taskStartLeadMinutes': preferences.taskStartLeadMinutes,
        'calendarStartEnabled': preferences.calendarStartEnabled,
        'calendarStartLeadMinutes': preferences.calendarStartLeadMinutes,
        'deadlineEnabled': preferences.deadlineEnabled,
        'deadlineLeadMinutes': preferences.deadlineLeadMinutes,
        'conflictEnabled': preferences.conflictEnabled,
        'quietHours': _rangeToJson(preferences.quietHours),
      }),
    );
  }

  Future<void> setTrustAutoAdjust(bool value) =>
      repository.write(_trustAutoAdjustKey, value.toString());

  /// 读取已确认/已自动采用的学习偏好。
  ///
  /// 这是学习偏好的唯一读取入口：排程通过 `resolveForDate` 消费它，偏好页面
  /// 通过 `SettingsPreferenceStore` 写入它。此前偏好页面写的是另一个键
  /// （`planning.preferenceState.v1`）且 JSON 结构也不同，导致用户确认的偏好
  /// 永远不影响排程。
  Future<PreferenceProfile?> loadLearnedPreferences() async {
    final raw = await repository.read(_learnedPreferencesKey);
    if (raw == null) return null;
    final value = jsonDecode(raw) as Map<String, Object?>;
    final windows = value['preferredEnergyWindows'] as List<Object?>?;
    return PreferenceProfile(
      enabled: value['enabled'] as bool? ?? true,
      preferredFocusMinutes: value['preferredFocusMinutes'] as int?,
      preferredEnergyWindows: windows
          ?.map((item) => _energyWindowFromJson(item))
          .toList(growable: false),
    );
  }

  Future<PlanningRulesPatch?> _loadPatch(String key) async {
    final raw = await repository.read(key);
    return raw == null ? null : _patchFromJson(jsonDecode(raw));
  }

  static void _validatePatch(
    PlanningRulesPatch patch,
    Map<String, String> errors,
  ) {
    void positive(int? value, String key) {
      if (value != null && value <= 0) errors[key] = '必须大于 0';
    }

    positive(patch.minimumSleepMinutes, 'minimumSleepMinutes');
    positive(patch.defaultFocusMinutes, 'defaultFocusMinutes');
    positive(
      patch.dailyMovableTaskLimitMinutes,
      'dailyMovableTaskLimitMinutes',
    );
    positive(patch.minChunkMinutes, 'minChunkMinutes');
    positive(patch.maxChunkMinutes, 'maxChunkMinutes');
    if (patch.breakMinutes case final value? when value < 0) {
      errors['breakMinutes'] = '不能小于 0';
    }
    if (patch.weeklyLifeQuotaMinutes case final value? when value < 0) {
      errors['weeklyLifeQuotaMinutes'] = '不能小于 0';
    }
    if (patch.dailyMovableTaskLimitMinutes case final value?
        when value > LocalTimeRange.minutesPerDay) {
      errors['dailyMovableTaskLimitMinutes'] = '不能超过 1440 分钟';
    }
    final minChunk = patch.minChunkMinutes;
    final maxChunk = patch.maxChunkMinutes;
    if (minChunk != null && maxChunk != null && minChunk > maxChunk) {
      errors['maxChunkMinutes'] = '不能小于最短片段';
    }
    final windows = patch.energyWindows;
    if (windows != null && _hasConflictingOverlap(windows)) {
      errors['energyWindows'] = '精力区间不能重叠且使用不同级别';
    }
  }

  static bool _hasConflictingOverlap(List<EnergyWindow> windows) {
    for (var i = 0; i < windows.length; i++) {
      for (var j = i + 1; j < windows.length; j++) {
        final left = windows[i];
        final right = windows[j];
        if (left.level == right.level || !_dayKindsOverlap(left, right)) {
          continue;
        }
        for (final a in left.range.splitAtMidnight()) {
          for (final b in right.range.splitAtMidnight()) {
            if (a.dayOffset == b.dayOffset &&
                a.startMinute < b.endMinute &&
                b.startMinute < a.endMinute) {
              return true;
            }
          }
        }
      }
    }
    return false;
  }

  static bool _dayKindsOverlap(EnergyWindow left, EnergyWindow right) =>
      left.dayKind == DayKind.any ||
      right.dayKind == DayKind.any ||
      left.dayKind == right.dayKind;

  static String _overrideKey(DateTime date) =>
      'planning.dateOverride.${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

Map<String, Object?> _patchToJson(PlanningRulesPatch patch) => {
  if (patch.energyWindows != null)
    'energyWindows': patch.energyWindows!.map(_energyWindowToJson).toList(),
  if (patch.protectedTimes != null)
    'protectedTimes': patch.protectedTimes!
        .map(
          (item) => {
            'kind': item.kind.name,
            'range': _rangeToJson(item.range),
            'dayKind': item.dayKind.name,
            'enabled': item.enabled,
          },
        )
        .toList(),
  if (patch.sleepRange != null) 'sleepRange': _rangeToJson(patch.sleepRange!),
  if (patch.minimumSleepMinutes != null)
    'minimumSleepMinutes': patch.minimumSleepMinutes,
  if (patch.defaultFocusMinutes != null)
    'defaultFocusMinutes': patch.defaultFocusMinutes,
  if (patch.breakMinutes != null) 'breakMinutes': patch.breakMinutes,
  if (patch.dailyMovableTaskLimitMinutes != null)
    'dailyMovableTaskLimitMinutes': patch.dailyMovableTaskLimitMinutes,
  if (patch.weeklyLifeQuotaMinutes != null)
    'weeklyLifeQuotaMinutes': patch.weeklyLifeQuotaMinutes,
  if (patch.minChunkMinutes != null) 'minChunkMinutes': patch.minChunkMinutes,
  if (patch.maxChunkMinutes != null) 'maxChunkMinutes': patch.maxChunkMinutes,
  if (patch.granularityMinutes != null)
    'granularityMinutes': patch.granularityMinutes,
};

PlanningRulesPatch _patchFromJson(Object? raw) {
  if (raw == null) return const PlanningRulesPatch();
  final value = raw as Map<String, Object?>;
  final energy = value['energyWindows'] as List<Object?>?;
  final protected = value['protectedTimes'] as List<Object?>?;
  return PlanningRulesPatch(
    energyWindows: energy?.map(_energyWindowFromJson).toList(growable: false),
    protectedTimes: protected
        ?.map((item) {
          final json = item as Map<String, Object?>;
          return ProtectedTimeRule(
            kind: ProtectedTimeKind.values.byName(json['kind'] as String),
            range: _rangeFromJson(json['range']),
            dayKind: DayKind.values.byName(json['dayKind'] as String),
            enabled: json['enabled'] as bool,
          );
        })
        .toList(growable: false),
    sleepRange: value['sleepRange'] == null
        ? null
        : _rangeFromJson(value['sleepRange']),
    minimumSleepMinutes: value['minimumSleepMinutes'] as int?,
    defaultFocusMinutes: value['defaultFocusMinutes'] as int?,
    breakMinutes: value['breakMinutes'] as int?,
    dailyMovableTaskLimitMinutes: value['dailyMovableTaskLimitMinutes'] as int?,
    weeklyLifeQuotaMinutes: value['weeklyLifeQuotaMinutes'] as int?,
    minChunkMinutes: value['minChunkMinutes'] as int?,
    maxChunkMinutes: value['maxChunkMinutes'] as int?,
    granularityMinutes: value['granularityMinutes'] as int?,
  );
}

Map<String, Object?> _energyWindowToJson(EnergyWindow window) => {
  'range': _rangeToJson(window.range),
  'level': window.level.name,
  'dayKind': window.dayKind.name,
};

EnergyWindow _energyWindowFromJson(Object? raw) {
  final value = raw as Map<String, Object?>;
  return EnergyWindow(
    range: _rangeFromJson(value['range']),
    level: EnergyLevel.values.byName(value['level'] as String),
    dayKind: DayKind.values.byName(value['dayKind'] as String),
  );
}

Map<String, Object?> _rangeToJson(LocalTimeRange range) => {
  'startMinute': range.startMinute,
  'endMinute': range.endMinute,
};

LocalTimeRange _rangeFromJson(Object? raw) {
  final value = raw as Map<String, Object?>;
  return LocalTimeRange(
    startMinute: value['startMinute'] as int,
    endMinute: value['endMinute'] as int,
  );
}
