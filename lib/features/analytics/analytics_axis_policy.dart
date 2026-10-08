// 统计坐标：聚合单位、横轴标签与抽样、时间单位（路线图 §3.1、§7.1、§11 Task 3）。
//
// **为什么这一层要单独存在**：`analytics_page.dart` 已经一千二百多行，而"一段范围该怎么切成桶、
// 横轴该标几个"是一条**算法**，不是渲染细节。放进页面意味着它只能靠 Widget 测试验证（要先把
// 页面搭起来、等假查询返回、再去数图上的文字），而它其实是纯函数：给一对瞬时和一个宽度，
// 答案就定了。§5 的组件边界表因此把它列为独立文件。
//
// **它修掉的是两类静默错误**：
//
// ① **重复横轴标签**。用户 2026-10-07 报过"横轴日期都是 10/7"：范围里只有一天有安排时，
//    图表画出一根横轴重复同一天日期的柱子。§7.1 把它列为全局验收口径第一条——
//    "横轴一个数据点最多出现一个标签；不存在重复『上周』或重复日期"。
// ② **裸分钟**。§7.1 的例子是 `1195` 必须显示成 `19 小时 55 分钟`：一个四位数的分钟数
//    用户没法心算，柱子对他没有意义。
import 'package:personal_planner/core/time_zone.dart';

/// 一段范围的**聚合单位**。决定桶的粒度，也决定横轴标签长什么样。
enum AnalyticsBucketUnit {
  /// 一个桶 = 一个本地日。
  day,

  /// 一个桶 = 一个本地周（周一起）。
  week,

  /// 一个桶 = 一个本地月（1 日起）。
  month,
}

/// 一个桶：本地日界切出来的半开区间 `[startUtc, endUtc)`。
///
/// **起止都是 `localMidnightToUtc` 的结果**，不是"起点加 7×24 小时"：夏令时切换日的一周不是
/// 168 小时，用绝对时间加会把桶边界推到本地 23:00 或 01:00，于是同一份数据在不同的桶里被算两次
/// 或者一次都不算。本仓库的排程侧在"按日推进"上吃过同一处亏（见 `protected_time_expander.dart`）。
final class AnalyticsBucket {
  const AnalyticsBucket({
    required this.startUtc,
    required this.endUtc,
    required this.label,
  });

  final DateTime startUtc;
  final DateTime endUtc;

  /// 横轴候选标签。**每个桶恰好一个**——"一个数据点最多一个标签"从数据形状上就成立，
  /// 不靠界面去重。
  final String label;
}

/// 一段范围的切桶结果：单位 + 桶序列。
final class AnalyticsBucketPlan {
  const AnalyticsBucketPlan({required this.unit, required this.buckets});

  final AnalyticsBucketUnit unit;
  final List<AnalyticsBucket> buckets;
}

/// 一个横轴标签：指向第几个桶，以及显示什么。
final class AxisTick {
  const AxisTick({required this.index, required this.label});

  /// 桶在 [AnalyticsBucketPlan.buckets] 里的下标。
  final int index;

  final String label;
}

/// [availableWidth] 低于这个宽度时按它算——低于 240 像素时"每 80 像素一个标签"的规则会算出
/// 0 或负数个标签，而一个没有横轴的图比标签挤一点更难读。
const double _minimumAxisWidth = 240;

/// 一个标签大致占的横向宽度（像素）。中文日期标签如 `10/07` 或 `10 月` 在这个量级。
const double _pixelsPerLabel = 80;

/// 超过这个天数就按周聚合。
///
/// **为什么阈值是 28**：§3.1 与 §11 Task 3 要求"周范围按日聚合，**月范围按周聚合**"。
/// 一个自然月是 28～31 天，取 28 才能让**最长的月范围（31 天）也落到按周**——
/// 阈值写成 31 的话，10 月（31 天）会逐日画 31 根柱子，而 9 月（30 天）却按周，
/// 同一份数据在两个月份里长出两种图。取 28 同时保住了"7 日范围正好 7 根柱子"。
const int dailyBucketMaxDays = 28;

/// 超过这个天数就按月聚合。半年（183 天）按周是 26 个点，仍然能读；一年按周是 52 个点，
/// 横轴就必须抽样到看不出趋势，因此一年及以上按月。
const int weekBucketMaxDays = 183;

