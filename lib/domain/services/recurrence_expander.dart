import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';

final class RecurrenceException {
  RecurrenceException.deleted({required this.localDate})
    : deleted = true,
      replacement = null;

  RecurrenceException.replaced({
    required this.localDate,
    required TimeRange this.replacement,
  }) : deleted = false;

  final DateTime localDate;
  final bool deleted;
  final TimeRange? replacement;
}

final class RecurrenceOccurrence {
  const RecurrenceOccurrence({
    required this.ruleId,
    required this.localDate,
    required this.range,
    required this.isException,
  });

  final String ruleId;
  final DateTime localDate;
  final TimeRange range;
  final bool isException;

  DateTime get startUtc => range.startUtc;
  DateTime get endUtc => range.endUtc;
  int get durationMinutes => range.durationMinutes;
}

final class RecurrenceExpander {
  const RecurrenceExpander(this._zones);

  final TimeZoneDatabase _zones;

  List<RecurrenceOccurrence> expand(
    RecurrenceRule rule,
    TimeRange window,
    List<RecurrenceException> exceptions,
  ) {
    final startLocal = _zones.toLocal(window.startUtc, rule.timeZoneId);
    final endLocal = _zones.toLocal(window.endUtc, rule.timeZoneId);
    var cursor = _dateOnly(startLocal).subtract(const Duration(days: 1));
    final firstValid = _dateOnly(rule.validFromLocalDate);
    if (cursor.isBefore(firstValid)) cursor = firstValid;
    final lastWindowDate = _dateOnly(endLocal).add(const Duration(days: 1));
    final lastValid = rule.validUntilLocalDate == null
        ? lastWindowDate
        : _dateOnly(rule.validUntilLocalDate!);
    final effectiveEnd = lastValid.isBefore(lastWindowDate)
        ? lastValid
        : lastWindowDate;

    final exceptionsByDate = <String, RecurrenceException>{
      for (final exception in exceptions)
        _dateKey(exception.localDate): exception,
    };
    final occurrences = <RecurrenceOccurrence>[];

    while (!cursor.isAfter(effectiveEnd)) {
      if (rule.weekdays.contains(cursor.weekday) &&
          _matchesIntervalWeek(rule, cursor)) {
        final exception = exceptionsByDate[_dateKey(cursor)];
        if (exception?.deleted == true) {
          cursor = cursor.add(const Duration(days: 1));
          continue;
        }

        final range = exception?.replacement ?? _regularRange(rule, cursor);
        if (range.overlaps(window)) {
          occurrences.add(
            RecurrenceOccurrence(
              ruleId: rule.id,
              localDate: cursor,
              range: range,
              isException: exception != null,
            ),
          );
        }
      }
      cursor = cursor.add(const Duration(days: 1));
    }

    occurrences.sort((a, b) => a.startUtc.compareTo(b.startUtc));
    return List.unmodifiable(occurrences);
  }

  TimeRange _regularRange(RecurrenceRule rule, DateTime localDate) {
    final startUtc = _zones.localDateTimeToUtc(
      localDate,
      rule.localStartMinute,
      rule.timeZoneId,
    );
    return TimeRange(
      startUtc: startUtc,
      endUtc: startUtc.add(Duration(minutes: rule.durationMinutes)),
    );
  }

  bool _matchesIntervalWeek(RecurrenceRule rule, DateTime candidateDate) {
    final anchorMonday = _weekMonday(rule.validFromLocalDate);
    final candidateMonday = _weekMonday(candidateDate);
    final weekOffset = candidateMonday.difference(anchorMonday).inDays ~/ 7;
    return weekOffset >= 0 && weekOffset % rule.intervalWeeks == 0;
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _weekMonday(DateTime value) {
  final date = _dateOnly(value);
  return date.subtract(Duration(days: date.weekday - DateTime.monday));
}

String _dateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
