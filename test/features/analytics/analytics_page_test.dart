import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/features/analytics/analytics_page.dart';

void main() {
  testWidgets('统计页的四种时间范围都能切换出正确的窗口', (tester) async {
    // FR-STAT-01 / spec §18 第 11 项要求"统计支持今天、本周、本月和自定义日期范围"。
    // 此前只有「本月」被断言过，其余三个只在界面上存在——**存在不等于生效**。
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final query = _AnalyticsQueryFake(_report());
    await tester.pumpWidget(
      MaterialApp(
        home: AnalyticsPage(
          analytics: query,
          nowUtc: DateTime.utc(2026, 10, 8, 8),
          zones: TimeZoneDatabase(),
          timeZoneId: 'Asia/Shanghai',
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> tapAndExpect(
      String label,
      DateTime start,
      DateTime end,
    ) async {
      await tester.tap(find.byKey(_rangeKey(label)));
      await tester.pumpAndSettle();
      expect(query.filters.last.startUtc, start, reason: '「$label」的窗口起点不对');
      expect(query.filters.last.endUtc, end, reason: '「$label」的窗口终点不对');
    }

    // 四种范围在界面上都存在，这是前提。按 key 而不是按文本：矩阵表头与柱状图坐标轴上
    // 也有"本周""本月"这些字，按文本查找会命中多个控件。
    for (final label in ['今天', '本周', '本月', '自定义范围']) {
      expect(
        find.byKey(_rangeKey(label)),
        findsOneWidget,
        reason: '缺少范围选项「$label」',
      );
    }

    // 「今天」= 当前本地日的 [00:00, 次日 00:00)，用**本地**日界构造后再比 UTC。
    final zones = TimeZoneDatabase();
    const zoneId = 'Asia/Shanghai';
    final localToday = zones.toLocal(DateTime.utc(2026, 10, 8, 8), zoneId);
    await tapAndExpect(
      '今天',
      zones.localMidnightToUtc(
        DateTime(localToday.year, localToday.month, localToday.day),
        zoneId,
      ),
      zones.localMidnightToUtc(
        DateTime(localToday.year, localToday.month, localToday.day + 1),
        zoneId,
      ),
    );
    // 「本周」= 含今天的那个 7 天窗口，起点是本周一的本地零点。
    final today = DateTime(localToday.year, localToday.month, localToday.day);
    final monday = today.subtract(Duration(days: today.weekday - 1));
    await tapAndExpect(
      '本周',
      zones.localMidnightToUtc(monday, zoneId),
      zones.localMidnightToUtc(
        DateTime(monday.year, monday.month, monday.day + 7),
        zoneId,
      ),
    );
    // 「本月」= 当月 1 日至次月 1 日。
    await tapAndExpect(
      '本月',
      zones.localMidnightToUtc(DateTime(today.year, today.month), zoneId),
      zones.localMidnightToUtc(DateTime(today.year, today.month + 1), zoneId),
    );
    // 「自定义范围」不再直接查询：它打开日期选择，因此这里只要求**给出一个可用的窗口**
    // （起止合法且为正），而不是断言某个具体日期——具体日期由用户选。
    await tester.tap(find.byKey(const Key('analytics-range-custom')));
    await tester.pumpAndSettle();
    final custom = query.filters.last;
    expect(custom.startUtc.isUtc && custom.endUtc.isUtc, isTrue);
    expect(custom.startUtc.isBefore(custom.endUtc), isTrue);
  });

  testWidgets('统计页显示领域占比、时间总计、完成情况，且不再显示计划/实际', (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final query = _AnalyticsQueryFake(_report());
    await tester.pumpWidget(
      MaterialApp(
        home: AnalyticsPage(
          analytics: query,
          nowUtc: DateTime.utc(2026, 10, 8, 8),
          zones: TimeZoneDatabase(),
          timeZoneId: 'Asia/Shanghai',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // **「计划 / 实际」整组已按用户要求移除**（"这个程序原先的本质就是计划，实际是什么没有统计
    // 必要"）。这条断言盯住它真的不再出现——否则将来有人"顺手"把它加回来也不会有人发现。
    expect(find.text('计划 120 分钟'), findsNothing);
    expect(find.text('实际 90 分钟'), findsNothing);
    expect(find.text('计划 / 实际'), findsNothing);
    expect(find.text('每日趋势'), findsNothing);

    // 横向：领域占比（当前范围）。
    expect(find.byKey(const Key('analytics-area-share')), findsOneWidget);
    expect(find.text('领域占比'), findsOneWidget);
    // 规划是否合理：完成率/按期/逾期都保留——它们问的是"计划合不合理"，与"计划 vs 实际"无关。
    expect(find.text('完成率 3 / 4'), findsOneWidget);

    // 纵向：时间总计 + 矩阵表。假报告对每次查询都返回同一份：三个周期的合计都是 120
    // （学业 90 + 生活 30），学业占 75%、生活占 25%。
    expect(find.byKey(const Key('analytics-period-total')), findsOneWidget);
    expect(find.text('时间总计'), findsOneWidget);
    expect(
      find.byKey(const Key('analytics-area-period-table')),
      findsOneWidget,
    );
    expect(find.text('90 分钟（75%）'), findsNWidgets(3));
    expect(find.text('30 分钟（25%）'), findsNWidgets(3));

    await tester.tap(find.byKey(const Key('analytics-range-month')));
    await tester.pumpAndSettle();

    // **本地日界**：东八区下 10 月从 09-30T16:00Z 开始。这两条断言此前写的是
    // `DateTime.utc(2026, 10, 1)`——也就是说它们把"统计按月取窗口"钉在了 **UTC** 日界上，
    // 而需求 §13／R11 要求按用户本机时区。修好页面后它们正是失败的用例，因此这里一并改成
    // 正确的期望值（旧值就是那个缺陷本身）。
    final zonesForRange = TimeZoneDatabase();
    expect(
      query.filters.last.startUtc,
      zonesForRange.localMidnightToUtc(DateTime(2026, 10), 'Asia/Shanghai'),
    );
    expect(
      query.filters.last.endUtc,
      zonesForRange.localMidnightToUtc(DateTime(2026, 11), 'Asia/Shanghai'),
    );
    // 温和反馈（FR-STAT-08 呈现侧）要求页面**再取一次对照窗口**：紧邻其前的等长区间，
    // 因此它以**当前窗口的起点**收尾。当前月窗口是 10-01→11-01（以 11-01 收尾），所以
    // "以 10-01 收尾的查询"就是那一次对照。断言不依赖查询位置（本用例中间切换过范围）。
    expect(
      query.filters.where(
        (f) =>
            f.endUtc ==
            zonesForRange.localMidnightToUtc(
              DateTime(2026, 10),
              'Asia/Shanghai',
            ),
      ),
      isNotEmpty,
      reason: '缺少以当前窗口起点收尾的查询，说明对照窗口没有被请求，反馈区将永不出现',
    );
  });

  testWidgets('自定义范围的选择器按钮既看得见、也是中文', (tester) async {
    // 用户 2026-10-07 反馈："自定义范围在选择统计范围的时候右上角的两个按钮不明显，容易被看不见"。
    // 诊断出**两个原因**，这条把两个都钉住：
    // ① 它继承全局 `textButtonTheme` 的次要灰 → 在深色面板上几乎看不见；
    // ② 应用没配 Material 本地化 → 全屏形态的确认按钮显示英文 **`Save`**、月份显示 `October 2026`，
    //    用户面对纯中文界面根本认不出那是"应用"。
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        // 与真实应用同一份本地化配置（`PlannerApp` 用的就是这个常量）。
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        theme: PlannerTheme.dark(),
        home: AnalyticsPage(
          analytics: _AnalyticsQueryFake(_report()),
          nowUtc: DateTime.utc(2026, 10, 8, 8),
          zones: TimeZoneDatabase(),
          timeZoneId: 'Asia/Shanghai',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('analytics-range-custom')));
    await tester.pumpAndSettle();

    // ② 不再是英文兜底。
    expect(find.text('Save'), findsNothing, reason: '英文兜底就是用户"看不见"的一半原因');
    expect(find.text('October 2026'), findsNothing);
    // 全屏与对话框两种形态都用"应用"这个文案。
    expect(find.text('应用'), findsOneWidget);

    // ① 对比度：前景必须是主文本色，不是次要灰。
    final theme = Theme.of(tester.element(find.text('应用')));
    expect(
      theme.textButtonTheme.style!.foregroundColor!.resolve(
        const <WidgetState>{},
      ),
      PlannerPalette.textPrimary,
      reason: '仍是次要灰 → 用户在深色面板上看不见',
    );
  });

  testWidgets('领域时间分配固定按上周/本周/本月取数，不随范围选择漂移', (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final query = _AnalyticsQueryFake(_report());
    await tester.pumpWidget(
      MaterialApp(
        home: AnalyticsPage(
          analytics: query,
          // 2026-10-08 是周四 → 本周一是 10-05，上周一是 09-28。
          nowUtc: DateTime.utc(2026, 10, 8, 8),
          zones: TimeZoneDatabase(),
          timeZoneId: 'Asia/Shanghai',
        ),
      ),
    );
    await tester.pumpAndSettle();
    query.filters.clear();

    // 把范围切成「今天」：矩阵的三个周期**不该**跟着变——用户要的是固定基准的横向纵向对比。
    await tester.tap(find.byKey(const Key('analytics-range-today')));
    await tester.pumpAndSettle();

    final zones = TimeZoneDatabase();
    DateTime at(DateTime local) =>
        zones.localMidnightToUtc(local, 'Asia/Shanghai');
    final starts = query.filters.map((filter) => filter.startUtc).toSet();

    expect(starts, contains(at(DateTime(2026, 9, 28))), reason: '缺上周');
    expect(starts, contains(at(DateTime(2026, 10, 5))), reason: '缺本周');
    expect(starts, contains(at(DateTime(2026, 10))), reason: '缺本月');
    // 当前窗口仍然是最后一次查询（既有测试与页面都依赖这一点）。
    expect(query.filters.last.startUtc, at(DateTime(2026, 10, 8)));
  });

  testWidgets('三个周期都没有计划块时说明情况，而不是给一块空白表', (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 实际投入不为 0、但计划块为 0：矩阵只算计划块，所以这里必须走空状态。
    final query = _AnalyticsQueryFake(_reportWithoutPlannedBlocks());
    await tester.pumpWidget(
      MaterialApp(
        home: AnalyticsPage(
          analytics: query,
          nowUtc: DateTime.utc(2026, 10, 8, 8),
          zones: TimeZoneDatabase(),
          timeZoneId: 'Asia/Shanghai',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('analytics-period-total')), findsOneWidget);
    expect(find.text('上周、本周与本月都还没有已确认的计划块或固定日程。'), findsOneWidget);
    expect(find.byKey(const Key('analytics-area-period-table')), findsNothing);
  });
}

AnalyticsReport _report() {
  final filter = AnalyticsFilter(
    startUtc: DateTime.utc(2026, 10, 1),
    endUtc: DateTime.utc(2026, 10, 9),
  );
  return AnalyticsReport(
    filter: filter,
    plannedMinutes: 120,
    actualMinutes: 90,
    completionRate: const RatioMetric(numerator: 3, denominator: 4),
    onTimeCompletionRate: const RatioMetric(numerator: 2, denominator: 3),
    overdueRate: const RatioMetric(numerator: 1, denominator: 4),
    estimateVariance: const RatioMetric(numerator: -30, denominator: 120),
    lifeQuota: const LifeQuotaMetric(
      targetMinutes: 360,
      plannedMinutes: 30,
      actualMinutes: 30,
    ),
    domainDistribution: const [
      DomainTimeMetric(
        id: 'study',
        label: '学业',
        plannedMinutes: 90,
        actualMinutes: 60,
      ),
      DomainTimeMetric(
        id: 'life',
        label: '生活',
        plannedMinutes: 30,
        actualMinutes: 30,
      ),
    ],
    trend: [
      DailyTimeMetric(
        dayUtc: DateTime.utc(2026, 10, 1),
        plannedMinutes: 120,
        actualMinutes: 90,
      ),
    ],
    commonInterruptions: const [RankedMetric('phone', 2)],
    replanReasons: const [RankedMetric('overrun', 1)],
    suggestionBehavior: const SuggestionBehaviorMetric(
      accepted: 2,
      modified: 1,
      rejected: 1,
    ),
  );
}

/// 计划块为 0、但**实际投入不为 0** 的报告。
///
/// 用来验证「领域时间分配」矩阵的口径：它只算计划块，所以这份报告必须走空状态。若实现里误用了
/// `actualMinutes`，空状态断言会立刻失败——这正是用户明确要求"不需要考虑实际投入"的那条。
AnalyticsReport _reportWithoutPlannedBlocks() {
  final base = _report();
  return AnalyticsReport(
    filter: base.filter,
    plannedMinutes: 0,
    actualMinutes: base.actualMinutes,
    completionRate: base.completionRate,
    onTimeCompletionRate: base.onTimeCompletionRate,
    overdueRate: base.overdueRate,
    estimateVariance: base.estimateVariance,
    lifeQuota: base.lifeQuota,
    domainDistribution: [
      for (final metric in base.domainDistribution)
        DomainTimeMetric(
          id: metric.id,
          label: metric.label,
          plannedMinutes: 0,
          actualMinutes: metric.actualMinutes,
        ),
    ],
    trend: base.trend,
    commonInterruptions: base.commonInterruptions,
    replanReasons: base.replanReasons,
    energyPeriods: base.energyPeriods,
    suggestionBehavior: base.suggestionBehavior,
  );
}

final class _AnalyticsQueryFake implements AnalyticsQuery {
  _AnalyticsQueryFake(this.report);
  final AnalyticsReport report;
  final filters = <AnalyticsFilter>[];

  @override
  Future<AnalyticsReport> query(AnalyticsFilter filter) async {
    filters.add(filter);
    return AnalyticsReport(
      filter: filter,
      plannedMinutes: report.plannedMinutes,
      actualMinutes: report.actualMinutes,
      completionRate: report.completionRate,
      onTimeCompletionRate: report.onTimeCompletionRate,
      overdueRate: report.overdueRate,
      estimateVariance: report.estimateVariance,
      lifeQuota: report.lifeQuota,
      domainDistribution: report.domainDistribution,
      trend: report.trend,
      commonInterruptions: report.commonInterruptions,
      replanReasons: report.replanReasons,
      suggestionBehavior: report.suggestionBehavior,
    );
  }
}

/// 范围按钮一律按 key 找：新增的「领域时间分配」矩阵表头里也有"上周／本周／本月"这几个字，
/// 按文本查找会命中多个控件，点击因此不再唯一。
Key _rangeKey(String label) => switch (label) {
  '今天' => const Key('analytics-range-today'),
  '本周' => const Key('analytics-range-week'),
  '本月' => const Key('analytics-range-month'),
  _ => const Key('analytics-range-custom'),
};
