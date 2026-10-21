// 1.11.0（计划 Task 4 Step 2）：DST 缺失/重复本地时间的唯一解析策略。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';

void main() {
  final zones = TimeZoneDatabase();
  const newYork = 'America/New_York';

  test('缺失时刻推进到第一个有效本地时刻（02:30 -> 03:00）', () {
    final instant = zones.resolveLocalWallTime(
      localDate: DateTime(2026, 3, 8),
      minuteOfDay: 2 * 60 + 30,
      timeZoneId: newYork,
    );

    final local = zones.toLocal(instant, newYork);
    expect((local.hour, local.minute), (3, 0));
    expect(instant, DateTime.utc(2026, 3, 8, 7));
  });

  test('重复时刻选择较早的 UTC 实例（EDT 一侧）', () {
    final instant = zones.resolveLocalWallTime(
      localDate: DateTime(2026, 11, 1),
      minuteOfDay: 1 * 60 + 30,
      timeZoneId: newYork,
    );

    final local = zones.toLocal(instant, newYork);
    expect((local.hour, local.minute), (1, 30));
    expect(instant, DateTime.utc(2026, 11, 1, 5, 30));
    expect(local.timeZoneOffset, const Duration(hours: -4));
  });

  test('普通时刻逐字往返，不产生漂移', () {
    final instant = zones.resolveLocalWallTime(
      localDate: DateTime(2026, 10, 19),
      minuteOfDay: 10 * 60,
      timeZoneId: 'Asia/Shanghai',
    );

    expect(instant, DateTime.utc(2026, 10, 19, 2));
    final local = zones.toLocal(instant, 'Asia/Shanghai');
    expect((local.hour, local.minute), (10, 0));
  });

  test('拒绝越界的分钟数', () {
    expect(
      () => zones.resolveLocalWallTime(
        localDate: DateTime(2026, 10, 19),
        minuteOfDay: 24 * 60,
        timeZoneId: 'Asia/Shanghai',
      ),
      throwsArgumentError,
    );
  });
}
