import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';

void main() {
  ScheduleRuleOverride overrideFor(DateTime date) => ScheduleRuleOverride(
    localDate: date,
    patch: PlanningRulesPatch(
      sleepRange: LocalTimeRange(startMinute: 60, endMinute: 8 * 60),
    ),
  );

  test('同一天即使时刻不同也算命中', () {
    // 日期来源不同：界面给的是 `DateTime(y, m, d)`，而解析窗口用的是本地零点/带时刻的
    // 本地时间。若按 `DateTime ==` 比较，同一天会被判为不同，覆盖被静默丢弃。
    final override = overrideFor(DateTime(2026, 10, 3));

    expect(override.appliesTo(DateTime(2026, 10, 3)), isTrue);
    expect(override.appliesTo(DateTime(2026, 10, 3, 23, 59)), isTrue);
    expect(override.appliesTo(DateTime(2026, 10, 3, 0, 0, 1)), isTrue);
  });

  test('不同日期不命中', () {
    final override = overrideFor(DateTime(2026, 10, 3));

    expect(override.appliesTo(DateTime(2026, 10, 4)), isFalse);
    expect(override.appliesTo(DateTime(2026, 10, 2)), isFalse);
    expect(override.appliesTo(DateTime(2025, 10, 3)), isFalse);
    expect(override.appliesTo(DateTime(2026, 11, 3)), isFalse);
  });

  test('覆盖只改显式给出的字段', () {
    // `applyTo` 用的是 `copyWith` 语义：没写的字段保持原值，因此一次性覆盖
    // 不会顺手清掉用户的其它设置。
    final base = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 23 * 60, endMinute: 7 * 60),
      minimumSleepMinutes: 420,
      defaultFocusMinutes: 50,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 240,
      weeklyLifeQuotaMinutes: 600,
    );

    final patched = overrideFor(DateTime(2026, 10, 3)).patch.applyTo(base);

    expect(patched.sleepRange, LocalTimeRange(startMinute: 60, endMinute: 480));
    expect(patched.minimumSleepMinutes, 420);
    expect(patched.defaultFocusMinutes, 50);
    expect(patched.dailyMovableTaskLimitMinutes, 240);
    expect(patched.weeklyLifeQuotaMinutes, 600);
  });
}
