import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/features/analytics/analytics_page.dart';

void main() {
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

    expect(query.filters.last.startUtc, DateTime.utc(2026, 10, 1));
    expect(query.filters.last.endUtc, DateTime.utc(2026, 11, 1));
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
