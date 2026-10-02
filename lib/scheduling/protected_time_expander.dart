import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 把按"本地墙上时间 + `DayKind`"描述的保护时间展开为规划窗口内的 UTC 忙碌区间。
///
/// 引擎只接受具体区间（`ScheduleProblem.protectedIntervals`），所以"午餐
/// 12:00–13:00、仅工作日"这类规则必须在进入引擎前逐日落到真实时刻上。
/// 此前没有任何生产代码做这件事，保护时间在真实运行时恒为空集，睡眠、用餐与
/// 固定休息实际上从未参与排程。
///
/// 展开使用本地墙上时间到 UTC 的转换（`localDateTimeToUtc`），因此夏令时切换
/// 当天的保护时间仍按用户看到的钟点生效。
final class ProtectedTimeExpander {
  const ProtectedTimeExpander(this._zones);

  final TimeZoneDatabase _zones;

  List<BusyInterval> expand({
    required PlanningRules rules,
    required DateTime startUtc,
    required DateTime endUtc,
    required String timeZoneId,
  }) {
    if (!startUtc.isUtc || !endUtc.isUtc) {
      throw ArgumentError('Planning window must use UTC instants.');
    }
    if (!endUtc.isAfter(startUtc)) {
      throw ArgumentError('Planning window must have positive duration.');
    }

    final intervals = <BusyInterval>[];
    var localDate = _dateOnly(_zones.toLocal(startUtc, timeZoneId));
    final lastDate = _dateOnly(
      _zones.toLocal(
        endUtc.subtract(const Duration(microseconds: 1)),
        timeZoneId,
      ),
    );

    while (!localDate.isAfter(lastDate)) {
      final dayKind = _dayKindOf(localDate.weekday);
      for (final rule in rules.protectedTimes) {
        if (!rule.enabled) continue;
        if (rule.dayKind != DayKind.any && rule.dayKind != dayKind) continue;

        final start = _zones.localDateTimeToUtc(
          localDate,
          rule.range.startMinute,
          timeZoneId,
        );
        final end = _zones.localDateTimeToUtc(
          rule.range.crossesMidnight
              ? localDate.add(const Duration(days: 1))
              : localDate,
          rule.range.endMinute,
          timeZoneId,
        );
        if (!end.isAfter(start)) continue;

        final clippedStart = start.isBefore(startUtc) ? startUtc : start;
        final clippedEnd = end.isAfter(endUtc) ? endUtc : end;
        if (!clippedEnd.isAfter(clippedStart)) continue;

        intervals.add(
          BusyInterval(
            id:
                'protected:${rule.kind.name}:${_dateKey(localDate)}:'
                '${rule.range.startMinute}',
            range: TimeRange(startUtc: clippedStart, endUtc: clippedEnd),
          ),
        );
      }
      localDate = localDate.add(const Duration(days: 1));
    }

    return List.unmodifiable(intervals);
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DayKind _dayKindOf(int weekday) =>
    weekday == DateTime.saturday || weekday == DateTime.sunday
    ? DayKind.weekend
    : DayKind.weekday;
