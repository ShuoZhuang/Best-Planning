// §11 Task 12 Step 3：空状态要给**下一步操作**，而不只是解释现状。
//
// 这一步此前登记为"未做"，理由是五个落点里有些页面还没落地。现在它们都落地了，因此补齐：
//
//   · 无统计 / 无确认计划 → 「计划总时长 0 分钟」那张卡给"去生成计划"
//   · 无保护时间        → 「保护时间达成率 未设置」那张卡给"去设置保护时间"
//   · 周期未安排        → 缺口卡片已经给出四个处理动作（`recurring_shortfall_preview_test` 覆盖）
//   · 无更新            → 更新页本身就有"立即检查"按钮，并写明"已经是最新版本"
//   · 数据不足          → 来源明细给出解释（"这个范围内还没有已确认的计划块"）
//
// 本文件钉住前两条：**按钮出现**、**点了真的回调**、以及**端口为空时按钮不渲染**。
//
// 最后一条最重要：一个点了没反应的入口比没有入口更糟——用户会以为功能坏了，而事实是这个装配
// 没接对应服务。这与这个应用其它端口（`openBreakdown`、`onOpenRecurringGoals`）同一口径。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/features/analytics/analytics_overview.dart';

/// 一份报告。参数化到只需要两个开关：**有没有计划**、**有没有保护时间**。
///
/// `AnalyticsReport` 的必填字段很多，因此这里给全默认值再按需覆盖，而不是每条用例各写一遍
/// 二十个参数——那样每条用例的重点会被淹没在样板里。
AnalyticsReport _report({
  int plannedMinutes = 0,
  RestSummaryMetric? restSummary,
}) {
  final filter = AnalyticsFilter(
    startUtc: DateTime.utc(2026, 10, 4, 16),
    endUtc: DateTime.utc(2026, 10, 11, 16),
  );
  return AnalyticsReport(
    filter: filter,
    plannedMinutes: plannedMinutes,
    actualMinutes: 0,
    completionRate: const RatioMetric(numerator: 0, denominator: 0),
    onTimeCompletionRate: const RatioMetric(numerator: 0, denominator: 0),
    overdueRate: const RatioMetric(numerator: 0, denominator: 0),
    estimateVariance: const RatioMetric(numerator: 0, denominator: 0),
    lifeQuota: const LifeQuotaMetric(
      targetMinutes: 0,
      plannedMinutes: 0,
      actualMinutes: 0,
    ),
    domainDistribution: plannedMinutes == 0
        ? const []
        : [
            DomainTimeMetric(
              id: 'study',
              label: '学业',
              plannedMinutes: plannedMinutes,
              actualMinutes: 0,
            ),
          ],
    trend: const [],
    commonInterruptions: const [],
    replanReasons: const [],
    energyPeriods: const [],
    suggestionBehavior: const SuggestionBehaviorMetric(
      accepted: 0,
      modified: 0,
      rejected: 0,
    ),
    restSummary: restSummary,
  );
}

const _sleep = RestSummaryMetric(
  windows: [RestWindowMetric(label: '睡眠', minutes: 3360, invadedMinutes: 0)],
  days: 7,
);

Future<void> _pump(
  WidgetTester tester,
  AnalyticsReport report, {
  VoidCallback? onGeneratePlan,
  VoidCallback? onOpenRestRules,
}) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnalyticsOverview(
            report: report,
            onGeneratePlan: onGeneratePlan,
            onOpenRestRules: onOpenRestRules,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('无计划 ⇒ 给"去生成计划"', () {
    testWidgets('按钮出现，且点了真的回调', (tester) async {
      var taps = 0;
      await _pump(tester, _report(), onGeneratePlan: () => taps++);

      expect(find.text('去生成计划'), findsOneWidget);
      await tester.tap(find.text('去生成计划'));
      await tester.pumpAndSettle();
      expect(taps, 1, reason: '点了没反应等于死入口');
    });

    testWidgets('**端口为空时不渲染按钮**（没装配排程服务就没有可去处）', (tester) async {
      await _pump(tester, _report());

      expect(find.text('去生成计划'), findsNothing);
      // 说明本身仍在——用户至少要知道为什么是 0。
      expect(find.textContaining('还没有已确认的计划块'), findsOneWidget);
    });

    testWidgets('有计划时**不**出现按钮（它只在空状态里是下一步）', (tester) async {
      await _pump(tester, _report(plannedMinutes: 600), onGeneratePlan: () {});

      expect(find.text('去生成计划'), findsNothing);
    });
  });

  group('无保护时间 ⇒ 给"去设置保护时间"', () {
    testWidgets('按钮出现，且点了真的回调', (tester) async {
      var taps = 0;
      await _pump(tester, _report(), onOpenRestRules: () => taps++);

      expect(find.text('去设置保护时间'), findsOneWidget);
      await tester.tap(find.text('去设置保护时间'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('端口为空时不渲染按钮', (tester) async {
      await _pump(tester, _report());

      expect(find.text('去设置保护时间'), findsNothing);
      expect(find.textContaining('还没有设置睡眠或用餐保护时间'), findsOneWidget);
    });

    testWidgets('有保护时间时不出现按钮', (tester) async {
      await _pump(tester, _report(restSummary: _sleep), onOpenRestRules: () {});

      expect(find.text('去设置保护时间'), findsNothing);
    });
  });
}
