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
    List<TimeRange> chargedMovableBlocks = const [],
  }) : fixedIntervals = UnmodifiableListView(fixedIntervals),
       protectedIntervals = UnmodifiableListView(protectedIntervals),
       lockedBlocks = UnmodifiableListView(lockedBlocks),
       chargedMovableBlocks = UnmodifiableListView(chargedMovableBlocks);

  final TimeRange planningWindow;
  final String timeZoneId;
  final PlanningRules rules;
  final List<TimeRange> fixedIntervals;
  final List<TimeRange> protectedIntervals;
  final List<TimeRange> lockedBlocks;

  /// 已经占住时间、**但落地为未锁定**的块（FR-CAL-05 里"拖动了但没锁定"的那一支）。
  ///
  /// 它们与 `lockedBlocks` 一样从可用时间里扣除（因此候选不会压上去），但**必须计入当日
  /// 可移动任务预算**：`PlanValidator` 是按"未锁定块"统计每日上限的，若这里不扣，同一段时长
  /// 在两侧算法不同，会凭空产生 `dailyLimitExceeded`，把一次合法的手动移动判为无效提案。
  final List<TimeRange> chargedMovableBlocks;
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
    // 已占住时间、但落地为未锁定的块先记到它们**起点所在**的本地日上，与
    // `PlanValidator` 的统计口径逐字一致（同样取起点本地日、同样算整段时长）。
    final chargedByLocalDate = <String, int>{};
    for (final range in input.chargedMovableBlocks) {
      final localDate = _dateOnly(
        _zones.toLocal(range.startUtc, input.timeZoneId),
      );
      chargedByLocalDate.update(
        _dateKey(localDate),
        (value) => value + range.durationMinutes,
        ifAbsent: () => range.durationMinutes,
      );
    }
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
        var remaining =
            input.rules.dailyMovableTaskLimitMinutes -
            (chargedByLocalDate[_dateKey(localDate)] ?? 0);
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

/// 与 `PlanValidator` 的每日上限统计用的键保持同一形状。
String _dateKey(DateTime localDate) =>
    '${localDate.year}-${localDate.month}-${localDate.day}';
