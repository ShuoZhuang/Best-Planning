import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/recurring_pace_curve.dart';

/// 周期容量预测（1.11.0 周期预排 Task 10）。
///
/// 只使用真实硬约束窗口：固定日程、保护时间、睡眠、每日上限都先由调用方合并成
/// [busyIntervals]。本类不读取模板当前值，也不创建候选。
final class RecurringCapacityWindow {
  const RecurringCapacityWindow({
    required this.range,
    required this.minChunkMinutes,
  });

  final TimeRange range;
  final int minChunkMinutes;
}

/// 一个窗口内可用且满足最短片段约束的分钟数。
int recurringLegalCapacityMinutes({
  required TimeRange window,
  required List<TimeRange> busyIntervals,
  required int minChunkMinutes,
}) {
  if (minChunkMinutes <= 0) {
    throw ArgumentError.value(minChunkMinutes, 'minChunkMinutes');
  }
  final busy = [...busyIntervals]
    ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
  var cursor = window.startUtc;
  var total = 0;
  for (final interval in busy) {
    if (!interval.endUtc.isAfter(cursor)) continue;
    if (!interval.startUtc.isBefore(window.endUtc)) break;
    final freeEnd = interval.startUtc.isBefore(window.endUtc)
        ? interval.startUtc
        : window.endUtc;
    total += _chunkedMinutes(cursor, freeEnd, minChunkMinutes);
    if (interval.endUtc.isAfter(cursor)) cursor = interval.endUtc;
    if (!cursor.isBefore(window.endUtc)) break;
  }
  if (cursor.isBefore(window.endUtc)) {
    total += _chunkedMinutes(cursor, window.endUtc, minChunkMinutes);
  }
  return total;
}

/// 按本地日应用每日可移动上限后的合法容量。
///
/// 先按真实硬占用算每天可用分钟，再与 `maxMinutesPerDay` 取小；跨日不累计到同一天。
int recurringLegalCapacityMinutesWithDailyCap({
  required TimeRange window,
  required List<TimeRange> busyIntervals,
  required int minChunkMinutes,
  required int maxMinutesPerDay,
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) {
  if (maxMinutesPerDay <= 0) return 0;
  var total = 0;
  final localStart = zones.toLocal(window.startUtc, timeZoneId);
  var day = DateTime(localStart.year, localStart.month, localStart.day);
  while (true) {
    final dayStart = zones.localMidnightToUtc(day, timeZoneId);
    final nextDay = zones.localMidnightToUtc(
      DateTime(day.year, day.month, day.day + 1),
      timeZoneId,
    );
    if (!nextDay.isAfter(window.startUtc)) {
      day = DateTime(day.year, day.month, day.day + 1);
      continue;
    }
    if (!dayStart.isBefore(window.endUtc)) break;
    final segmentStart = dayStart.isAfter(window.startUtc)
        ? dayStart
        : window.startUtc;
    final segmentEnd = nextDay.isBefore(window.endUtc)
        ? nextDay
        : window.endUtc;
    if (segmentEnd.isAfter(segmentStart)) {
      final legal = recurringLegalCapacityMinutes(
        window: TimeRange(startUtc: segmentStart, endUtc: segmentEnd),
        busyIntervals: busyIntervals,
        minChunkMinutes: minChunkMinutes,
      );
      total += legal < maxMinutesPerDay ? legal : maxMinutesPerDay;
    }
    if (!nextDay.isBefore(window.endUtc)) break;
    day = DateTime(day.year, day.month, day.day + 1);
  }
  return total;
}

int _capacityWithOptionalDailyCap({
  required TimeRange window,
  required List<TimeRange> busyIntervals,
  required int minChunkMinutes,
  required TimeZoneDatabase? zones,
  required String? timeZoneId,
  required int? maxMinutesPerDay,
}) {
  if (zones == null || timeZoneId == null || maxMinutesPerDay == null) {
    return recurringLegalCapacityMinutes(
      window: window,
      busyIntervals: busyIntervals,
      minChunkMinutes: minChunkMinutes,
    );
  }
  return recurringLegalCapacityMinutesWithDailyCap(
    window: window,
    busyIntervals: busyIntervals,
    minChunkMinutes: minChunkMinutes,
    maxMinutesPerDay: maxMinutesPerDay,
    zones: zones,
    timeZoneId: timeZoneId,
  );
}

int _chunkedMinutes(DateTime start, DateTime end, int minChunk) {
  final minutes = end.difference(start).inMinutes;
  if (minutes < minChunk) return 0;
  // 容量只统计能落下一个最短片段的连续段；余数仍可被更短尾段使用，测试口径取整段。
  return minutes;
}

/// 基于真实容量计算本窗口应承诺的周期分钟数。
RecurringPaceDecision recurringPaceForCycle({
  required int remainingMinutes,
  required TimeRange cycleRange,
  required TimeRange visibleWindow,
  required List<TimeRange> busyIntervals,
  required int minChunkMinutes,
  required RecurringPaceCurve curve,
  TimeZoneDatabase? zones,
  String? timeZoneId,
  int? maxMinutesPerDay,
}) {
  if (!cycleRange.contains(visibleWindow.startUtc) &&
      visibleWindow.startUtc.isBefore(cycleRange.startUtc)) {
    throw ArgumentError('Visible window must start inside the cycle.');
  }
  final visibleStart = visibleWindow.startUtc.isAfter(cycleRange.startUtc)
      ? visibleWindow.startUtc
      : cycleRange.startUtc;
  final visibleEnd = visibleWindow.endUtc.isBefore(cycleRange.endUtc)
      ? visibleWindow.endUtc
      : cycleRange.endUtc;
  final beforeStart = visibleWindow.endUtc.isBefore(cycleRange.startUtc)
      ? cycleRange.startUtc
      : visibleWindow.endUtc;
  final afterEnd = beforeStart.isBefore(cycleRange.endUtc)
      ? cycleRange.endUtc
      : beforeStart;
  final visibleCapacity = visibleEnd.isAfter(visibleStart)
      ? _capacityWithOptionalDailyCap(
          window: TimeRange(startUtc: visibleStart, endUtc: visibleEnd),
          busyIntervals: busyIntervals,
          minChunkMinutes: minChunkMinutes,
          zones: zones,
          timeZoneId: timeZoneId,
          maxMinutesPerDay: maxMinutesPerDay,
        )
      : 0;
  final afterCapacity = afterEnd.isAfter(beforeStart)
      ? _capacityWithOptionalDailyCap(
          window: TimeRange(startUtc: beforeStart, endUtc: afterEnd),
          busyIntervals: busyIntervals,
          minChunkMinutes: minChunkMinutes,
          zones: zones,
          timeZoneId: timeZoneId,
          maxMinutesPerDay: maxMinutesPerDay,
        )
      : 0;
  return recurringPaceDecision(
    remainingMinutes: remainingMinutes,
    visibleCapacityMinutes: visibleCapacity,
    afterCapacityMinutes: afterCapacity,
    curve: curve,
  );
}