/// 把一段本地范围切成聚合桶。
///
/// [localRange] 必须已经是 UTC 瞬时（`AnalyticsFilter` 的口径），且首尾是**本地日界**。
///
/// [availableWidth] 目前只用于推导显示上的标签上限（见 [analyticsAxisTicks]），
/// 但保留在签名里是有意的：§11 Task 3 的接口就是
/// `analyticsBucketPlan(DateTimeRange localRange, double availableWidth)`，
/// 而"宽度足够时逐日、不够时按周"这类取舍将来要落在这里。
AnalyticsBucketPlan analyticsBucketPlan(
  ({DateTime startUtc, DateTime endUtc}) localRange, {
  required TimeZoneDatabase zones,
  required String timeZoneId,
  required double availableWidth,
}) {
  final startLocal = _localDate(zones, timeZoneId, localRange.startUtc);
  final endLocal = _localDate(zones, timeZoneId, localRange.endUtc);
  final days = endLocal.difference(startLocal).inDays;

  final unit = days <= dailyBucketMaxDays
      ? AnalyticsBucketUnit.day
      // 单日范围也是 `day`（一个桶），因此上面这条同时覆盖了"今天"。
      : days <= weekBucketMaxDays
      ? AnalyticsBucketUnit.week
      : AnalyticsBucketUnit.month;

  final edges = switch (unit) {
    AnalyticsBucketUnit.day => _dayEdges(startLocal, endLocal),
    AnalyticsBucketUnit.week => _weekEdges(startLocal, endLocal),
    AnalyticsBucketUnit.month => _monthEdges(startLocal, endLocal),
  };

  final buckets = <AnalyticsBucket>[];
  for (var i = 0; i + 1 < edges.length; i++) {
    buckets.add(
      AnalyticsBucket(
        startUtc: zones.localMidnightToUtc(edges[i], timeZoneId),
        endUtc: zones.localMidnightToUtc(edges[i + 1], timeZoneId),
        label: _labelFor(unit, edges[i]),
      ),
    );
  }
  return AnalyticsBucketPlan(unit: unit, buckets: buckets);
}

/// 从桶序列里挑出最多 [maxLabels] 个标签。
///
/// **抽样规则：保留首尾 + 均匀取。** 首尾必须留下——没有起点标签，用户不知道这张图从哪天开始；
/// 没有终点标签，他不知道到哪天为止。中间按下标等距取，因此**不会出现重复标签**（桶的标签本来
/// 就互不相同，按下标取值只会少取、不会取重）。
///
/// [maxLabels] 小于 1 时按 1 处理：调用方算出一个非正的上限（窗口极窄）时，给"只有起点"比给
/// 空横轴更有用。
List<AxisTick> analyticsAxisTicks(
  List<AnalyticsBucket> buckets, {
  required int maxLabels,
}) {
  if (buckets.isEmpty) return const [];
  final limit = maxLabels < 1 ? 1 : maxLabels;
  if (buckets.length <= limit) {
    return [
      for (var i = 0; i < buckets.length; i++)
        AxisTick(index: i, label: buckets[i].label),
    ];
  }
  if (limit == 1) {
    return [AxisTick(index: 0, label: buckets.first.label)];
  }

  // 在 [0, length-1] 上等距取 limit 个下标。用整数乘除而不是浮点累加，
  // 免得 `0.1 + 0.2` 那种误差把最后一个点挤掉或挤出重复下标。
  final last = buckets.length - 1;
  final indices = <int>{};
  for (var i = 0; i < limit; i++) {
    indices.add((last * i) ~/ (limit - 1));
  }
  final sorted = indices.toList()..sort();
  return [
    for (final index in sorted)
      AxisTick(index: index, label: buckets[index].label),
  ];
}

/// 宽度够放几个标签。宽度会被夹到 [_minimumAxisWidth]。
int analyticsMaxLabelsForWidth(double availableWidth) {
  final width = availableWidth < _minimumAxisWidth
      ? _minimumAxisWidth
      : availableWidth;
  final count = (width / _pixelsPerLabel).floor();
  // 上限 8 是 §7.1 写死的（"横轴最多显示 6～8 个标签"）。下限 1：再窄也要有一个。
  return count.clamp(1, 8);
}

