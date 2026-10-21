import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

/// 学习偏好写入端（偏好页面）与读取端（排程）必须共用同一个键与同一份 JSON 结构。
///
/// 这两端此前各自自洽却从不互通：写入端用 `planning.preferenceState.v1` 并把偏好
/// 包在 `profile` 字段下，读取端用 `planning.learnedPreferences.v1` 且期望
/// 精力区间是 `{'range': {...}}` 的嵌套结构。结果是用户在偏好页面确认的偏好
/// 永远不影响排程，而且单纯对齐键名还会因为结构不同而变成崩溃。
///
/// 该测试的作用是把这条跨模块约定固化下来，而不是只验证单侧自洽。
void main() {
  test('偏好页面保存的学习偏好会被排程读到', () async {
    final repository = MemorySettingsRepository();
    final store = SettingsPreferenceStore(repository);
    final settings = SettingsService(repository: repository);
    final day = DateTime(2026, 10, 5);

    expect((await settings.resolveForDate(day)).rules.defaultFocusMinutes, 50);

    await store.saveProfile(
      PreferenceProfile(
        enabled: true,
        preferredFocusMinutes: 75,
        preferredEnergyWindows: [
          EnergyWindow(
            range: LocalTimeRange(startMinute: 600, endMinute: 720),
            level: EnergyLevel.low,
          ),
        ],
      ),
    );

    final resolved = await settings.resolveForDate(day);
    expect(resolved.rules.defaultFocusMinutes, 75);
    // 精力区间往返成功，说明两端的 JSON 结构一致。
    expect(resolved.rules.energyWindows, hasLength(1));
    expect(resolved.rules.energyWindows.single.level, EnergyLevel.low);
    expect(resolved.rules.energyWindows.single.range.startMinute, 600);
    expect((await store.loadProfile()).preferredFocusMinutes, 75);
  });

  test('清除学习结果会同时删除排程读取的那份偏好', () async {
    final repository = MemorySettingsRepository();
    final store = SettingsPreferenceStore(repository);
    final settings = SettingsService(repository: repository);
    final day = DateTime(2026, 10, 5);

    await store.saveProfile(
      const PreferenceProfile(enabled: true, preferredFocusMinutes: 75),
    );
    expect((await settings.resolveForDate(day)).rules.defaultFocusMinutes, 75);

    await store.clearLearned();

    // 清除会写入显式的"已停用"档案，而不是删除键：用户需要能区分
    // "我清空过学习结果"与"我还没用过这个功能"。
    final cleared = await settings.loadLearnedPreferences();
    expect(cleared, isNotNull);
    expect(cleared!.enabled, isFalse);
    expect(cleared.preferredFocusMinutes, isNull);
    expect((await settings.resolveForDate(day)).rules.defaultFocusMinutes, 50);
    expect((await store.loadProfile()).enabled, isFalse);
  });

  test('用户主动设置优先于学习偏好', () async {
    final repository = MemorySettingsRepository();
    final store = SettingsPreferenceStore(repository);
    final settings = SettingsService(repository: repository);

    await store.saveProfile(
      const PreferenceProfile(enabled: true, preferredFocusMinutes: 75),
    );
    await settings.saveUserRules(
      const UserPlanningRules(
        common: PlanningRulesPatch(defaultFocusMinutes: 90),
      ),
    );

    final resolved = await settings.resolveForDate(DateTime(2026, 10, 5));
    expect(resolved.rules.defaultFocusMinutes, 90);
    // 学习偏好仍在，只是被用户设置覆盖。
    expect((await store.loadProfile()).preferredFocusMinutes, 75);
  });
}
