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
        // 终点落在次日有两种情形：真正跨越午夜的区间（22:00–02:00），以及终点为
        // 24:00 的区间（09:00–24:00）。后者不跨午夜但 `endMinute` 是 1440，而
        // `localDateTimeToUtc` 只接受 [0, 1439]，直接传会抛参数错误，因此必须改用
        // 次日本地零点(`localMidnightToUtc`)。
        final endsAtMidnight =
            rule.range.endMinute == LocalTimeRange.minutesPerDay;
        final endDate = rule.range.crossesMidnight || endsAtMidnight
            ? _shiftDate(localDate, 1)
            : localDate;
        final end = endsAtMidnight
            ? _zones.localMidnightToUtc(endDate, timeZoneId)
            : _zones.localDateTimeToUtc(
                endDate,
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
            // **类别是数据，不是 id 的一部分**（计划 §2.5）：id 里仍然带着它，
            // 但下游不许再靠解析 id 得到它——此前正是那次解析漏了 breakfast。
            protectedKind: rule.kind,
          ),
        );
      }
      localDate = _shiftDate(localDate, 1);
    }

    return List.unmodifiable(intervals);
  }

  /// 把 [PlanningRules.sleepRange] 展开成窗口内的 UTC 区间
  /// （用户第 65 轮复核第 3 条：睡眠也是硬占用）。
  ///
  /// **为什么单独一个方法而不是塞进 [expand]**：睡眠是**跨午夜**的单个区间
  /// （`22:00–06:00`），语义上不属于"按 `DayKind` 生效的保护时间规则"，
  /// 因此不参与 `rule.dayKind` 过滤；它的展开还必须**向前后各多覆盖一天**，
  /// 否则窗口起点正好落在本地 00:00 时，"当天 00:00–06:00"属于**前一夜**的睡眠
  /// 会被整段漏掉（本地 00:00 起算的那一天，其睡眠从**前一天** 22:00 开始）。
  ///
  /// **它是睡眠展开的唯一实现**：`AvailabilityBuilder` 曾经自带一份同样的逻辑
  /// （`_sleepIntervals`）。两份口径迟早会漂 —— 现在两边都调用这里，
  /// 于是"容量认为睡眠不可用"与"校验认为压上去是冲突"永远一致。
  List<BusyInterval> sleep({
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
    // 前后各多一天：见上面关于"窗口起点落在本地 00:00"的说明。
    var localDate = _shiftDate(
      _dateOnly(_zones.toLocal(startUtc, timeZoneId)),
      -1,
    );
    final lastDate = _shiftDate(
      _dateOnly(_zones.toLocal(endUtc, timeZoneId)),
      1,
    );

    while (!localDate.isAfter(lastDate)) {
      // 跨午夜的区间拆成"当天那段"与"次日那段"，`dayOffset` 指明落在哪一天。
      for (final segment in rules.sleepRange.splitAtMidnight()) {
        final segmentDate = _shiftDate(localDate, segment.dayOffset);
        final start = _localMinuteToUtc(
          segmentDate,
          segment.startMinute,
          timeZoneId,
        );
        final end = _localMinuteToUtc(
          segmentDate,
          segment.endMinute,
          timeZoneId,
        );
        if (!end.isAfter(start)) continue;

        final clippedStart = start.isBefore(startUtc) ? startUtc : start;
        final clippedEnd = end.isAfter(endUtc) ? endUtc : end;
        if (!clippedEnd.isAfter(clippedStart)) continue;

        intervals.add(
          BusyInterval(
            id:
                'sleep:${_dateKey(localDate)}:'
                '${segment.startMinute}:${segment.dayOffset}',
            range: TimeRange(startUtc: clippedStart, endUtc: clippedEnd),
          ),
        );
      }
      localDate = _shiftDate(localDate, 1);
    }

    // **合并相邻/重叠片段**：`splitAtMidnight` 会把 `22:00–06:00` 拆成
    // "当天 22:00–24:00" 与 "次日 00:00–06:00" 两段。它们是**同一段睡眠**，
    // 因此这里顺手合并，返回的每个区间就是用户概念里的一整夜。
    //
    // 此前 `AvailabilityBuilder` 自带的那份实现没有合并，是**下游**统一做的
    // （`build` 把所有忙碌区间交给 `_merge`）。现在本方法自己给出合并结果，
    // 于是直接调用它的地方（例如装配层的硬占用集合）也不会看到半截的睡眠。
    final merged = <BusyInterval>[];
    intervals.sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
    for (final interval in intervals) {
      final last = merged.isEmpty ? null : merged.last;
      if (last != null && !interval.range.startUtc.isAfter(last.range.endUtc)) {
        merged[merged.length - 1] = BusyInterval(
          id: last.id,
          range: TimeRange(
            startUtc: last.range.startUtc,
            endUtc: interval.range.endUtc.isAfter(last.range.endUtc)
                ? interval.range.endUtc
                : last.range.endUtc,
          ),
          // 合并后仍然**不是**一条带类别的保护时间规则：睡眠没有类别，
          // 这里原样把 `last` 的值带过去（而不是写死 null），免得将来合并
          // 别的来源时悄悄丢字段。
          protectedKind: last.protectedKind,
        );
      } else {
        merged.add(interval);
      }
    }

    return List.unmodifiable(merged);
  }

  /// 本地"某天第 [minute] 分钟"换算为 UTC。
  ///
  /// **`minute == 1440` 必须单独处理**：它表示"当天 24:00"，也就是**次日零点**。
  /// `localDateTimeToUtc` 只接受 `[0, 1439]`，直接传 1440 会抛
  /// `Invalid argument (minuteOfDay): 1440`。
  ///
  /// 这个特例原先只存在于 `AvailabilityBuilder._utcBoundary` 里；我把睡眠展开统一到
  /// 本文件时漏了它，四条用例当场红（`sleep_occupancy_test.dart` 两条 +
  /// `availability_builder_test.dart` 两条）—— 因为 `DefaultSettings.v1().sleepRange`
  /// 的终点正好是 1440。
  DateTime _localMinuteToUtc(DateTime date, int minute, String zoneId) {
    if (minute == LocalTimeRange.minutesPerDay) {
      // 用 `(y, m, d + 1)` 而不是 `add(Duration(days: 1))`：本地 `add` 是绝对时间加法，
      // 夏令时回拨日会落回同一天的 23:00。见 [_shiftDate]。
      return _zones.localMidnightToUtc(_shiftDate(date, 1), zoneId);
    }
    return _zones.localDateTimeToUtc(date, minute, zoneId);
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 按日历日位移，而不是 `DateTime.add(const Duration(days: 1))`。
///
/// 本地 `DateTime` 的 `add` 是**绝对时间**加法：在夏令时回拨日，本地零点加 24 小时
/// 会回到同一天的 23:00，日期不变，于是逐日展开会漏掉一天或多算一天。按
/// `(year, month, day + n)` 构造才是真正的"下一个日历日"。
DateTime _shiftDate(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

String _dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DayKind _dayKindOf(int weekday) =>
    weekday == DateTime.saturday || weekday == DateTime.sunday
    ? DayKind.weekend
    : DayKind.weekday;
