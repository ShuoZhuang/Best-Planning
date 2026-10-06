import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';

void main() {
  final zones = TimeZoneDatabase();

  test('本地墙上时间换算出的 UTC 时刻是普通 DateTime', () {
    final instant = zones.localMidnightToUtc(
      DateTime(2026, 10, 5),
      'Asia/Shanghai',
    );

    // 东八区 2026-10-05 00:00 == 2026-10-04 16:00Z。
    expect(instant, DateTime.utc(2026, 10, 4, 16));
    expect(instant.runtimeType, DateTime);
    expect(instant.isUtc, isTrue);
  });

  test('换算结果可以与普通 UTC 时刻直接判等', () {
    // tz.TZDateTime 即使表示 UTC 也不等于 DateTime.utc（微秒值相同、hashCode
    // 相同，但 == 为 false），因此换算必须返回规范化后的时刻，否则任何依赖
    // == / Set / Map 的比较都会出错。
    final lunchStart = zones.localDateTimeToUtc(
      DateTime(2026, 10, 5),
      12 * 60,
      'Asia/Shanghai',
    );
    expect(lunchStart, DateTime.utc(2026, 10, 5, 4));

    final range = TimeRange(
      startUtc: lunchStart,
      endUtc: zones.localDateTimeToUtc(
        DateTime(2026, 10, 5),
        13 * 60,
        'Asia/Shanghai',
      ),
    );
    expect(
      range,
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 5, 4),
        endUtc: DateTime.utc(2026, 10, 5, 5),
      ),
    );
  });

  test('夏令时切换当天仍按本地钟点换算', () {
    // 纽约 2026-03-08 02:00 进入夏令时；当天 01:30 与 03:30 的 UTC 偏移不同。
    final beforeSpringForward = zones.localDateTimeToUtc(
      DateTime(2026, 3, 8),
      1 * 60 + 30,
      'America/New_York',
    );
    final afterSpringForward = zones.localDateTimeToUtc(
      DateTime(2026, 3, 8),
      3 * 60 + 30,
      'America/New_York',
    );

    // 01:30 EST = 06:30Z，03:30 EDT = 07:30Z：墙上时间相隔 2 小时，实际只隔 1 小时。
    expect(beforeSpringForward, DateTime.utc(2026, 3, 8, 6, 30));
    expect(afterSpringForward, DateTime.utc(2026, 3, 8, 7, 30));
    expect(
      afterSpringForward.difference(beforeSpringForward),
      const Duration(hours: 1),
    );
  });
}
