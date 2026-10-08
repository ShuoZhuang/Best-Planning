// M2（路线图 §3.1、§7.1、§11 Task 3）统计坐标：聚合单位、横轴标签与抽样、时间单位。
//
// **这个文件回答三个此前会静默出错的问题**：
//
// ① **一个数据点最多一个标签，且不重复。** 用户 2026-10-07 报的"横轴日期都是 10/7"就是这一条
//    的反面：范围里只有一天有安排时，图表画出一根横轴重复同一天日期的柱子。§7.1 因此把它列为
//    全局验收口径的第一条。
// ② **标签数量有上限。** 365 天范围逐日画 365 个标签，横轴会糊成一条黑线；抽样规则必须
//    "保留首尾、均匀取"，而且**不能出现重复标签**（否则用户看到两个"上周"或两个"10/7"）。
// ③ **主图数值不显示裸分钟。** §7.1 举的例子是 `1195` 必须显示成 `19 小时 55 分钟`——
//    一个四位数分钟的柱子对用户没有意义，他没法心算那是多久。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/features/analytics/analytics_axis_policy.dart';

final _zones = TimeZoneDatabase();
const _zone = 'Asia/Shanghai';

/// 用本地日期构造统计区间（半开 `[start, end)`），与页面同一口径。
({DateTime startUtc, DateTime endUtc}) _range(
  DateTime localStart,
  DateTime localEndExclusive,
) => (
  startUtc: _zones.localMidnightToUtc(localStart, _zone),
  endUtc: _zones.localMidnightToUtc(localEndExclusive, _zone),
);

/// 一周的日报表：本地 2026-10-05（周一）起 7 天。
({DateTime startUtc, DateTime endUtc}) _oneWeek() =>
    _range(DateTime(2026, 10, 5), DateTime(2026, 10, 12));

/// 按本机时区切桶。宽度 600 与统计页在 1080 宽度上限下的一张卡片相近。
AnalyticsBucketPlan bucketPlan(
  ({DateTime startUtc, DateTime endUtc}) range,
  double width,
) => analyticsBucketPlan(
  range,
  zones: _zones,
  timeZoneId: _zone,
  availableWidth: width,
);

