// R1 的统计侧入口：按标签筛选（FR-STAT-02）。
//
// 数据层此前从不填充标签，因此任何非空标签筛选都会静默返回空集（见 analytics_dao_test）；
// 这里验证的是界面真的把标签放进了查询条件，并且**换时间范围不会把标签丢掉**——那是一个
// 只有把两处过滤条件分开写才会出现的缺陷：用户看起来标签仍然选中，实际查询已经不带了。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/features/analytics/analytics_page.dart';

void main() {
  Future<_AnalyticsQueryFake> pump(
    WidgetTester tester, {
    required Set<String> availableTags,
    bool withTagSource = true,
  }) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final query = _AnalyticsQueryFake();
    await tester.pumpWidget(
      MaterialApp(
        home: AnalyticsPage(
          analytics: query,
          nowUtc: DateTime.utc(2026, 10, 8, 8),
          zones: TimeZoneDatabase(),
          timeZoneId: 'Asia/Shanghai',
          loadTagNames: withTagSource ? () async => availableTags : null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return query;
  }

  testWidgets('勾选标签会进入查询条件，多选同时保留', (tester) async {
    final query = await pump(tester, availableTags: {'论文', '深度工作'});

    // 初始查询不带任何标签。
    expect(query.filters.first.tags, isEmpty);

    await tester.tap(find.byKey(const Key('analytics-tag-论文')));
    await tester.pumpAndSettle();
    expect(query.filters.last.tags, {'论文'});

    await tester.tap(find.byKey(const Key('analytics-tag-深度工作')));
    await tester.pumpAndSettle();
    // 交集语义：两个都在筛选条件里，而不是互相替换。
    expect(query.filters.last.tags, {'论文', '深度工作'});
  });

  testWidgets('切换时间范围不会丢掉已选标签', (tester) async {
    final query = await pump(tester, availableTags: {'论文'});

    await tester.tap(find.byKey(const Key('analytics-tag-论文')));
    await tester.pumpAndSettle();
    expect(query.filters.last.tags, {'论文'});

    await tester.tap(find.byKey(const Key('analytics-range-month')));
    await tester.pumpAndSettle();

    expect(query.filters.last.tags, {'论文'});
    // **本地日界**（与 `analytics_page_test.dart` 同一条更正）：东八区下 10 月从
    // 09-30T16:00Z 开始，而不再是 UTC 的 10-01T00:00Z。
    final zonesForRange = TimeZoneDatabase();
    expect(
      query.filters.last.startUtc,
      zonesForRange.localMidnightToUtc(DateTime(2026, 10), 'Asia/Shanghai'),
    );
    expect(
      query.filters.last.endUtc,
      zonesForRange.localMidnightToUtc(DateTime(2026, 11), 'Asia/Shanghai'),
    );
  });

  testWidgets('可以清除标签筛选，且时间范围保持不变', (tester) async {
    final query = await pump(tester, availableTags: {'论文'});

    await tester.tap(find.byKey(const Key('analytics-tag-论文')));
    await tester.pumpAndSettle();
    final range = query.filters.last;

    await tester.tap(find.byKey(const Key('analytics-clear-tags')));
    await tester.pumpAndSettle();

    expect(query.filters.last.tags, isEmpty);
    expect(query.filters.last.startUtc, range.startUtc);
    expect(query.filters.last.endUtc, range.endUtc);
    // 没有选中项时不再显示清除按钮。
    expect(find.byKey(const Key('analytics-clear-tags')), findsNothing);
  });

  testWidgets('尚无标签时说明原因与下一步，而不是给一块空白', (tester) async {
    await pump(tester, availableTags: const {});

    expect(find.text('按标签筛选'), findsOneWidget);
    expect(find.textContaining('尚无标签'), findsOneWidget);
  });

  testWidgets('未注入标签来源时不显示标签筛选', (tester) async {
    await pump(tester, availableTags: {'论文'}, withTagSource: false);

    expect(find.text('按标签筛选'), findsNothing);
    expect(find.byKey(const Key('analytics-tag-论文')), findsNothing);
  });
}

final class _AnalyticsQueryFake implements AnalyticsQuery {
  final filters = <AnalyticsFilter>[];

  @override
  Future<AnalyticsReport> query(AnalyticsFilter filter) async {
    filters.add(filter);
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
}
