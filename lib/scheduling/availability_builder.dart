import 'dart:collection';

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';

final class AvailabilityInput {
  AvailabilityInput({
    required this.planningWindow,
    required this.timeZoneId,
    required this.rules,
    List<TimeRange> fixedIntervals = const [],
    List<TimeRange> protectedIntervals = const [],
    List<TimeRange> lockedBlocks = const [],
  }) : fixedIntervals = UnmodifiableListView(fixedIntervals),
       protectedIntervals = UnmodifiableListView(protectedIntervals),
       lockedBlocks = UnmodifiableListView(lockedBlocks);

  final TimeRange planningWindow;
  final String timeZoneId;
  final PlanningRules rules;
  final List<TimeRange> fixedIntervals;
  final List<TimeRange> protectedIntervals;
  final List<TimeRange> lockedBlocks;
}

final class AvailabilitySlot {
  const AvailabilitySlot({required this.range, required this.localDate});

  final TimeRange range;
  final DateTime localDate;

  DateTime get startUtc => range.startUtc;
  DateTime get endUtc => range.endUtc;
  int get durationMinutes => range.durationMinutes;
}

final class AvailabilityBuilder {
  const AvailabilityBuilder(this._zones);

  final TimeZoneDatabase _zones;

  List<AvailabilitySlot> build(AvailabilityInput input) {
    final busy = _merge(
      [
            ...input.fixedIntervals,
            ...input.protectedIntervals,
            ...input.lockedBlocks,
            ..._sleepIntervals(input),
          ]
          .map((range) => _intersection(range, input.planningWindow))
          .nonNulls
          .toList(),
    );

    final output = <AvailabilitySlot>[];
    var localDate = _dateOnly(
      _zones.toLocal(input.planningWindow.startUtc, input.timeZoneId),
    );
    final lastLocalDate = _dateOnly(
      _zones.toLocal(
        input.planningWindow.endUtc.subtract(const Duration(microseconds: 1)),
        input.timeZoneId,
      ),
    );

    while (!localDate.isAfter(lastLocalDate)) {
      final dayStart = _zones.localMidnightToUtc(localDate, input.timeZoneId);
      final nextDate = localDate.add(const Duration(days: 1));
      final dayEnd = _zones.localMidnightToUtc(nextDate, input.timeZoneId);
      final dayWindow = _intersection(
        TimeRange(startUtc: dayStart, endUtc: dayEnd),
        input.planningWindow,
      );
      if (dayWindow != null) {
        final dayBusy = busy
            .map((range) => _intersection(range, dayWindow))
            .nonNulls
            .toList();
        final free = _complement(dayWindow, dayBusy);
        var remaining = input.rules.dailyMovableTaskLimitMinutes;
        for (final range in free) {
          if (remaining <= 0) break;
          final alignedMinutes =
              (range.durationMinutes ~/ input.rules.granularityMinutes) *
              input.rules.granularityMinutes;
          final usedMinutes = alignedMinutes < remaining
              ? alignedMinutes
              : remaining;
          if (usedMinutes <= 0) continue;
          output.add(
            AvailabilitySlot(
              localDate: localDate,
              range: TimeRange(
                startUtc: range.startUtc,
                endUtc: range.startUtc.add(Duration(minutes: usedMinutes)),
              ),
            ),
          );
          remaining -= usedMinutes;
        }
      }
      localDate = nextDate;
    }

    return List.unmodifiable(output);
  }

  List<TimeRange> _sleepIntervals(AvailabilityInput input) {
    final result = <TimeRange>[];
    var date = _dateOnly(
      _zones
          .toLocal(input.planningWindow.startUtc, input.timeZoneId)
          .subtract(const Duration(days: 1)),
    );
    final end = _dateOnly(
      _zones
          .toLocal(input.planningWindow.endUtc, input.timeZoneId)
          .add(const Duration(days: 1)),
    );

    while (!date.isAfter(end)) {
      for (final segment in input.rules.sleepRange.splitAtMidnight()) {
        final segmentDate = date.add(Duration(days: segment.dayOffset));
        result.add(
          TimeRange(
            startUtc: _utcBoundary(
              segmentDate,
              segment.startMinute,
              input.timeZoneId,
            ),
            endUtc: _utcBoundary(
              segmentDate,
              segment.endMinute,
              input.timeZoneId,
            ),
          ),
        );
      }
      date = date.add(const Duration(days: 1));
    }
    return result;
  }

  DateTime _utcBoundary(DateTime date, int minute, String zoneId) {
    if (minute == LocalTimeRange.minutesPerDay) {
      return _zones.localMidnightToUtc(
        date.add(const Duration(days: 1)),
        zoneId,
      );
    }
    return _zones.localDateTimeToUtc(date, minute, zoneId);
  }
}

List<TimeRange> _merge(List<TimeRange> ranges) {
  if (ranges.isEmpty) return const [];
  ranges.sort((a, b) => a.startUtc.compareTo(b.startUtc));
  final merged = <TimeRange>[];
  var current = ranges.first;
  for (final next in ranges.skip(1)) {
    if (!next.startUtc.isAfter(current.endUtc)) {
      current = TimeRange(
        startUtc: current.startUtc,
        endUtc: next.endUtc.isAfter(current.endUtc)
            ? next.endUtc
            : current.endUtc,
      );
    } else {
      merged.add(current);
      current = next;
    }
  }
  merged.add(current);
  return merged;
}

List<TimeRange> _complement(TimeRange window, List<TimeRange> busy) {
  final output = <TimeRange>[];
  var cursor = window.startUtc;
  for (final interval in _merge(busy)) {
    if (interval.startUtc.isAfter(cursor)) {
      output.add(TimeRange(startUtc: cursor, endUtc: interval.startUtc));
    }
    if (interval.endUtc.isAfter(cursor)) cursor = interval.endUtc;
  }
  if (cursor.isBefore(window.endUtc)) {
    output.add(TimeRange(startUtc: cursor, endUtc: window.endUtc));
  }
  return output;
}

TimeRange? _intersection(TimeRange a, TimeRange b) {
  final start = a.startUtc.isAfter(b.startUtc) ? a.startUtc : b.startUtc;
  final end = a.endUtc.isBefore(b.endUtc) ? a.endUtc : b.endUtc;
  return end.isAfter(start) ? TimeRange(startUtc: start, endUtc: end) : null;
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
