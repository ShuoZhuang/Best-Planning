import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

/// 一条安排**在某一个本地日里**的那一段，以及它的本地分钟区间。
///
/// 位置与文字必须共用同一个 [startMinute] / [endMinute]——设计规范 §4.1 的"单一时间
/// 表示"。此前卡片的位置用本地分钟算，文字却把本地分钟再经过一次时区换算，于是
/// Asia/Shanghai 下文字偏 8 小时（§2.1）。
final class PlannedDayEntry {
  const PlannedDayEntry({
    required this.item,
    required this.startMinute,
    required this.endMinute,
  });

  final ScheduleViewItem item;
  final int startMinute;
  final int endMinute;

  /// 卡片文字、悬浮提示与无障碍语义共用的标签。
  String get label =>
      '${formatLocalMinute(startMinute)}–${formatLocalMinute(endMinute)}';
}

/// 时间轴里的一列（某一个本地日）。
final class TimelineDayPlan {
  const TimelineDayPlan({
    required this.index,
    required this.localDate,
    required this.dayStartUtc,
    required this.dayEndUtc,
    required this.entries,
  });

  /// 相对 [weeklyTimelinePlan] 传入的周起点：`-1` 是前一天，`0` 是第一天。
  final int index;

  /// 这一列代表的**本地日期**（只有年月日有意义）。
  ///
  /// 刻意不是"UTC 起点加一天"：`DateTime.add(Duration(days: 1))` 是加**经过时长**，
  /// 而在夏令时切换日，本地一天不是 24 小时——Berlin 的 2026-03-29 只有 23 小时。
  /// 列的日期必须由本地日历推出来（规范 §4.1 最后一条）。
  final DateTime localDate;

  final DateTime dayStartUtc;
  final DateTime dayEndUtc;

  /// 落在这一列里的条目，已按这一天裁剪，且各自的本地分钟区间已算好。
  final List<PlannedDayEntry> entries;
}

/// 整个时间轴的布局计划：每一列 + 全体条目决定的可见时间范围。
final class WeeklyTimelinePlan {
  const WeeklyTimelinePlan({required this.days, required this.ranges});

  final List<TimelineDayPlan> days;

  /// 所有列的最早开始与最晚结束，交给 [timelineWindowFor]。
  ///
  /// **用全局范围而不是每列各自的范围**：各列范围不同的话，同一钟点在相邻两列会落在
  /// 不同高度，时间轴就失去了"横向可比"的意义——而那正是它存在的理由。
  final List<({int start, int end})> ranges;
}

/// 把 `[startUtc, endUtc)` 落在**某一个本地日**里的那一段换算成本地分钟区间。
///
/// [startUtc] / [endUtc] 必须已经按这一天裁剪过（见 [weeklyTimelinePlan]）。
/// [toLocal] 生产环境传入应用选定时区的换算函数。
///
/// 两个边界约定：
///
/// - **终点落在次日本地 00:00 时返回 1440，而不是 0**。这不是回绕，而是"画到列底"：
///   一个 23:30–次日 00:30 的块，在第一列里的终点就是当天 24:00。返回 0 会让卡片
///   高度变成负数或零（设计规范 §4.1：单列范围不得超过 0～1440）。
/// - 起点落在本地 00:00 的**次日**（只有未裁剪的输入才会发生）钳到 1440，
///   同样是为了让"没有可用区间"表现为零高度而不是画到整列。
({int start, int end}) localMinuteRangeInDay(
  DateTime startUtc,
  DateTime endUtc,
  DateTime Function(DateTime instantUtc) toLocal, {
  required DateTime dayStartUtc,
}) {
  final localStart = toLocal(startUtc);
  final localEnd = toLocal(endUtc);

  var start = localStart.hour * 60 + localStart.minute;
  var end = localEnd.hour * 60 + localEnd.minute;

  // 起点落在次日：这一天已经被裁掉了，起点钳到列底（得到零高度）。
  if (_localDateOf(localStart).isAfter(_localDateOf(toLocal(dayStartUtc)))) {
    start = LocalTimeRange.minutesPerDay;
  }
  // 终点落在**比起点更晚的本地日**（通常是次日 00:00，也可能跨了两天）：
  // 这一段一直画到列底。`end <= start` 只在终点确实落在次日或更晚时才这样解释。
  final endLocalDate = _localDateOf(localEnd);
  if (endLocalDate.isAfter(_localDateOf(localStart)) && end <= start) {
    end = LocalTimeRange.minutesPerDay;
  }

  final clampedStart = start.clamp(0, LocalTimeRange.minutesPerDay);
  // 零长度在几何上等价于"没有内容"；保留成一个退化的区间而不是反过来制造负高度。
  final clampedEnd = end.clamp(clampedStart, LocalTimeRange.minutesPerDay);
  return (start: clampedStart, end: clampedEnd);
}

/// 把"本地日内分钟"格式化成 `HH:mm`。
///
/// - 0 → `00:00`；
/// - 1440 **只作为区间终点**显示 `24:00`——不能回绕成 `00:00`，那会把"跨到次日"
///   显示成"当天零点"，丢掉跨日含义（计划 Task 2 Step 4）。
///
/// 时间轴、卡片文字、悬浮提示与无障碍语义**共用**这一个函数，因此四处的文字不可能
/// 各自算出不同的值。
String formatLocalMinute(int minute) {
  if (minute == LocalTimeRange.minutesPerDay) return '24:00';
  final clamped = minute.clamp(0, LocalTimeRange.minutesPerDay);
  final hour = clamped ~/ 60;
  final rest = clamped % 60;
  return '${hour.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
}

