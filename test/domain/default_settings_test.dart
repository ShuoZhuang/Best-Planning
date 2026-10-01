import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';

void main() {
  group('DefaultSettings.v1', () {
    test('提供可立即排程的作息、精力和容量默认值', () {
      final rules = DefaultSettings.v1();

      expect(rules.energyWindows, hasLength(3));
      expect(
        rules.energyWindows
            .singleWhere((window) => window.level == EnergyLevel.high)
            .range,
        LocalTimeRange(startMinute: 9 * 60, endMinute: 12 * 60),
      );
      expect(
        rules.energyWindows
            .singleWhere((window) => window.level == EnergyLevel.medium)
            .range,
        LocalTimeRange(startMinute: 14 * 60, endMinute: 17 * 60),
      );
      expect(
        rules.energyWindows
            .singleWhere((window) => window.level == EnergyLevel.low)
            .range,
        LocalTimeRange(startMinute: 19 * 60, endMinute: 22 * 60),
      );
      expect(
        rules.sleepRange,
        LocalTimeRange(startMinute: 23 * 60 + 30, endMinute: 7 * 60 + 30),
      );
      expect(rules.minimumSleepMinutes, 420);
      expect(rules.defaultFocusMinutes, 50);
      expect(rules.breakMinutes, 10);
      expect(rules.dailyMovableTaskLimitMinutes, 360);
      expect(rules.weeklyLifeQuotaMinutes, 360);
      expect(rules.granularityMinutes, 5);
    });

    test('按临时例外、用户设置、已确认偏好和默认值的顺序解析', () {
      const learned = PreferenceProfile(preferredFocusMinutes: 55);
      const user = PlanningRulesPatch(defaultFocusMinutes: 60);
      const dateOverride = PlanningRulesPatch(defaultFocusMinutes: 65);

      expect(
        DefaultSettings.resolve(
          confirmedPreferences: learned,
          userRules: user,
          dateOverride: dateOverride,
        ).defaultFocusMinutes,
        65,
      );
      expect(
        DefaultSettings.resolve(
          confirmedPreferences: learned,
          userRules: user,
        ).defaultFocusMinutes,
        60,
      );
      expect(
        DefaultSettings.resolve(confirmedPreferences: learned)
            .defaultFocusMinutes,
        55,
      );
      expect(DefaultSettings.resolve().defaultFocusMinutes, 50);
    });
  });
}
