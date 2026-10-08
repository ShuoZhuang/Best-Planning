import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:timezone/timezone.dart' as tz;

/// 一个"周期目标的周"（路线图 §3.3 与 Global Constraints）。
///
/// 周界统一为**本地时间周一 00:00 到下一周周一 00:00**：[startUtc, endUtc) 是半开区间，
/// 与 `TimeRange` 的口径一致（终点不属于本周，避免相邻两周重叠一小时或漏掉一小时）。
///
/// 为什么同时留 `startLocalDate` 与 `startUtc`：前者是**周期实例的主键**
/// （`YYYY-MM-DD` 的本地周一），后者是**排程窗口与分钟归集的边界**。两者不能互相推导
/// ——推导需要时区，而时区恰恰是会变的那一项。把两个都存下来，调用方就不必各自再算一遍。
final class WeeklyPeriod {
  WeeklyPeriod({
    required DateTime startLocalDate,
    required DateTime endLocalDate,
    required this.startUtc,
    required this.endUtc,
    required this.timeZoneId,
  }) : startLocalDate = localDateOnly(startLocalDate),
       endLocalDate = localDateOnly(endLocalDate) {
    if (this.startLocalDate.weekday != DateTime.monday) {
      throw ArgumentError.value(
        startLocalDate,
        'startLocalDate',
        'A weekly period must start on a local Monday.',
      );
    }
    if (!this.endLocalDate.isAfter(this.startLocalDate)) {
      throw ArgumentError.value(endLocalDate, 'endLocalDate');
    }
    if (!startUtc.isUtc || !endUtc.isUtc) {
      throw ArgumentError('WeeklyPeriod requires UTC instants.');
    }
    if (!endUtc.isAfter(startUtc)) {
      throw ArgumentError('WeeklyPeriod must have positive duration.');
    }
  }

  /// 本周的本地周一（周期实例的主键）。
  final DateTime startLocalDate;

  /// 下一周的本地周一（不含）。
  final DateTime endLocalDate;

  final DateTime startUtc;
  final DateTime endUtc;
  final String timeZoneId;

  TimeRange get range => TimeRange(startUtc: startUtc, endUtc: endUtc);

  /// 实际时长（小时）。
  ///
  /// **不等于 168**：`[startUtc, endUtc)` 是两个"本地 00:00"之间的绝对时间，夏令时切换
  /// 的那一周会是 167 或 169 小时。把它暴露出来是为了让"周界按本地日历推进"这件事
  /// 可被断言——按 `Duration(days: 7)` 构造的周永远恰好 168 小时，那样反倒说明它错了。
  int get durationHours => endUtc.difference(startUtc).inHours;

  /// 起点在本地时区里的墙上时间（总是周一 00:00）。
  tz.TZDateTime localStart(TimeZoneDatabase zones) =>
      zones.toLocal(startUtc, timeZoneId);

  bool contains(DateTime instantUtc) => range.contains(instantUtc);

  /// 从 [nowUtc] 所在的本地时刻出发，算出它属于哪一周。
  ///
  /// **周一必须用日历算术得到，不能用 `add(Duration(days: 7))`**：本仓库在
  /// `scheduling/protected_time_expander.dart` 里已经记录过一次真实事故——本地
  /// `DateTime.add` 是绝对时间加法，夏令时回拨日的"加一天"会回到同一天的 23:00，
  /// 日期不变。周界错一天会让"这一周的进度"落到相邻周，而周期实例的唯一键正是那一天。
  static WeeklyPeriod forInstant(
    DateTime nowUtc,
    String timeZoneId,
    TimeZoneDatabase zones,
  ) {
    if (!nowUtc.isUtc) {
      throw ArgumentError.value(nowUtc, 'nowUtc', 'Must be UTC.');
    }
    final local = zones.toLocal(nowUtc, timeZoneId);
    final startLocalDate = shiftLocalDate(
      localDateOnly(local),
      -(local.weekday - DateTime.monday),
    );
    final endLocalDate = shiftLocalDate(startLocalDate, 7);
    return WeeklyPeriod(
      startLocalDate: startLocalDate,
      endLocalDate: endLocalDate,
      startUtc: zones.localMidnightToUtc(startLocalDate, timeZoneId),
      endUtc: zones.localMidnightToUtc(endLocalDate, timeZoneId),
      timeZoneId: timeZoneId,
    );
  }

  /// 以 [startLocalDate]（必须是本地周一）为起点构造同一形状的周。
  static WeeklyPeriod startingAt(
    DateTime startLocalDate,
    String timeZoneId,
    TimeZoneDatabase zones,
  ) => WeeklyPeriod(
    startLocalDate: startLocalDate,
    endLocalDate: shiftLocalDate(startLocalDate, 7),
    startUtc: zones.localMidnightToUtc(startLocalDate, timeZoneId),
    endUtc: zones.localMidnightToUtc(
      shiftLocalDate(startLocalDate, 7),
      timeZoneId,
    ),
    timeZoneId: timeZoneId,
  );

  /// 前一周。
  WeeklyPeriod previous(TimeZoneDatabase zones) =>
      startingAt(shiftLocalDate(startLocalDate, -7), timeZoneId, zones);

  /// 后一周。
  WeeklyPeriod next(TimeZoneDatabase zones) =>
      startingAt(shiftLocalDate(startLocalDate, 7), timeZoneId, zones);

  @override
  String toString() =>
      'WeeklyPeriod(${formatLocalDate(startLocalDate)} → '
      '${formatLocalDate(endLocalDate)}, $timeZoneId)';
}

/// `weeklyPeriodFor(nowUtc, timeZoneId)`：见 [WeeklyPeriod.forInstant]。
///
/// 单独抽一个顶层函数而不是只留静态方法，是因为路线图 §11 Task 6 的接口写的就是这个
/// 形状，而领域层不应为了"少一层"让调用方自己去 new 一个时区库。
WeeklyPeriod weeklyPeriodFor(
  DateTime nowUtc,
  String timeZoneId, {
  TimeZoneDatabase? zones,
}) => WeeklyPeriod.forInstant(nowUtc, timeZoneId, zones ?? TimeZoneDatabase());
