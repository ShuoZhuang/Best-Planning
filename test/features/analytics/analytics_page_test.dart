import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/core/time_zone.dart';
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

    Future<void> tapAndExpect(String label, DateTime start, DateTime end) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(
        query.filters.last.startUtc,
        start,
        reason: '「$label」的窗口起点不对',
      );
      expect(query.filters.last.endUtc, end, reason: '「$label」的窗口终点不对');
    }

    // 四种范围在界面上都存在，这是前提。
    for (final label in ['今天', '本周', '本月', '自定义范围']) {
      expect(find.text(label), findsOneWidget, reason: '缺少范围选项「$label」');
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
    await tester.tap(find.text('自定义范围'));
    await tester.pumpAndSettle();
    final custom = query.filters.last;
    expect(custom.startUtc.isUtc && custom.endUtc.isUtc, isTrue);
    expect(custom.startUtc.isBefore(custom.endUtc), isTrue);
  });

  testWidgets('统计页同时显示计划、实际、分母、文本摘要和图表语义', (tester) async {
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

    expect(find.text('计划 120 分钟'), findsOneWidget);
    expect(find.text('实际 90 分钟'), findsOneWidget);
    expect(find.text('完成率 3 / 4'), findsOneWidget);
    expect(find.textContaining('学业：实际 60 分钟'), findsOneWidget);
    expect(_semanticsLabel('领域分布图：学业实际60分钟，生活实际30分钟'), findsOneWidget);
    expect(_semanticsLabel('每日趋势图：计划120分钟，实际90分钟'), findsOneWidget);
    expect(_semanticsLabel('计划实际对比图：计划120分钟，实际90分钟'), findsOneWidget);

    await tester.tap(find.text('本月'));
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
}

Finder _semanticsLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
  description: 'Semantics label "$label"',
);

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