/// 分钟数 → "X 小时 Y 分钟"。**用户可见的时长一律走这里**（§7.1 第 3 条）。
///
/// 与今日页的 `formatPlannerMinutes` 是同一套写法：两处各写一份的话，"1195 分钟"可能在统计页
/// 被格式化成"19 小时 55 分钟"、在今日页却是别的样子。负数按 0 处理——时长不可能为负，
/// 出现负数说明上游算错了，显示"-1 小时"只会让人更困惑。
String formatAnalyticsMinutes(int minutes) {
  if (minutes <= 0) return '0 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return '$rest 分钟';
  if (rest == 0) return '$hours 小时';
  return '$hours 小时 $rest 分钟';
}

/// UTC 瞬时 → 它所在**本地日**的年月日。
DateTime _localDate(
  TimeZoneDatabase zones,
  String timeZoneId,
  DateTime instantUtc,
) {
  final local = zones.toLocal(instantUtc, timeZoneId);
  return DateTime(local.year, local.month, local.day);
}

/// 逐日的边界：`[start, start+1, ..., end]`。
///
/// 用 `DateTime(y, m, d + i)` 而不是 `add(Duration(days: i))`：后者是绝对时间加法，
/// 夏令时切换日的本地一天不是 24 小时（见文件头的说明）。
List<DateTime> _dayEdges(DateTime start, DateTime end) => [
  for (
    var date = start;
    date.isBefore(end);
    date = DateTime(date.year, date.month, date.day + 1)
  )
    date,
  end,
];

/// 按周的边界：先对齐到**区间起点所在周的周一**，再每周推进一格。
///
/// **为什么对齐周一而不是从起点每 7 天切一刀**：用户读的是"周"，一刀切出来的桶不对应任何
/// 自然周，"本周"这一列就没法和其它视图对上。对齐之后第一个桶可能比 7 天短（区间从周三开始
/// 就只含周三到周日），这是正确的——桶只覆盖区间内的部分。
List<DateTime> _weekEdges(DateTime start, DateTime end) {
  final firstMonday = DateTime(
    start.year,
    start.month,
    start.day - (start.weekday - DateTime.monday),
  );
  final edges = <DateTime>[];
  // 第一个边界取**区间起点**：早于它的那几天不在范围里，不该出现在标签上。
  edges.add(start);
  for (
    var monday = firstMonday;
    monday.isBefore(end);
    monday = DateTime(monday.year, monday.month, monday.day + 7)
  ) {
    final next = DateTime(monday.year, monday.month, monday.day + 7);
    // 只把落在区间内部的边界放进图里；越过终点的部分由末尾的 `end` 收口。
    if (next.isAfter(start) && next.isBefore(end)) edges.add(next);
  }
  edges.add(end);
  return edges;
}

/// 按月的边界：对齐到区间起点所在月的 1 日，逐月推进；末边界取区间终点。
List<DateTime> _monthEdges(DateTime start, DateTime end) {
  final edges = <DateTime>[start];
  for (
    var month = DateTime(start.year, start.month);
    month.isBefore(end);
    month = DateTime(month.year, month.month + 1)
  ) {
    final next = DateTime(month.year, month.month + 1);
    if (next.isAfter(start) && next.isBefore(end)) edges.add(next);
  }
  edges.add(end);
  return edges;
}

/// 桶的标签。**逐单位不同，且逐桶唯一**——日给 `10/07`，周给 `10/05 周`，月给 `2026-10`。
///
/// 日标签用 `M/d` 而不是 `yyyy-MM-dd`：一个 7 桶的横轴放不下 7 个完整日期，而年份在
/// 月范围以上的聚合里已经由月标签承担。两位数补零（`10/07` 而不是 `10/7`）是刻意的：
/// 宽度固定的横轴上，补零之后每个标签一样宽，不会出现"10/7"和"10/12"挤在一起。
String _labelFor(AnalyticsBucketUnit unit, DateTime localDate) {
  String two(int value) => value.toString().padLeft(2, '0');
  return switch (unit) {
    AnalyticsBucketUnit.day => '${localDate.month}/${two(localDate.day)}',
    AnalyticsBucketUnit.week => '${localDate.month}/${two(localDate.day)} 周',
    AnalyticsBucketUnit.month => '${localDate.year}-${two(localDate.month)}',
  };
}
