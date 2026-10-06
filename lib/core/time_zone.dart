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
