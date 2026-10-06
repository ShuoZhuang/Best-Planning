import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/recurrence_expander.dart';

void main() {
  final zones = TimeZoneDatabase();
  final expander = RecurrenceExpander(zones);

  test('每周本地九点在夏令时切换后仍保持九点', () {
    final rule = RecurrenceRule(
      id: 'rule-1',
      weekdays: {DateTime.monday},
      localStartMinute: 9 * 60,
      durationMinutes: 60,
      validFromLocalDate: DateTime(2026, 3, 2),
      validUntilLocalDate: DateTime(2026, 3, 16),
      timeZoneId: 'America/New_York',
    );
    final window = TimeRange(
      startUtc: DateTime.utc(2026, 3, 1),
      endUtc: DateTime.utc(2026, 3, 18),
    );

    final occurrences = expander.expand(rule, window, const []);

    expect(occurrences, hasLength(3));
    expect(occurrences.map((item) => item.startUtc.hour), [14, 13, 13]);
    for (final occurrence in occurrences) {
      final local = zones.toLocal(occurrence.startUtc, 'America/New_York');
      expect(local.hour, 9);
      expect(local.minute, 0);
    }
  });

  test('支持删除单次、修改单次、有效日期和跨午夜', () {
    final rule = RecurrenceRule(
      id: 'rule-2',
      weekdays: {DateTime.saturday},
      localStartMinute: 23 * 60 + 30,
      durationMinutes: 120,
      validFromLocalDate: DateTime(2026, 10, 3),
      validUntilLocalDate: DateTime(2026, 10, 17),
      timeZoneId: 'Asia/Shanghai',
    );
    final replacementStart = zones.localDateTimeToUtc(
      DateTime(2026, 10, 17),
      20 * 60,
      'Asia/Shanghai',
    );
    final exceptions = [
      RecurrenceException.deleted(localDate: DateTime(2026, 10, 10)),
      RecurrenceException.replaced(
        localDate: DateTime(2026, 10, 17),
        replacement: TimeRange(
          startUtc: replacementStart,
          endUtc: replacementStart.add(const Duration(minutes: 90)),
        ),
      ),
    ];

    final occurrences = expander.expand(
      rule,
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 1),
        endUtc: DateTime.utc(2026, 10, 20),
      ),
      exceptions,
    );

    expect(occurrences, hasLength(2));
    final firstEndLocal = zones.toLocal(
      occurrences.first.endUtc,
      'Asia/Shanghai',
    );
    expect(
      (firstEndLocal.day, firstEndLocal.hour, firstEndLocal.minute),
      (4, 1, 30),
    );
    expect(occurrences.last.startUtc, replacementStart);
    expect(occurrences.last.durationMinutes, 90);
  });

  test('每两周按有效起点所在的本地周展开，并包含结束日', () {
    final rule = RecurrenceRule(
      id: 'rule-fortnight',
      weekdays: {DateTime.monday, DateTime.wednesday},
      localStartMinute: 8 * 60,
      durationMinutes: 45,
      intervalWeeks: 2,
      validFromLocalDate: DateTime(2026, 10, 5),
      validUntilLocalDate: DateTime(2026, 10, 21),
      timeZoneId: 'Asia/Shanghai',
    );

    final occurrences = expander.expand(
      rule,
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 4),
        endUtc: DateTime.utc(2026, 10, 23),
      ),
      const [],
    );

    expect(occurrences.map((item) => item.localDate), [
      DateTime(2026, 10, 5),
      DateTime(2026, 10, 7),
      DateTime(2026, 10, 19),
      DateTime(2026, 10, 21),
    ]);
  });

  test('单双周由不同的有效起点锚定，而不是只贴标签', () {
    RecurrenceRule rule(DateTime validFrom) => RecurrenceRule(
      id: 'rule-${validFrom.day}',
      weekdays: {DateTime.monday},
      localStartMinute: 9 * 60,
      durationMinutes: 60,
      intervalWeeks: 2,
      validFromLocalDate: validFrom,
      timeZoneId: 'Asia/Shanghai',
    );
    final window = TimeRange(
      startUtc: DateTime.utc(2026, 9, 6),
      endUtc: DateTime.utc(2026, 10, 5),
    );

    final odd = expander.expand(rule(DateTime(2026, 9, 7)), window, const []);
    final even = expander.expand(rule(DateTime(2026, 9, 14)), window, const []);

    expect(odd.map((item) => item.localDate.day), [7, 21]);
    expect(even.map((item) => item.localDate.day), [14, 28]);
  });

  test('隔周规则跨夏令时后仍保持本地九点', () {
    final rule = RecurrenceRule(
      id: 'rule-dst-fortnight',
      weekdays: {DateTime.monday},
      localStartMinute: 9 * 60,
      durationMinutes: 60,
      intervalWeeks: 2,
      validFromLocalDate: DateTime(2026, 10, 26),
      validUntilLocalDate: DateTime(2026, 11, 9),
      timeZoneId: 'America/New_York',
    );

    final occurrences = expander.expand(
      rule,
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 25),
        endUtc: DateTime.utc(2026, 11, 11),
      ),
      const [],
    );

    expect(occurrences.map((item) => item.startUtc.hour), [13, 14]);
    expect(
      occurrences.map(
        (item) => zones.toLocal(item.startUtc, 'America/New_York').hour,
      ),
      [9, 9],
    );
  });

  test('重复间隔只允许 1 到 52 周', () {
    RecurrenceRule create(int intervalWeeks) => RecurrenceRule(
      id: 'rule-invalid',
      weekdays: {DateTime.monday},
      localStartMinute: 9 * 60,
      durationMinutes: 60,
      intervalWeeks: intervalWeeks,
      validFromLocalDate: DateTime(2026, 10, 5),
      timeZoneId: 'UTC',
    );

    expect(() => create(0), throwsArgumentError);
    expect(() => create(53), throwsArgumentError);
    expect(create(1).intervalWeeks, 1);
    expect(create(52).intervalWeeks, 52);
  });
}
