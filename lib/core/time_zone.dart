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
    return local.toUtc();
  }

  DateTime localMidnightToUtc(DateTime localDate, String timeZoneId) =>
      tz.TZDateTime(
        location(timeZoneId),
        localDate.year,
        localDate.month,
        localDate.day,
      ).toUtc();
}