/// 一次算出整个时间轴的分列与分钟区间。
///
/// **这是 UTC → 本地时区的唯一转换边界**（设计规范 §4.1："UTC → 本地时区只在
/// `ScheduleViewSource` 或时间轴入口转换一次"）。几何、卡片文字、悬浮提示与无障碍语义
/// （[PlannedDayEntry.label]）全部由这里产出的值派生，因此不存在第二次换算。
///
/// [days] 是每列的本地日期，`0` 对应周起点的本地日期。日期由调用方按**本地日历**推出，
/// 而不是 `weekStartUtc.add(Duration(days: n))`——后者在夏令时切换周会漂。
WeeklyTimelinePlan weeklyTimelinePlan({
  required Iterable<ScheduleViewItem> items,
  required List<DateTime> days,
  required DateTime Function(DateTime instantUtc) toLocal,
}) {
  final dayPlans = <TimelineDayPlan>[];

  for (var index = 0; index < days.length; index++) {
    final localDate = days[index];
    final dayStartUtc = localMidnightUtc(
      localDate: localDate,
      toLocal: toLocal,
    );
    final nextLocalDate = DateTime(
      localDate.year,
      localDate.month,
      localDate.day + 1,
    );
    final dayEndUtc = localMidnightUtc(
      localDate: nextLocalDate,
      toLocal: toLocal,
    );
    final range = TimeRange(startUtc: dayStartUtc, endUtc: dayEndUtc);

    final entries = <PlannedDayEntry>[];
    for (final item in items) {
      if (!item.range.overlaps(range)) continue;
      // 先把区间裁到这一天，再换算：不裁剪的话 23:30–次日 00:30 的块会在两列里
      // 都被算成"从 23:30 到列底"，第二列于是凭空多出一条 23:30–24:00。
      final clippedStart = _maxUtc(item.range.startUtc, dayStartUtc);
      final clippedEnd = _minUtc(item.range.endUtc, dayEndUtc);
      final minutes = localMinuteRangeInDay(
        clippedStart,
        clippedEnd,
        toLocal,
        dayStartUtc: dayStartUtc,
      );
      entries.add(
        PlannedDayEntry(
          item: item,
          startMinute: minutes.start,
          endMinute: minutes.end,
        ),
      );
    }
    dayPlans.add(
      TimelineDayPlan(
        index: index - 1,
        localDate: localDate,
        dayStartUtc: dayStartUtc,
        dayEndUtc: dayEndUtc,
        entries: entries,
      ),
    );
  }

  return WeeklyTimelinePlan(
    days: dayPlans,
    ranges: [
      for (final day in dayPlans)
        for (final entry in day.entries)
          (start: entry.startMinute, end: entry.endMinute),
    ],
  );
}

DateTime _localDateOf(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 求出某个**本地日期**（可带本地钟点）对应的 UTC 时刻。
///
/// 页面只从装配层收到**一个**方向的换算函数（**UTC → 本地**），因为
/// `TimeZoneDatabase.localDateTimeToUtc` 需要时区 id，而页面按设计不认识时区 id
/// （`today_page.dart` / `day_view_page.dart` 同样只收 `toLocal`）。本地日列的边界
/// 又必须落在**本地午夜**上——夏令时切换日的本地一天不是 24 小时，用
/// `weekStart + 1 天` 会漂到 01:00 或 23:00。
///
/// 反解办法：`toLocal` 给回的是 `tz.TZDateTime`，它自带的 `timeZoneOffset` 就是那一刻的
/// 真实偏移。用"该本地墙上时间 - 偏移"得到 UTC 候选，再用候选重新换算一次以确认偏移
/// （跨越切换点时候选会落到另一侧，那时偏移会变，需要再迭代一次）。两次迭代足以收敛：
/// 一次修正就能从"按旧偏移猜的候选"落到正确的一侧。
///
/// **墙上时间必须构造成 `DateTime.utc`，不能是 `DateTime`**：裸 `DateTime(...)` 带的是
/// **主机**时区，对它调 `toUtc()` 会先减掉主机偏移，于是"本地午夜"变成主机时区解释下的
/// 午夜再减一次——本机（Asia/Shanghai）实测差了整整 8 小时，而那时区恰是规范要求测的
/// 第一个场景。用它承载墙上时间等于把主机时区偷偷掺进结果。
DateTime localWallClockToUtc({
  required DateTime localDate,
  int minuteOfDay = 0,
  required DateTime Function(DateTime instantUtc) toLocal,
}) {
  final wallClock = DateTime.utc(
    localDate.year,
    localDate.month,
    localDate.day,
    minuteOfDay ~/ 60,
    minuteOfDay % 60,
  );
  var candidate = wallClock;
  for (var attempt = 0; attempt < 3; attempt++) {
    final rendered = toLocal(candidate);
    final corrected = wallClock.subtract(rendered.timeZoneOffset);
    if (corrected == candidate) break;
    candidate = corrected;
  }
  return candidate;
}

/// 求出某个**本地日期**的本地 00:00 对应的 UTC 时刻。
DateTime localMidnightUtc({
  required DateTime localDate,
  required DateTime Function(DateTime instantUtc) toLocal,
}) => localWallClockToUtc(localDate: localDate, toLocal: toLocal);

DateTime _maxUtc(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

DateTime _minUtc(DateTime a, DateTime b) => a.isBefore(b) ? a : b;
