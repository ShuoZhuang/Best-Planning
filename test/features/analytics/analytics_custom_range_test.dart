// M7（路线图 §11）退出条件："自定义日期范围包含起始日和结束日，跨月、跨年和空范围有测试"。
//
// 这一组钉住的是 `analyticsRangeForSelectedDays`：用户在选择器里选的**日期区间**（末日含当天）
// 如何换算成统计用的**半开区间** `[startUtc, endUtc)`。
//
// **为什么值得单独测**：少算一天不会报错，只会让每个数字都偏小一点——属于"静默少算"，
// 靠肉眼几乎发现不了。而"末日含当天"这件事在没有断言的情况下极容易被改回去。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/features/analytics/analytics_page.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zone = 'Asia/Shanghai';

  ({DateTime startUtc, DateTime endUtc}) rangeFor(
    DateTime start,
    DateTime end,
  ) => analyticsRangeForSelectedDays(
    DateTimeRange(start: start, end: end),
    zones: zones,
    timeZoneId: zone,
  );

  test('M7 末日含当天：终点取"末日次日零点"', () {
    // 选 10 月 1 日到 10 月 7 日 → 窗口应当是 [1 日零点, 8 日零点)。
    // 若终点取"7 日零点"，7 号一整天都会被排除，而且不会报错。
    final range = rangeFor(DateTime(2026, 10, 1), DateTime(2026, 10, 7));

    expect(
      range.startUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 1), zone),
      reason: '起始日必须包含在内',
    );
    expect(
      range.endUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 8), zone),
      reason: '结束日必须包含在内 ⇒ 终点是次日零点',
    );
    // 半开区间：结束日那一整天都落在窗口里。
    final lastDayNoon = zones.localDateTimeToUtc(
      DateTime(2026, 10, 7),
      12 * 60,
      zone,
    );
    expect(lastDayNoon.isBefore(range.endUtc), isTrue);
    expect(lastDayNoon.isAfter(range.startUtc), isTrue);
  });

  test('M7 单日范围：选同一天也算一整天', () {
    // 选 10 月 7 日到 10 月 7 日 → 窗口是 7 日零点到 8 日零点，正好 24 小时。
    final range = rangeFor(DateTime(2026, 10, 7), DateTime(2026, 10, 7));
    expect(range.endUtc.difference(range.startUtc), const Duration(hours: 24));
  });

  test('M7 跨月：9 月 28 日到 10 月 3 日', () {
    final range = rangeFor(DateTime(2026, 9, 28), DateTime(2026, 10, 3));
    expect(
      range.startUtc,
      zones.localMidnightToUtc(DateTime(2026, 9, 28), zone),
    );
    expect(
      range.endUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 4), zone),
      reason: '跨月时"次日零点"要自动进位到下个月',
    );
  });

  test('M7 跨年：12 月 30 日到次年 1 月 2 日', () {
    final range = rangeFor(DateTime(2026, 12, 30), DateTime(2027, 1, 2));
    expect(
      range.startUtc,
      zones.localMidnightToUtc(DateTime(2026, 12, 30), zone),
    );
    expect(
      range.endUtc,
      zones.localMidnightToUtc(DateTime(2027, 1, 3), zone),
      reason: '跨年时"次日零点"要自动进位到下一年',
    );
  });

  test('M7 跨年且落在 12 月 31 日：终点进到次年 1 月 1 日', () {
    // 年末最后一天是"次日进位"最容易写错的一天。
    final range = rangeFor(DateTime(2026, 12, 31), DateTime(2026, 12, 31));
    expect(range.endUtc, zones.localMidnightToUtc(DateTime(2027, 1, 1), zone));
    expect(range.endUtc.difference(range.startUtc), const Duration(hours: 24));
  });

  test('M7 闰年二月：2 月 28 日到 2 月 29 日', () {
    // 2028 是闰年，2 月有 29 天。
    final range = rangeFor(DateTime(2028, 2, 28), DateTime(2028, 2, 29));
    expect(
      range.endUtc,
      zones.localMidnightToUtc(DateTime(2028, 3, 1), zone),
      reason: '闰年 2 月 29 日的次日是 3 月 1 日，不是 2 月 30 日',
    );
    expect(
      range.endUtc.difference(range.startUtc),
      const Duration(hours: 48),
      reason: '两天 = 48 小时',
    );
  });

  test('M7 非法顺序（结束早于开始）会被显式拒绝，而不是静默给出空窗口', () {
    // `showDateRangePicker` 本身不会交出反向区间，但换算函数是公开的、也可能被别处调用。
    // 重要的是**不会**悄悄产出一个"看起来正常但永远查不到数据"的窗口。
    //
    // **两边都要接受**：反向区间可能在换算这一步就被底层拒绝（本地零点换算自己会断言），
    // 也可能顺利换算出来、到 `AnalyticsFilter` 才被拒。这一条只要求"必须以某种方式报错"，
    // 不把错误来自哪一层写死——那是实现细节，写死会让一次合理的重构变成红。
    Object? thrown;
    ({DateTime startUtc, DateTime endUtc})? range;
    try {
      range = rangeFor(DateTime(2026, 10, 7), DateTime(2026, 10, 1));
      AnalyticsFilter(startUtc: range.startUtc, endUtc: range.endUtc);
    } on Object catch (error) {
      thrown = error;
    }
    expect(
      thrown,
      isNotNull,
      reason:
          '反向区间必须报错。若它被接受成 ${range?.startUtc}..${range?.endUtc}，'
          '用户会看到一个查不到任何数据的"正常"范围',
    );
  });

  test('M7 空范围（起点等于终点作为 UTC 瞬时）会被拒绝', () {
    final midnight = zones.localMidnightToUtc(DateTime(2026, 10, 7), zone);
    expect(
      () => AnalyticsFilter(startUtc: midnight, endUtc: midnight),
      throwsArgumentError,
      reason: '零长度窗口必须拒绝：它会查不到任何东西，却看起来像个正常范围',
    );
  });

  test('M7 起点晚于终点作为 UTC 瞬时也会被拒绝', () {
    final first = zones.localMidnightToUtc(DateTime(2026, 10, 7), zone);
    final second = zones.localMidnightToUtc(DateTime(2026, 10, 8), zone);
    expect(
      () => AnalyticsFilter(startUtc: second, endUtc: first),
      throwsArgumentError,
    );
  });

  test('M7 窗口使用的必须是 UTC 瞬时', () {
    // `AnalyticsFilter` 对本地 DateTime 会直接抛错——这条钉住"换算之后一定是 UTC"。
    final range = rangeFor(DateTime(2026, 10, 1), DateTime(2026, 10, 7));
    expect(range.startUtc.isUtc, isTrue);
    expect(range.endUtc.isUtc, isTrue);
  });
}
