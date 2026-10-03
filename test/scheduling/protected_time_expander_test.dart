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

  test('终点为 24:00 的保护时间结束于次日本地零点', () {
    // 09:00–24:00 不跨午夜，但 endMinute 是 1440，而 localDateTimeToUtc 只接受
    // [0, 1439]：直接传 1440 会抛参数错误，整轮排程随之失败。
    final rules = DefaultSettings.v1().copyWith(
      protectedTimes: [
        ProtectedTimeRule(
          kind: ProtectedTimeKind.fixedRest,
          range: LocalTimeRange(
            startMinute: 9 * 60,
            endMinute: LocalTimeRange.minutesPerDay,
          ),
        ),
      ],
    );

    final intervals = expander.expand(
      rules: rules,
      startUtc: DateTime.utc(2026, 10, 5),
      endUtc: DateTime.utc(2026, 10, 7),
      timeZoneId: 'UTC',
    );

    expect(intervals.length, 2);
    expect(intervals.first.range.startUtc, DateTime.utc(2026, 10, 5, 9));
    expect(intervals.first.range.endUtc, DateTime.utc(2026, 10, 6));
    expect(intervals.first.range.durationMinutes, 15 * 60);
    expect(intervals.last.range.endUtc, DateTime.utc(2026, 10, 7));
  });

  test('夏令时切换日仍按当地钟点展开', () {
    // 2026-03-08 是美国夏令时开始日。当地 12:00–13:00 在 3/7 是 17:00Z（EST，
    // UTC-5），在 3/8 与 3/9 是 16:00Z（EDT，UTC-4）。三天都应当展开出当地 12:00
    // 的那一小时，说明换算走的是本地墙上时间而不是固定偏移。
    final rules = DefaultSettings.v1().copyWith(
      protectedTimes: [
        ProtectedTimeRule(
          kind: ProtectedTimeKind.fixedRest,
          range: LocalTimeRange(startMinute: 12 * 60, endMinute: 13 * 60),
        ),
      ],
    );

    final intervals = expander.expand(
      rules: rules,
      startUtc: DateTime.utc(2026, 3, 7, 12),
      // 窗口要一直覆盖到 3/9 当地中午之后，否则 3/9 那段会被正确地裁掉。
      endUtc: DateTime.utc(2026, 3, 10),
      timeZoneId: 'America/New_York',
    );

    expect(
      intervals.map((item) => item.range.startUtc).toList(),
      [
        DateTime.utc(2026, 3, 7, 17),
        DateTime.utc(2026, 3, 8, 16),
        DateTime.utc(2026, 3, 9, 16),
      ],
    );
    for (final item in intervals) {
      expect(item.range.durationMinutes, 60);
    }
  });
}
