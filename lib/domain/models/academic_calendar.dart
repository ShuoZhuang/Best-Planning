import 'package:personal_planner/core/ids.dart';

final class AcademicTerm {
  AcademicTerm({
    required this.id,
    required String name,
    required this.firstWeekMonday,
    required this.totalWeeks,
    required String timeZoneId,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : name = name.trim(),
       timeZoneId = timeZoneId.trim() {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
    if (this.name.isEmpty) throw ArgumentError.value(name, 'name');
    if (!_isDateOnly(firstWeekMonday) ||
        firstWeekMonday.weekday != DateTime.monday) {
      throw ArgumentError.value(
        firstWeekMonday,
        'firstWeekMonday',
        'Must be a local date on Monday.',
      );
    }
    if (totalWeeks < 1 || totalWeeks > 60) {
      throw ArgumentError.value(totalWeeks, 'totalWeeks', 'Must be 1–60.');
    }
    if (this.timeZoneId.isEmpty) {
      throw ArgumentError.value(timeZoneId, 'timeZoneId');
    }
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
  }

  final EntityId id;
  final String name;
  final DateTime firstWeekMonday;
  final int totalWeeks;
  final String timeZoneId;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

final class PeriodEntry {
  PeriodEntry({
    required this.periodNumber,
    required this.startMinute,
    required this.endMinute,
  }) {
    if (periodNumber <= 0) {
      throw ArgumentError.value(periodNumber, 'periodNumber');
    }
    if (startMinute < 0 || startMinute >= endMinute || endMinute > 24 * 60) {
      throw ArgumentError(
        'Period times must satisfy 0 <= startMinute < endMinute <= 1440.',
      );
    }
  }

  final int periodNumber;
  final int startMinute;
  final int endMinute;
}

final class PeriodTemplate {
  PeriodTemplate({
    required this.id,
    required String name,
    required this.isDefault,
    required List<PeriodEntry> entries,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : name = name.trim(),
       entries = List.unmodifiable(_validatedEntries(entries)) {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
    if (this.name.isEmpty) throw ArgumentError.value(name, 'name');
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
  }

  final EntityId id;
  final String name;
  final bool isDefault;
  final List<PeriodEntry> entries;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

final class AcademicWeekCalculator {
  const AcademicWeekCalculator._();

  static DateTime firstWeekMonday({
    required DateTime referenceDate,
    required int weekNumber,
  }) {
    if (weekNumber < 1) {
      throw ArgumentError.value(weekNumber, 'weekNumber');
    }
    return _weekMonday(referenceDate)
        .subtract(Duration(days: (weekNumber - 1) * DateTime.daysPerWeek));
  }

  static int weekNumber({
    required DateTime firstWeekMonday,
    required DateTime date,
  }) {
    final first = _dateOnly(firstWeekMonday);
    if (first.weekday != DateTime.monday) {
      throw ArgumentError.value(
        firstWeekMonday,
        'firstWeekMonday',
        'Must be Monday.',
      );
    }
    final currentMonday = _weekMonday(date);
    if (currentMonday.isBefore(first)) {
      throw ArgumentError.value(date, 'date', 'Date precedes academic week 1.');
    }
    return currentMonday.difference(first).inDays ~/ DateTime.daysPerWeek + 1;
  }
}

List<PeriodEntry> _validatedEntries(List<PeriodEntry> source) {
  final entries = [...source]
    ..sort((a, b) => a.periodNumber.compareTo(b.periodNumber));
  final seen = <int>{};
  PeriodEntry? previous;
  for (final entry in entries) {
    if (!seen.add(entry.periodNumber)) {
      throw ArgumentError.value(
        entry.periodNumber,
        'entries',
        'Period numbers must be unique.',
      );
    }
    if (previous != null && entry.startMinute < previous.endMinute) {
      throw ArgumentError.value(
        entry.periodNumber,
        'entries',
        'Periods must not overlap in period-number order.',
      );
    }
    previous = entry;
  }
  return entries;
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _weekMonday(DateTime value) {
  final date = _dateOnly(value);
  return date.subtract(Duration(days: date.weekday - DateTime.monday));
}

bool _isDateOnly(DateTime value) =>
    value.hour == 0 &&
    value.minute == 0 &&
    value.second == 0 &&
    value.millisecond == 0 &&
    value.microsecond == 0;

void _requireUtc(DateTime value, String name) {
  if (!value.isUtc) throw ArgumentError.value(value, name, 'Must be UTC.');
}
