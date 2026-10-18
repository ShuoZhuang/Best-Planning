import 'dart:convert';

import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/protected_time_overlap.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/window_behavior.dart';
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
    this.enabled = true,
    this.taskStartEnabled = true,
    this.taskStartLeadMinutes = 10,
    this.calendarStartEnabled = true,
    this.calendarStartLeadMinutes = 10,
    this.deadlineEnabled = true,
    this.deadlineLeadMinutes = 24 * 60,
    this.conflictEnabled = true,
    this.conflictLeadMinutes = 30,
    this.recurringGoalEnabled = true,
    LocalTimeRange? quietHours,
  }) : quietHours =
           quietHours ??
           LocalTimeRange(startMinute: 23 * 60 + 30, endMinute: 7 * 60 + 30);

  /// **通知总开关，默认开启**（1.8.0，设计规范 §5.1）。
  ///
  /// 关闭时下面五个分类值**保留但不生效**：用户关掉通知是为了"现在别打扰我"，不是
  /// "把我之前的选择全清掉"——再打开时他应当看到原来的勾选，而不是被重置成默认。
  ///
  /// 这就是它必须与分类开关分开、且取消逻辑必须"总开关优先"的原因：只按分类判断的话，
  /// 关掉总开关并不会取消任何东西（五个分类都还是 true）。
  final bool enabled;

  final bool taskStartEnabled;
  final int taskStartLeadMinutes;
  final bool calendarStartEnabled;
  final int calendarStartLeadMinutes;
  final bool deadlineEnabled;
  final int deadlineLeadMinutes;
  final bool conflictEnabled;

  /// 冲突待处理通知的提前时间。
  ///
  /// 需求 FR-NOTIFY-02 要求**每一种通知类型**都能单独设置提前时间，而冲突类型此前
  /// 只有开关没有提前时间。冲突本身不绑定具体时刻，因此提前时间是相对"现在"计算。
  final int conflictLeadMinutes;

  /// 周期目标提醒（周中进度、到期缺口、容量不足）的开关。默认开启。
  ///
  /// **默认与其它四类一致为 `true`**：路线图 §3.5 把这三条提醒当作周期目标功能的一部分，
  /// 而不是一个可选的锦上添花。用户在设置里可以单独关掉它——这是"能关"，不是"默认关"。
  final bool recurringGoalEnabled;

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
  SettingsService({required this.repository, this.onPlanningRulesChanged});

  static const _userRulesKey = 'planning.userRules.v1';
  static const _learnedPreferencesKey = 'planning.learnedPreferences.v1';
  static const _notificationsKey = 'notifications.v1';
  static const _trustAutoAdjustKey = 'planning.trustAutoAdjust.v1';
  static const _closeBehaviorKey = 'window.closeBehavior.v1';
  static const _absoluteMinimumSleepKey = 'planning.absoluteMinimumSleep.v1';
  static const _weeklyExtensionQuotaKey = 'planning.weeklyExtensionQuota.v1';
  static const _learningEnabledKey = 'planning.learning.enabled.v1';
  static const _learningAutoAdoptKey = 'planning.learning.autoAdopt.v1';
  static const _preferenceMigrationKey = 'planning.learning.migrated.v1';

  final SettingsRepository repository;

  /// **规划规则**成功保存之后的日历失效信号（计划 §2.6）。
  ///
  /// 只挂在 [saveUserRules] 与 [saveDateOverride] 上：这两处改的是作息、保护时间规则与
  /// 按日例外——它们直接决定日历上的保护时间区间。通知设置、关闭行为、信任自动调整与
  /// 学习偏好**都不发**：它们不改变任何一条日历条目，发信号只会让页面白刷一次
  /// （§2.6："通知设置、关闭行为等无关设置不发"）。
  ///
  /// 允许为空以保持测试替身轻量；生产组合根必须装配到那唯一的失效总线上。
  final void Function()? onPlanningRulesChanged;

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
    // **保护窗口重叠的校验必须在服务层**（Task 10 Step 5）。
    //
    // 第一版只把它写在设置页的 `_save()` 里。页面上确实挡住了，但**任何不经页面的
    // 调用方**（引导、日期覆盖、脚本、将来的批量编辑）都能写进一份"早餐与睡眠重叠"
    // 的规则——而那条规则会让保护分钟被重复计算。集成用例正是从服务直接调用时
    // 发现这一点的：`saveUserRules` 没有抛异常。
    //
    // 日型要分开算：工作日睡眠与周末早餐互不影响，因此逐日型各校验一次。
    for (final dayKind in const [DayKind.weekday, DayKind.weekend]) {
      _validateProtectedOverlap(rules, dayKind, errors);
    }
    if (errors.isNotEmpty) throw SettingsValidationException(errors);
    await repository.write(
      _userRulesKey,
      jsonEncode({
        'common': _patchToJson(rules.common),
        'weekday': _patchToJson(rules.weekday),
        'weekend': _patchToJson(rules.weekend),
      }),
    );
    // **校验通过且写入成功之后**才发（§2.6）：非法规则在上面就抛了，那时日历不该刷新
    // ——它读到的仍是旧的合法规则，刷新只会白读一次。
    onPlanningRulesChanged?.call();
  }

  /// 同一个日型里，保护窗口之间、以及与睡眠之间**不得重叠**（规范 §9.1）。
  ///
  /// **睡眠从 `common.sleepRange` 取，不从日型补丁取**。这一点我一开始写错了：
  /// 我先取 `patch.sleepRange ?? common.sleepRange`，而 `PlanningRulesPatch.sleepRange`
  /// 在**用户规则**里几乎总是 `null`——用户规则只带用户显式改过的那几项
  /// （见 `PlanningRulesPatch` 的"可空即未设置"约定）。于是 `sleep` 恒为空、
  /// 这个校验**一次都没生效**，而我当时以为它挡住了。
  ///
  /// 实测证据（探针输出）：`DBGOV entered day=DayKind.weekday` / `n=1 sleep=null`。
  ///
  /// 现在按真实存放位置读：睡眠是 `common` 上的一项全局规则，因此它就在那里。
  ///
  /// **不静默合并**：合并会**重复计算保护分钟**——重叠的那段时间被算两遍，
  /// 用户看到的总保护时长凭空变多。因此这里报错并指出具体区间。
  static void _validateProtectedOverlap(
    UserPlanningRules rules,
    DayKind dayKind,
    Map<String, String> errors,
  ) {
    final patch = switch (dayKind) {
      DayKind.weekend => rules.weekend,
      _ => rules.weekday,
    };
    final protected = [
      ...?rules.common.protectedTimes,
      ...?patch.protectedTimes,
    ].where((rule) => rule.enabled).toList();
    if (protected.isEmpty) return;
    final sleep = rules.common.sleepRange;
    if (sleep == null) return;

    for (final rule in protected) {
      final overlaps = findProtectedTimeOverlaps(
        kind: rule.kind,
        range: rule.range,
        // **只看与它同类日型的窗口**：工作日睡眠与周末早餐互不影响。
        protectedTimes: [
          for (final other in protected)
            if (other.kind != rule.kind || !identical(other, rule)) other,
        ],
        sleepRange: sleep,
        dayKind: dayKind,
      );
      if (overlaps.isEmpty) continue;
      errors['protected-${rule.kind.name}'] = overlaps.first.describe();
    }
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
    // 按日例外同样会改变那一天的规则，因此与 `saveUserRules` 同一口径：只在写入成功后发。
    onPlanningRulesChanged?.call();
  }

  /// 读取某一天的临时例外；没有则返回 `null`。
  ///
  /// **为什么需要它**：例外此前**只能写不能读**（`_loadPatch` 是私有的），因此界面上无法
  /// 显示"这一天被放宽成了多少"，统计也无法说明"哪一天用户临时放宽过"（FR-STAT-05 的
  /// 休息保护情况正是缺这一项）。看不到自己设过的例外，用户就只能靠猜。
  Future<PlanningRulesPatch?> loadDateOverride(DateTime localDate) =>
      _loadPatch(_overrideKey(localDate));

  /// 清除某一天的临时例外（FR-REPLAN-07 的"临时放宽"必须可逆）。
  ///
  /// **这一条是 C8 的教训直接要求的**：C8 记录的原缺陷正是"`saveDateOverride` 有唯一写入方
  /// 却**没有任何清除路径**，于是用户只要预览过一次恢复方案，那一天的睡眠例外就永久生效"。
  /// 因此"临时放宽"这条入口在设计上就必须自带撤销——它放宽的是**硬约束**
  /// （每日可移动任务上限），留下一个清不掉的放宽比没有这条入口更糟。
  Future<void> clearDateOverride(DateTime localDate) =>
      repository.remove(_overrideKey(localDate));

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
      // 与 `recurringGoalEnabled` 同一口径：**缺键时默认开启**。1.7.1 及以前存下的设置
      // 里没有 `enabled`，强转会在启动路径上抛；而"老用户升级后收不到任何通知"是更坏的默认。
      enabled: value['enabled'] as bool? ?? true,
      taskStartEnabled: value['taskStartEnabled'] as bool,
      taskStartLeadMinutes: value['taskStartLeadMinutes'] as int,
      calendarStartEnabled: value['calendarStartEnabled'] as bool,
      calendarStartLeadMinutes: value['calendarStartLeadMinutes'] as int,
      deadlineEnabled: value['deadlineEnabled'] as bool,
      deadlineLeadMinutes: value['deadlineLeadMinutes'] as int,
      conflictEnabled: value['conflictEnabled'] as bool,
      conflictLeadMinutes: value['conflictLeadMinutes'] as int? ?? 30,
      // **缺失时默认开启**，而不是 `as bool`：1.7 之前存下的设置里没有这个键，
      // 直接强转会抛在启动路径上；而"老用户升级后收不到周期目标提醒"也是错的默认。
      recurringGoalEnabled: value['recurringGoalEnabled'] as bool? ?? true,
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
      preferences.conflictLeadMinutes,
    ];
    if (leadTimes.any((value) => value < 0)) {
      throw const SettingsValidationException({
        'notificationLeadMinutes': '不能小于 0',
      });
    }
    await repository.write(
      _notificationsKey,
      jsonEncode({
        'enabled': preferences.enabled,
        'taskStartEnabled': preferences.taskStartEnabled,
        'taskStartLeadMinutes': preferences.taskStartLeadMinutes,
        'calendarStartEnabled': preferences.calendarStartEnabled,
        'calendarStartLeadMinutes': preferences.calendarStartLeadMinutes,
        'deadlineEnabled': preferences.deadlineEnabled,
        'deadlineLeadMinutes': preferences.deadlineLeadMinutes,
        'conflictEnabled': preferences.conflictEnabled,
        'conflictLeadMinutes': preferences.conflictLeadMinutes,
        'recurringGoalEnabled': preferences.recurringGoalEnabled,
        'quietHours': _rangeToJson(preferences.quietHours),
      }),
    );
  }

  Future<void> setTrustAutoAdjust(bool value) =>
      repository.write(_trustAutoAdjustKey, value.toString());

  /// 绝对最低睡眠（算法 20，规范 §8.2）。默认 6 小时，只能由用户修改。
  ///
  /// 与 `PlanningRules.minimumSleepMinutes`（长期目标睡眠）**分开保存**：一次晚睡
  /// 不得改变长期作息，而绝对最低线是延长日候选的硬边界。
  Future<int> loadAbsoluteMinimumSleepMinutes() async {
    final raw = await repository.read(_absoluteMinimumSleepKey);
    final value = raw == null ? null : int.tryParse(raw);
    return (value == null || value <= 0) ? 6 * 60 : value.clamp(60, 24 * 60);
  }

  Future<void> saveAbsoluteMinimumSleepMinutes(int minutes) {
    if (minutes < 60 || minutes > 24 * 60) {
      throw const SettingsValidationException({
        'absoluteMinimumSleepMinutes': '必须在 60..1440 分钟之间',
      });
    }
    return repository.write(_absoluteMinimumSleepKey, '$minutes');
  }

  /// 滚动 7 天允许的临时延长日次数（0、1、2），默认 2（规范 §8.2）。
  Future<int> loadWeeklyExtensionQuota() async {
    final raw = await repository.read(_weeklyExtensionQuotaKey);
    final value = raw == null ? null : int.tryParse(raw);
    return (value == null || value < 0 || value > 2) ? 2 : value;
  }

  Future<void> saveWeeklyExtensionQuota(int value) {
    if (value < 0 || value > 2) {
      throw const SettingsValidationException({
        'weeklyExtensionQuota': '只能是 0、1 或 2',
      });
    }
    return repository.write(_weeklyExtensionQuotaKey, '$value');
  }

  /// 学习总开关。关闭学习只停止建议，不删除已有证据（规范 §9.4）。
  Future<bool> loadLearningEnabled() async =>
      (await repository.read(_learningEnabledKey)) != 'false';

  Future<void> saveLearningEnabled(bool enabled) =>
      repository.write(_learningEnabledKey, enabled.toString());

  /// 自动采用学习建议。默认关闭。
  Future<bool> loadLearningAutoAdopt() async =>
      (await repository.read(_learningAutoAdoptKey)) == 'true';

  Future<void> saveLearningAutoAdopt(bool enabled) =>
      repository.write(_learningAutoAdoptKey, enabled.toString());

  /// 旧 `planning.learnedPreferences.v1` 是否已迁移到规则表。
  Future<bool> isPreferenceMigrationDone() async =>
      (await repository.read(_preferenceMigrationKey)) == 'true';

  Future<void> markPreferenceMigrationDone() =>
      repository.write(_preferenceMigrationKey, 'true');

  /// 读取"信任自动调整"。此前只有 setter，加上 `resolveForDate` 里那次内联解析，
  /// 启动路径上没有读取它的入口（W8）。
  Future<bool> loadTrustAutoAdjust() async =>
      (await repository.read(_trustAutoAdjustKey)) == 'true';

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

  /// 关闭主窗口时的行为。从未设置过时是"最小化到后台运行"。
  Future<WindowCloseBehavior> loadCloseBehavior() async =>
      WindowCloseBehavior.fromStorage(await repository.read(_closeBehaviorKey));

  Future<void> saveCloseBehavior(WindowCloseBehavior behavior) =>
      repository.write(_closeBehaviorKey, behavior.name);

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
    // 与 `breakMinutes` 同为**非负**：`0` 是合法的关闭方式（用户 2026-10-08 明确要能关掉
    // 课后缓冲）。用正数校验会让"关闭"变成一条非法输入。
    if (patch.courseTransitionMinutes case final value? when value < 0) {
      errors['courseTransitionMinutes'] = '不能小于 0';
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
  if (patch.courseTransitionMinutes != null)
    'courseTransitionMinutes': patch.courseTransitionMinutes,
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
    // **缺键时给 `null` 而不是 `10`**：`null` 表示"这个覆盖没有提到它"，于是
    // `applyTo` 会保留基线的值。写死 10 会让一条本该保留基线（用户改过）的覆盖把它压回默认。
    courseTransitionMinutes: value['courseTransitionMinutes'] as int?,
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