void main() {
  group('M2 聚合单位', () {
    test('单日范围按日聚合，且只有一个桶（不是 24 个小时桶）', () {
      final plan = bucketPlan(
        _range(DateTime(2026, 10, 8), DateTime(2026, 10, 9)),
        600,
      );

      expect(plan.unit, AnalyticsBucketUnit.day);
      expect(plan.buckets, hasLength(1));
    });

    test('7 日范围按日聚合，正好 7 个桶', () {
      final plan = bucketPlan(_oneWeek(), 600);

      expect(plan.unit, AnalyticsBucketUnit.day);
      expect(plan.buckets, hasLength(7), reason: '§7.1："周范围显示 7 个或更少标签"');
    });

    test('31 日范围按周聚合（逐日会画 31 个桶）', () {
      final plan = bucketPlan(
        _range(DateTime(2026, 10, 1), DateTime(2026, 11, 1)),
        600,
      );

      expect(plan.unit, AnalyticsBucketUnit.week);
      expect(plan.buckets.length, lessThanOrEqualTo(6));
    });

    test('365 日范围按月聚合', () {
      final plan = bucketPlan(
        _range(DateTime(2026, 1, 1), DateTime(2027, 1, 1)),
        600,
      );

      expect(plan.unit, AnalyticsBucketUnit.month);
      expect(plan.buckets.length, inInclusiveRange(12, 14));
    });

    test('桶首尾覆盖整个区间，中间无缝隙（否则有分钟会凭空消失）', () {
      for (final range in [
        _range(DateTime(2026, 10, 8), DateTime(2026, 10, 9)),
        _oneWeek(),
        _range(DateTime(2026, 10, 1), DateTime(2026, 11, 1)),
        _range(DateTime(2026, 1, 1), DateTime(2027, 1, 1)),
      ]) {
        final plan = bucketPlan(range, 600);
        expect(
          plan.buckets.first.startUtc,
          range.startUtc,
          reason: '首个桶必须从区间起点开始',
        );
        expect(plan.buckets.last.endUtc, range.endUtc, reason: '末个桶必须到区间终点结束');
        for (var i = 1; i < plan.buckets.length; i++) {
          expect(
            plan.buckets[i].startUtc,
            plan.buckets[i - 1].endUtc,
            reason: '第 $i 个桶与前一个之间不能有空隙',
          );
        }
      }
    });

    test('每个桶都是半开区间（起点早于终点）', () {
      final plan = bucketPlan(
        _range(DateTime(2026, 1, 1), DateTime(2027, 1, 1)),
        600,
      );

      for (final bucket in plan.buckets) {
        expect(bucket.startUtc.isBefore(bucket.endUtc), isTrue);
      }
    });
  });

  group('M2 横轴标签：一个数据点最多一个标签', () {
    test('3 个数据点只出现 3 个标签（不重复）', () {
      final plan = bucketPlan(
        _range(DateTime(2026, 10, 5), DateTime(2026, 10, 8)),
        600,
      );
      final ticks = analyticsAxisTicks(plan.buckets, maxLabels: 8);

      expect(ticks, hasLength(3));
      expect(
        ticks.map((tick) => tick.label).toSet(),
        hasLength(3),
        reason: '标签必须互不相同；重复的"10/7"正是用户报过的那条缺陷',
      );
    });

    test('7 日范围最多 7 个标签', () {
      final plan = bucketPlan(_oneWeek(), 600);
      final ticks = analyticsAxisTicks(plan.buckets, maxLabels: 8);

      expect(ticks.length, lessThanOrEqualTo(7));
      expect(ticks.map((t) => t.label).toSet(), hasLength(ticks.length));
    });

    test('31 日范围与 365 日范围都不超过标签上限', () {
      for (final range in [
        _range(DateTime(2026, 10, 1), DateTime(2026, 11, 1)),
        _range(DateTime(2026, 1, 1), DateTime(2027, 1, 1)),
      ]) {
        final plan = bucketPlan(range, 600);
        final ticks = analyticsAxisTicks(plan.buckets, maxLabels: 8);

        expect(
          ticks.length,
          lessThanOrEqualTo(8),
          reason: '§7.1：横轴最多显示 6～8 个标签；实际 ${ticks.length} 个',
        );
        expect(
          ticks.map((t) => t.label).toSet(),
          hasLength(ticks.length),
          reason: '抽样之后也不能出现重复标签',
        );
      }
    });

    test('抽样保留首尾：第一个与最后一个桶各自恰好一个标签', () {
      final plan = bucketPlan(
        _range(DateTime(2026, 1, 1), DateTime(2027, 1, 1)),
        600,
      );
      final ticks = analyticsAxisTicks(plan.buckets, maxLabels: 6);

      expect(ticks.first.index, 0, reason: '起点必须被标出来，否则用户不知道这张图从哪开始');
      expect(ticks.last.index, plan.buckets.length - 1, reason: '终点必须被标出来');
    });

    test('抽样下标严格递增（否则标签会叠在一起或错位）', () {
      final plan = bucketPlan(
        _range(DateTime(2026, 1, 1), DateTime(2027, 1, 1)),
        600,
      );
      final ticks = analyticsAxisTicks(plan.buckets, maxLabels: 5);

      for (var i = 1; i < ticks.length; i++) {
        expect(ticks[i].index, greaterThan(ticks[i - 1].index));
      }
    });

    test('空桶列表给出空标签（不抛异常）', () {
      expect(analyticsAxisTicks(const [], maxLabels: 8), isEmpty);
    });

    test('桶数不足上限时全部标出，不做无意义的抽样', () {
      final plan = bucketPlan(_oneWeek(), 600);
      final ticks = analyticsAxisTicks(plan.buckets, maxLabels: 8);

      expect(ticks, hasLength(plan.buckets.length));
    });

    test('maxLabels 为 1 时只标第一个（不会越界）', () {
      final plan = bucketPlan(_oneWeek(), 600);
      final ticks = analyticsAxisTicks(plan.buckets, maxLabels: 1);

      expect(ticks, hasLength(1));
      expect(ticks.single.index, 0);
    });
  });

  group('M2 时间单位：主图不显示裸分钟', () {
    test('§7.1 的例子：1195 分钟显示为「19 小时 55 分钟」', () {
      expect(formatAnalyticsMinutes(1195), '19 小时 55 分钟');
    });

    test('整小时不带"0 分钟"，整分钟不带"0 小时"', () {
      expect(formatAnalyticsMinutes(120), '2 小时');
      expect(formatAnalyticsMinutes(45), '45 分钟');
    });

    test('0 与负数都写作「0 分钟」（不出现"-1 小时"这种话）', () {
      expect(formatAnalyticsMinutes(0), '0 分钟');
      expect(formatAnalyticsMinutes(-5), '0 分钟');
    });

    test('一天以上照常进位成小时，不写"25 小时"以外的怪格式', () {
      expect(formatAnalyticsMinutes(60 * 25), '25 小时');
      expect(formatAnalyticsMinutes(60 * 25 + 30), '25 小时 30 分钟');
    });
  });
}
