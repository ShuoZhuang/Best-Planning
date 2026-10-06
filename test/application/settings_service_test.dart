import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart'
    show AppDatabase;
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/window_behavior.dart';

void main() {
  late AppDatabase database;
  late DriftSettingsRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftSettingsRepository(database, const _Clock());
  });

  tearDown(() => database.close());

  test('关闭窗口行为默认为收进后台，存下后读回同一值', () async {
    final service = SettingsService(repository: repository);
    // 从未设置过：默认"收进后台运行"，这是用户要求的常态。
    expect(
      await service.loadCloseBehavior(),
      WindowCloseBehavior.minimizeToTray,
    );

    await service.saveCloseBehavior(WindowCloseBehavior.quit);
    expect(await service.loadCloseBehavior(), WindowCloseBehavior.quit);

    await service.saveCloseBehavior(WindowCloseBehavior.minimizeToTray);
    expect(
      await service.loadCloseBehavior(),
      WindowCloseBehavior.minimizeToTray,
    );
  });

  test('存储里是不认识的值时退回默认，而不是启动失败', () async {
    // 这个键是用户可手改的存储项：读到垃圾值时能开机比抛异常有用。
    await repository.write('window.closeBehavior.v1', 'whatever');
    final service = SettingsService(repository: repository);
    expect(
      await service.loadCloseBehavior(),
      WindowCloseBehavior.minimizeToTray,
    );
  });

  test('指定日期、用户规则、已确认偏好和默认值按优先级解析', () async {
    final service = SettingsService(repository: repository);
    await service.saveLearnedPreferences(
      const PreferenceProfile(preferredFocusMinutes: 55),
    );
    await service.saveUserRules(
      const UserPlanningRules(
        common: PlanningRulesPatch(defaultFocusMinutes: 60),
      ),
    );
    await service.saveDateOverride(
      DateTime(2026, 10, 2),
      const PlanningRulesPatch(defaultFocusMinutes: 65),
    );

    expect(
      (await service.resolveForDate(DateTime(2026, 10, 2)))
          .rules
          .defaultFocusMinutes,
      65,
    );
    expect(
      (await service.resolveForDate(DateTime(2026, 10, 3)))
          .rules
          .defaultFocusMinutes,
      60,
    );

    final learnedOnly = SettingsService(
      repository: DriftSettingsRepository(database, const _Clock()),
    );
    await learnedOnly.clearUserRules();
    expect(
      (await learnedOnly.resolveForDate(DateTime(2026, 10, 3)))
          .rules
          .defaultFocusMinutes,
      55,
    );
    await learnedOnly.clearLearnedPreferences();
    expect(
      (await learnedOnly.resolveForDate(DateTime(2026, 10, 3)))
          .rules
          .defaultFocusMinutes,
      50,
    );
  });

  test('未标记的时段使用中性精力权重', () async {
    final resolved = await SettingsService(repository: repository)
        .resolveForDate(DateTime(2026, 10, 2));

    expect(resolved.energyLevelAt(10 * 60), EnergyLevel.high);
    expect(resolved.energyLevelAt(13 * 60), isNull);
  });

  test('学习偏好不能更改用户保存的硬约束', () async {
    final service = SettingsService(repository: repository);
    await service.saveUserRules(
      const UserPlanningRules(
        common: PlanningRulesPatch(
          minimumSleepMinutes: 450,
          weeklyLifeQuotaMinutes: 420,
        ),
        weekday: PlanningRulesPatch(dailyMovableTaskLimitMinutes: 300),
      ),
    );
    await service.saveLearnedPreferences(
      PreferenceProfile(
        preferredFocusMinutes: 65,
        preferredEnergyWindows: [
          EnergyWindow(
            range: LocalTimeRange(startMinute: 8 * 60, endMinute: 10 * 60),
            level: EnergyLevel.high,
          ),
        ],
      ),
    );

    final resolved = await service.resolveForDate(DateTime(2026, 10, 2));
    expect(resolved.rules.minimumSleepMinutes, 450);
    expect(resolved.rules.dailyMovableTaskLimitMinutes, 300);
    expect(resolved.rules.weeklyLifeQuotaMinutes, 420);
    expect(resolved.rules.defaultFocusMinutes, 65);
  });

  test('重启服务后用户设置仍优先于默认值', () async {
    final first = SettingsService(repository: repository);
    await first.saveUserRules(
      const UserPlanningRules(
        weekend: PlanningRulesPatch(dailyMovableTaskLimitMinutes: 480),
      ),
    );

    final restarted = SettingsService(
      repository: DriftSettingsRepository(database, const _Clock()),
    );
    final resolved = await restarted.resolveForDate(DateTime(2026, 10, 3));

    expect(resolved.rules.dailyMovableTaskLimitMinutes, 480);
  });

  test('拒绝级别冲突的重叠精力区间和非法时长', () async {
    final service = SettingsService(repository: repository);
    final overlapping = [
      EnergyWindow(
        range: LocalTimeRange(startMinute: 9 * 60, endMinute: 12 * 60),
        level: EnergyLevel.high,
      ),
      EnergyWindow(
        range: LocalTimeRange(startMinute: 11 * 60, endMinute: 13 * 60),
        level: EnergyLevel.medium,
      ),
    ];

    await expectLater(
      service.saveUserRules(
        UserPlanningRules(
          common: PlanningRulesPatch(
            energyWindows: overlapping,
            breakMinutes: -1,
            dailyMovableTaskLimitMinutes: 1441,
          ),
        ),
      ),
      throwsA(
        isA<SettingsValidationException>().having(
          (error) => error.fieldErrors.keys,
          'field errors',
          containsAll(<String>[
            'energyWindows',
            'breakMinutes',
            'dailyMovableTaskLimitMinutes',
          ]),
        ),
      ),
    );
  });
}

final class _Clock implements Clock {
  const _Clock();

  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 2, 8);
}
