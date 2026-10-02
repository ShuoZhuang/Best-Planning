import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/protected_time_expander.dart';

void main() {
  final zones = TimeZoneDatabase();
  final expander = ProtectedTimeExpander(zones);

  test('把默认午餐与晚餐保护时间展开到窗口内的每一天', () {
    final intervals = expander.expand(
      rules: DefaultSettings.v1(),
      startUtc: DateTime.utc(2026, 10, 5),
      endUtc: DateTime.utc(2026, 10, 12),
      timeZoneId: 'UTC',
    );

    // 午餐与晚餐各 7 天。
    expect(intervals.length, 14);
    final lunches = intervals
        .where((item) => item.id.startsWith('protected:lunch:'))
        .toList();
    expect(lunches.length, 7);
    // 每天各有一段，且都落在当地 12:00（本例时区为 UTC）。
    expect(lunches.map((item) => item.range.startUtc).toSet().length, 7);
    for (final lunch in lunches) {
      expect(lunch.range.startUtc.hour, 12);
      expect(lunch.range.durationMinutes, 60);
    }
  });

  test('跨午夜的保护时间结束于次日而不是被截断', () {
    final rules = DefaultSettings.v1().copyWith(
      protectedTimes: [
        ProtectedTimeRule(
          kind: ProtectedTimeKind.fixedRest,
          range: LocalTimeRange(startMinute: 23 * 60, endMinute: 7 * 60),
        ),
      ],
    );

    final intervals = expander.expand(
      rules: rules,
      startUtc: DateTime.utc(2026, 10, 5),
      endUtc: DateTime.utc(2026, 10, 7),
      timeZoneId: 'UTC',
    );

    final first = intervals.first;
    expect(first.range.startUtc, DateTime.utc(2026, 10, 5, 23));
    expect(first.range.endUtc, DateTime.utc(2026, 10, 6, 7));
    expect(first.range.durationMinutes, 8 * 60);
  });

  test('只展开与当天类型匹配的保护时间', () {
    final rules = DefaultSettings.v1().copyWith(
      protectedTimes: [
        ProtectedTimeRule(
          kind: ProtectedTimeKind.fixedRest,
          range: LocalTimeRange(startMinute: 12 * 60, endMinute: 13 * 60),
          dayKind: DayKind.weekend,
        ),
      ],
    );

    // 2026-10-10 是周六、2026-10-11 是周日。
    final weekend = expander.expand(
      rules: rules,
      startUtc: DateTime.utc(2026, 10, 10),
      endUtc: DateTime.utc(2026, 10, 12),
      timeZoneId: 'UTC',
    );
    expect(weekend.length, 2);

    // 2026-10-05 是周一。
    final weekday = expander.expand(
      rules: rules,
      startUtc: DateTime.utc(2026, 10, 5),
      endUtc: DateTime.utc(2026, 10, 7),
      timeZoneId: 'UTC',
    );
    expect(weekday, isEmpty);
  });

  test('按本地墙上时间而不是 UTC 展开', () {
    // 东八区 12:00 午餐对应 04:00Z。
    final intervals = expander.expand(
      rules: DefaultSettings.v1(),
      startUtc: DateTime.utc(2026, 10, 4, 16),
      endUtc: DateTime.utc(2026, 10, 5, 16),
      timeZoneId: 'Asia/Shanghai',
    );

    final lunch = intervals.singleWhere(
      (item) => item.id.startsWith('protected:lunch:'),
    );
    expect(lunch.range.startUtc, DateTime.utc(2026, 10, 5, 4));
    expect(lunch.range.endUtc, DateTime.utc(2026, 10, 5, 5));
  });
}
