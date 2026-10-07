/// 统计页每张卡片可以选的**可视化类型**。
///
/// 2026-10-06 用户要求："各个统计的图表类型可以由我来选择，比如饼状图、柱状图、条形图、折线图
/// 都在，由我来选择显示哪个"。
///
/// **可选项按数据形状给，不是四选一全放开**：占比类的数据给折线图没有意义（读者会以为它在
/// 表示趋势），时间序列给饼图更没有意义。因此每个位置用 [AnalyticsChartSlot.allowedKinds]
/// 声明自己允许哪些类型——"给得出但画出来看不懂"不算选择自由，那是陷阱。
enum ChartKind {
  /// 饼图：一眼看构成比例。
  pie,

  /// 柱状图：纵向比较。
  bar,

  /// 条形图：横向比较，分类名长时比柱状图好读。
  horizontalBar,

  /// 折线图：看随时间的变化。
  line,
}

extension ChartKindLabel on ChartKind {
  /// 界面上显示的名字。存进设置的是 `name`（`pie`/`bar`/…），这个只用于界面。
  String get label => switch (this) {
    ChartKind.pie => '饼图',
    ChartKind.bar => '柱状图',
    ChartKind.horizontalBar => '条形图',
    ChartKind.line => '折线图',
  };
}

/// 统计页上**可以单独选图型**的位置。
///
/// 新增一张图就加一个取值：`allowedKinds` 与 `defaultKind` 都必须在这里写全，`switch` 刻意不写
/// `_` 默认分支，这样将来加位置时编译器会指到每一处需要补的地方。
enum AnalyticsChartSlot {
  /// 横向：一个周期内各领域的时间占比。
  areaShare,

  /// 纵向：上周／本周／本月的时间总计。各领域的逐周期明细由紧随其后的矩阵表给出——
  /// 那张表**不参与图型选择**（表就是表），因此这里没有第二个"纵向"槽位。
  periodTotal,

  /// 休息时长：各类休息的容量与被侵占量。
  restDuration,

  /// 工作 / 生活 / 休息 / 未安排 的比例。
  workRest,

  /// 作息规律性：每天的开工与收工时刻。
  routine;

  /// 该位置**允许**的类型。顺序即界面上的下拉顺序。
  List<ChartKind> get allowedKinds => switch (this) {
    AnalyticsChartSlot.areaShare => const [
      ChartKind.pie,
      ChartKind.horizontalBar,
      ChartKind.bar,
    ],
    AnalyticsChartSlot.periodTotal => const [
      ChartKind.bar,
      ChartKind.horizontalBar,
      ChartKind.line,
    ],
    AnalyticsChartSlot.restDuration => const [
      ChartKind.bar,
      ChartKind.horizontalBar,
      ChartKind.pie,
    ],
    AnalyticsChartSlot.workRest => const [
      ChartKind.bar,
      ChartKind.horizontalBar,
      ChartKind.pie,
    ],
    AnalyticsChartSlot.routine => const [
      ChartKind.line,
      ChartKind.bar,
      ChartKind.horizontalBar,
    ],
  };

  /// 默认类型：取 `allowedKinds` 的第一个。刻意不另写一份默认值表——两份表迟早会不一致，
  /// 而"允许的第一个"本身就是最自然、最该当默认的那个。
  ChartKind get defaultKind => allowedKinds.first;

  /// 这张卡片在设置里的键名（与枚举名一致，改名会丢用户的选择，因此不要随手改）。
  String get storageKey => name;
}

/// 某个位置最终用哪个类型：先看用户选过的，非法或没选过就用默认。
///
/// **非法值要回落到默认而不是抛**：设置文件可能来自旧版本或被手改过，而"打开统计页就崩"
/// 不是处理脏数据的合理方式。
ChartKind resolveChartKind(
  AnalyticsChartSlot slot,
  Map<AnalyticsChartSlot, ChartKind>? selected,
) {
  final value = selected?[slot];
  if (value == null) return slot.defaultKind;
  return slot.allowedKinds.contains(value) ? value : slot.defaultKind;
}
