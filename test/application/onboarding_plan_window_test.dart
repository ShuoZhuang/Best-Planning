// M8 §1.5 计划日期（用户 2026-10-07 定案）。
//
// 用户原话：
//   规划起点：今天本地 00:00
//   规划范围：今天 + 后续 6 个自然日
//   例如 2026-10-07 → 2026-10-07 ～ 2026-10-13
//   **重新打开引导时应以重新生成当日的日期为准**，
//   不能继续使用第一次进入引导时保存的旧日期。
//
// **"本地"这三个字是这条里最容易做错的地方**：用 UTC 的今天会在 UTC+8 的凌晨
// 差一天——用户在 10-08 00:30 打开引导，窗口却从 10-07 开始，于是"今天"那一格
// 其实排的是昨天。仓库里保护时间展开器（§13.0 的 C11）与统计页都吃过这一处，
// 所以这里单独钉。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/onboarding_progress.dart';
import 'package:personal_planner/core/time_zone.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zone = 'Asia/Shanghai';

  test('M8 计划窗口是"本机今天零点"起 7 个自然日', () {
    // 用户在本地 10-07 的任意时刻进入（这里取下午，避免跨日边界干扰）。
    final nowUtc = zones.localDateTimeToUtc(
      DateTime(2026, 10, 7),
      15 * 60,
      zone,
    );
    final window = onboardingPlanWindow(
      nowUtc: nowUtc,
      zones: zones,
      timeZoneId: zone,
    );

    expect(
      window.startUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 7), zone),
      reason: '起点必须是**本机今天**的零点',
    );
    expect(
      window.endUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 14), zone),
      reason: '今天 + 后续 6 天 ⇒ 终点是第 7 天的零点（半开区间）',
    );
    expect(
      window.endUtc.difference(window.startUtc),
      const Duration(days: 7),
      reason: '10-07～10-13 共 7 个自然日',
    );
  });

  test('M8 UTC+8 凌晨进入引导时，起点仍是**本机**今天（不是 UTC 的昨天）', () {
    // 本机 10-08 00:30 = UTC 10-07 16:30。用 UTC 日期会算出 10-07。
    final nowUtc = DateTime.utc(2026, 10, 7, 16, 30);
    final window = onboardingPlanWindow(
      nowUtc: nowUtc,
      zones: zones,
      timeZoneId: zone,
    );

    expect(
      window.startUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 8), zone),
      reason: '本机已经是 10-08，窗口必须从 10-08 开始',
    );
    expect(
      window.endUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 15), zone),
    );
  });

  test('M8 重新进入引导时用**新的**今天（不沿用上次的日期）', () {
    // 同一个函数、两次不同的"现在"，必须给出两个不同的窗口——
    // 这正是"以重新生成当日的日期为准"的判据。
    final first = onboardingPlanWindow(
      nowUtc: zones.localDateTimeToUtc(DateTime(2026, 10, 7), 9 * 60, zone),
      zones: zones,
      timeZoneId: zone,
    );
    final later = onboardingPlanWindow(
      nowUtc: zones.localDateTimeToUtc(DateTime(2026, 10, 20), 9 * 60, zone),
      zones: zones,
      timeZoneId: zone,
    );

    expect(first.startUtc, isNot(later.startUtc), reason: '两次的起点必须不同');
    expect(
      later.startUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 20), zone),
      reason: '第二次进入必须用第二次的今天',
    );
  });

  test('M8 跨月时终点正确进位', () {
    final window = onboardingPlanWindow(
      nowUtc: zones.localDateTimeToUtc(DateTime(2026, 10, 30), 10 * 60, zone),
      zones: zones,
      timeZoneId: zone,
    );
    expect(
      window.startUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 30), zone),
    );
    expect(
      window.endUtc,
      zones.localMidnightToUtc(DateTime(2026, 11, 6), zone),
      reason: '按日历加法进位到 11 月，不是 10 月 36 日',
    );
  });

  test('M8 窗口是半开区间：起点包含、终点不含', () {
    final window = onboardingPlanWindow(
      nowUtc: zones.localDateTimeToUtc(DateTime(2026, 10, 7), 10 * 60, zone),
      zones: zones,
      timeZoneId: zone,
    );
    // 10-13 当天 23:59 必须在窗口内。
    final lastMoment = zones.localDateTimeToUtc(
      DateTime(2026, 10, 13),
      23 * 60 + 59,
      zone,
    );
    expect(lastMoment.isBefore(window.endUtc), isTrue);
    expect(lastMoment.isAfter(window.startUtc), isTrue);
    // 10-14 零点必须在窗口外。
    final nextDay = zones.localMidnightToUtc(DateTime(2026, 10, 14), zone);
    expect(nextDay.isBefore(window.endUtc), isFalse);
  });
}
