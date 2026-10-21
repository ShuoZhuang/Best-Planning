import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

final class TimeZoneDatabase {
  TimeZoneDatabase() {
    if (!_initialized) {
      tz_data.initializeTimeZones();
      _initialized = true;
    }
  }

  static bool _initialized = false;

  tz.Location location(String timeZoneId) {
    if (timeZoneId == 'UTC' || timeZoneId == 'Etc/UTC') return tz.UTC;
    try {
      return tz.getLocation(timeZoneId);
    } on tz.LocationNotFoundException {
      throw ArgumentError.value(timeZoneId, 'timeZoneId', 'Unknown IANA zone.');
    }
  }

  tz.TZDateTime toLocal(DateTime instantUtc, String timeZoneId) {
    if (!instantUtc.isUtc) {
      throw ArgumentError.value(instantUtc, 'instantUtc', 'Must be UTC.');
    }
    return tz.TZDateTime.from(instantUtc, location(timeZoneId));
  }

  DateTime localDateTimeToUtc(
    DateTime localDate,
    int minuteOfDay,
    String timeZoneId,
  ) {
    if (minuteOfDay < 0 || minuteOfDay >= 24 * 60) {
      throw ArgumentError.value(minuteOfDay, 'minuteOfDay');
    }
    final local = tz.TZDateTime(
      location(timeZoneId),
      localDate.year,
      localDate.month,
      localDate.day,
      minuteOfDay ~/ 60,
      minuteOfDay % 60,
    );
    return _asPlainUtc(local.toUtc());
  }

  /// 把一个**本地墙上时间**解析成 UTC 时刻，并冻结 DST 缺失/重复时刻的策略
  /// （计划 Task 4 Step 2）。
  ///
  /// - **缺失**（春季前跳，例如纽约 2026-03-08 02:30 不存在）：向前推进到该日
  ///   第一个有效本地时刻（03:00 起）；
  /// - **重复**（秋季回拨，例如 01:30 出现两次）：选择**较早**的 UTC 实例。
  ///
  /// 这是全库唯一允许的本地时间解析入口：其它层自己试偏移量，会在一年两次的
  /// 切换日产生"同一句话算出两个时刻"的静默漂移。
  DateTime resolveLocalWallTime({
    required DateTime localDate,
    required int minuteOfDay,
    required String timeZoneId,
  }) {
    if (minuteOfDay < 0 || minuteOfDay >= 24 * 60) {
      throw ArgumentError.value(minuteOfDay, 'minuteOfDay');
    }
    final zone = location(timeZoneId);
    final hour = minuteOfDay ~/ 60;
    final minute = minuteOfDay % 60;
    final local = tz.TZDateTime(
      zone,
      localDate.year,
      localDate.month,
      localDate.day,
      hour,
      minute,
    );
    final instant = _asPlainUtc(local.toUtc());
    final asLocal = toLocal(instant, timeZoneId);
    if (asLocal.hour == hour && asLocal.minute == minute) {
      // 正常时刻；重复时刻 `TZDateTime` 已取较早实例（offset 较大的一侧），
      // 与冻结策略一致。
      return instant;
    }
    // 缺失时刻：`TZDateTime` 会把它平移 gap 的长度（02:30 -> 03:30），而冻结策略
    // 要求落到**第一个有效本地时刻**（03:00）。在 [instant - 3h, instant] 上二分
    // 找"本地墙上时间首次达到请求值"的 UTC 时刻。
    final requestedWall = DateTime(
      localDate.year,
      localDate.month,
      localDate.day,
      hour,
      minute,
    );
    var lower = instant.subtract(const Duration(hours: 3));
    var upper = instant;
    while (upper.difference(lower) > const Duration(microseconds: 1)) {
      final mid = lower.add(
        Duration(microseconds: upper.difference(lower).inMicroseconds ~/ 2),
      );
      final wall = toLocal(mid, timeZoneId);
      final wallValue = DateTime(
        wall.year,
        wall.month,
        wall.day,
        wall.hour,
        wall.minute,
        wall.second,
        wall.millisecond,
        wall.microsecond,
      );
      if (wallValue.isBefore(requestedWall)) {
        lower = mid;
      } else {
        upper = mid;
      }
    }
    return upper;
  }

  DateTime localMidnightToUtc(DateTime localDate, String timeZoneId) =>
      _asPlainUtc(
        tz.TZDateTime(
          location(timeZoneId),
          localDate.year,
          localDate.month,
          localDate.day,
        ).toUtc(),
      );
}

/// 把时刻规范化为普通 UTC `DateTime`。
///
/// `tz.TZDateTime` 即使表示 UTC，`isUtc` 为 true、微秒值与 `hashCode` 都与
/// `DateTime.utc` 相同，但 `==` 返回 **false**。因此只要 TZDateTime 与普通
/// DateTime 混用，所有依赖 `==`、`Set` 或 `Map` 的比较都会出错——例如
/// `TimeRange.operator ==` 会把同一时刻判成两个不同区间，未锁定的判等失败会
/// 让 `PlanValidator` 误报 `lockedBlockMoved`，进而使 `PlanApplicationService`
/// 拒绝合法提案。
///
/// 从本地墙上时间换算出来的 UTC 时刻在返回前统一规范化，从源头消除这个陷阱。
DateTime _asPlainUtc(DateTime instantUtc) =>
    DateTime.fromMicrosecondsSinceEpoch(
      instantUtc.microsecondsSinceEpoch,
      isUtc: true,
    );
