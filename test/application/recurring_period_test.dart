import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/core/time_zone.dart';

/// 周界口径（路线图 §3.3 与 Global Constraints）。
///
/// **这里每一个用例都在回答同一个问题**：某一瞬间属于哪一周。答错的后果不是"显示差一天"，
/// 而是周期实例的唯一键落到相邻周——同一周会生成两个实例，或者一个实例永远不生成。
void main() {
  final zones = TimeZoneDatabase();
  const shanghai = 'Asia/Shanghai';

  test('周日 23:59 仍属于本周，周一 00:00 进入下一周', () {
    // 2026-10-11 是周日，2026-10-12 是周一。本地时间（UTC+8）：
    final sundayNight = DateTime.utc(2026, 10, 11, 15, 59); // 本地 23:59
    final mondayMidnight = DateTime.utc(2026, 10, 11, 16); // 本地 10-12 00:00

    final beforeCut = WeeklyPeriod.forInstant(sundayNight, shanghai, zones);
    final afterCut = WeeklyPeriod.forInstant(mondayMidnight, shanghai, zones);

    expect(beforeCut.startLocalDate, DateTime(2026, 10, 5));
    expect(afterCut.startLocalDate, DateTime(2026, 10, 12));
    expect(beforeCut.endUtc, mondayMidnight, reason: '半开区间：终点属于下一周');
    expect(afterCut.startUtc, mondayMidnight);
  });

  test('周界是本地周一 00:00 到下一周周一 00:00', () {
    final period = weeklyPeriodFor(DateTime.utc(2026, 10, 7, 4), shanghai);
    expect(period.startLocalDate, DateTime(2026, 10, 5));
    expect(period.startLocalDate.weekday, DateTime.monday);
    expect(period.endLocalDate, DateTime(2026, 10, 12));
    // 本地 2026-10-05 00:00 = UTC 2026-10-04 16:00
    expect(period.startUtc, DateTime.utc(2026, 10, 4, 16));
    expect(period.endUtc, DateTime.utc(2026, 10, 11, 16));
    final localStart = period.localStart(zones);
    expect(localStart.weekday, DateTime.monday);
    expect(localStart.hour, 0);
  });

  test('跨年：2026-12-31 属于包含它的那一周，且不因跨年分裂', () {
    // 2026-12-31 是周四，所在周的周一是 2026-12-28。
    final period = weeklyPeriodFor(DateTime.utc(2026, 12, 31, 4), shanghai);
    expect(period.startLocalDate, DateTime(2026, 12, 28));
    expect(period.endLocalDate, DateTime(2027, 1, 4));
    // 2027-01-01 属于**同一周**，不是新的一年就从周一开始。
    final newYear = weeklyPeriodFor(DateTime.utc(2027, 1, 1, 4), shanghai);
    expect(newYear.startLocalDate, DateTime(2026, 12, 28));
    expect(newYear.startUtc, period.startUtc);
  });

  test('时区转换：同一瞬间在 UTC 与东八区可能属于不同周', () {
    // UTC 2026-10-11 20:00 = 本地(UTC+8) 2026-10-12 04:00 → 东八区是下一周；
    // 而 UTC 时区里它仍是 2026-10-11（周日），属于 10-05 那一周。
    final instant = DateTime.utc(2026, 10, 11, 20);
    expect(weeklyPeriodFor(instant, shanghai).startLocalDate, DateTime(2026, 10, 12));
    expect(weeklyPeriodFor(instant, 'UTC').startLocalDate, DateTime(2026, 10, 5));
  });

  test('程序跨周未重启：同一个 nowUtc 反复算出的周界完全一致', () {
    // "跨周未重启"要的是**用当前时刻重算**，而不是复用启动时算好的值。这里固定瞬间、
    // 反复调用，结果必须逐字段相同——它是无状态纯函数，因此这一点必须成立。
    final now = DateTime.utc(2026, 10, 12, 0, 30);
    final first = weeklyPeriodFor(now, shanghai);
    for (var attempt = 0; attempt < 5; attempt++) {
      final again = weeklyPeriodFor(now, shanghai);
      expect(again.startLocalDate, first.startLocalDate);
      expect(again.startUtc, first.startUtc);
      expect(again.endUtc, first.endUtc);
    }
  });

  test('previous / next 按日历周位移，跨年与跨月都正确', () {
    final period = WeeklyPeriod.startingAt(
      DateTime(2027, 1, 4),
      shanghai,
      zones,
    );
    expect(period.previous(zones).startLocalDate, DateTime(2026, 12, 28));
    expect(period.next(zones).startLocalDate, DateTime(2027, 1, 11));
    expect(
      period.next(zones).previous(zones).startLocalDate,
      period.startLocalDate,
    );
  });

  test('美国夏令时切换周仍然是七天（按日历日推进，不用 Duration）', () {
    // 2026-11-01 是美国夏令时结束日（纽约）。若用 `add(Duration(days: 7))` 构造周界，
    // 那一天的 24 小时会出现 25 小时，日期可能不前进。本地周一日期必须仍然是 11-02 → 11-09。
    const newYork = 'America/New_York';
    final period = WeeklyPeriod.forInstant(
      DateTime.utc(2026, 11, 4, 12),
      newYork,
      zones,
    );
    expect(period.startLocalDate, DateTime(2026, 11, 2));
    expect(period.startLocalDate.weekday, DateTime.monday);
    expect(period.endLocalDate, DateTime(2026, 11, 9));
    // 实际时长可能是 167/169 小时，这正是"不能假设 7×24 小时"的原因。
    expect(period.durationHours, anyOf(167, 168, 169));
  });

  test('构造校验：非周一的起点、非 UTC 的时刻都被拒绝', () {
    expect(
      () => WeeklyPeriod.startingAt(DateTime(2026, 10, 6), shanghai, zones),
      throwsArgumentError,
    );
    expect(
      () => weeklyPeriodFor(DateTime(2026, 10, 7), shanghai),
      throwsArgumentError,
    );
  });

  test('startingAt 与 forInstant 对同一周给出相同边界', () {
    final fromInstant = weeklyPeriodFor(DateTime.utc(2026, 10, 7, 4), shanghai);
    final explicit = WeeklyPeriod.startingAt(
      DateTime(2026, 10, 5),
      shanghai,
      zones,
    );
    expect(explicit.startUtc, fromInstant.startUtc);
    expect(explicit.endUtc, fromInstant.endUtc);
  });
}
