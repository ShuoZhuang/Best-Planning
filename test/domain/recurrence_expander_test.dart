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
}
