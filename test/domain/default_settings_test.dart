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

    test('默认值自身满足"可立即排程"所需的一致性', () {
      // 上一条用例钉住的是设计文档默认值表里的**具体数值**；这一条钉住这些数值必须满足的
      // **性质**。差别在于：破坏一致性的改动（例如把夜间区间改短到低于最低睡眠、让两个精力
      // 区间重叠、把粒度改成不能整除专注时长）能被它抓住，而纯快照断言抓不住——快照可以
      // 跟着实现一起被改，那正是 §13.0 记的"复述实现"。
      final rules = DefaultSettings.v1();

      // 作息：夜间区间跨零点，时长按环绕计算。
      const minutesPerDay = 24 * 60;
      final sleepMinutes =
          (rules.sleepRange.endMinute -
              rules.sleepRange.startMinute +
              minutesPerDay) %
          minutesPerDay;
      expect(sleepMinutes, greaterThanOrEqualTo(rules.minimumSleepMinutes));

      // 精力区间按时间递增且互不重叠：重叠意味着同一时刻有两个精力等级，排程无从取舍。
      final ordered = [...rules.energyWindows]
        ..sort((a, b) => a.range.startMinute.compareTo(b.range.startMinute));
      for (var index = 1; index < ordered.length; index++) {
        expect(
          ordered[index].range.startMinute,
          greaterThanOrEqualTo(ordered[index - 1].range.endMinute),
        );
      }
      // 每一档都要有，且各只出现一次（上一条用例用 singleWhere 逐个取值，本身就是这个前提）。
      expect(
        ordered.map((window) => window.level).toSet(),
        hasLength(ordered.length),
      );

      // 粒度必须能整除专注时长，否则排出的块会落在粒度网格之外。
      expect(rules.granularityMinutes, greaterThan(0));
      expect(rules.defaultFocusMinutes % rules.granularityMinutes, 0);

      // 容量类默认值必须为正：为 0 等于"不安排任何事"，与"可立即排程的默认值"自相矛盾。
      expect(rules.dailyMovableTaskLimitMinutes, greaterThan(0));
      expect(rules.weeklyLifeQuotaMinutes, greaterThan(0));
      expect(rules.breakMinutes, greaterThanOrEqualTo(0));
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
