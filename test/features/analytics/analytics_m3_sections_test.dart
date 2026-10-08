// M3（路线图 §3.1、§7.1 第 5/6 条、§11 Task 4）：统计复盘页的信息架构与来源明细。
//
// 这一组钉住的是**重构本身**，而不是某个数字算得对不对（那由 `analytics_service_test.dart` 与
// `analytics_review_metrics_test.dart` 负责）。具体三件事：
//
//   ① **四个页签**（时间分配／计划质量／休息与作息／调整记录），默认「时间分配」；
//   ② **首页四项摘要**（计划总时长／任务完成率／保护时间达成率／最需处理的问题）；
//   ③ **每一项都能打开来源明细**，且**没有来源时给解释、不给空列表**（§11 Task 4 Step 6）。
//
// 另有一条 §7.1 第 5 条的口径断言：空白时间**不能**叫"休息"。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/features/analytics/analytics_drilldown_sheet.dart';
import 'package:personal_planner/features/analytics/analytics_page.dart';

final class _Query implements AnalyticsQuery {
  _Query(this.report);
  final AnalyticsReport report;

  @override
  Future<AnalyticsReport> query(AnalyticsFilter filter) async => report;
}

AnalyticsReport _report({
  int studyMinutes = 1195,
  int lifeMinutes = 60,
  RatioMetric completion = const RatioMetric(numerator: 3, denominator: 4),
  RestSummaryMetric? rest = const RestSummaryMetric(
    windows: [
      RestWindowMetric(label: '睡眠', minutes: 3360, invadedMinutes: 0),
      RestWindowMetric(label: '午餐', minutes: 420, invadedMinutes: 60),
    ],
    days: 7,
  ),
  AreaCoverageMetric? coverage = const AreaCoverageMetric(
    covered: ['学业'],
    uncovered: ['科研'],
    totalAreas: 2,
  ),
  List<DomainTimeMetric>? domains,
}) {
  final filter = AnalyticsFilter(
    startUtc: DateTime.utc(2026, 10, 4, 16),
    endUtc: DateTime.utc(2026, 10, 11, 16),
  );
  return AnalyticsReport(
    filter: filter,
    plannedMinutes: studyMinutes + lifeMinutes,
    actualMinutes: 0,
    completionRate: completion,
    onTimeCompletionRate: const RatioMetric(numerator: 2, denominator: 3),
    overdueRate: const RatioMetric(numerator: 1, denominator: 4),
    estimateVariance: const RatioMetric(numerator: 0, denominator: 0),
    lifeQuota: const LifeQuotaMetric(
      targetMinutes: 0,
      plannedMinutes: 0,
      actualMinutes: 0,
    ),
    domainDistribution:
        domains ??
        [
          DomainTimeMetric(
            id: 'study',
            label: '学业',
            plannedMinutes: studyMinutes,
            actualMinutes: 0,
            storedColorArgb: 0xff2f86ff,
            sortOrder: 0,
          ),
          DomainTimeMetric(
            id: 'life',
            label: '生活',
            plannedMinutes: lifeMinutes,
            actualMinutes: 0,
            storedColorArgb: 0xff2ea44f,
            sortOrder: 1,
          ),
        ],
    trend: const [],
    commonInterruptions: const [RankedMetric('phone', 2)],
    replanReasons: const [RankedMetric('overrun', 1)],
    energyPeriods: const [],
    suggestionBehavior: const SuggestionBehaviorMetric(
      accepted: 1,
      modified: 0,
      rejected: 0,
    ),
    restSummary: rest,
    areaCoverage: coverage,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  AnalyticsReport? report,
  void Function(String title, String subtitle)? openBreakdown,
}) async {
  tester.view.physicalSize = const Size(1400, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: AnalyticsPage(
        analytics: _Query(report ?? _report()),
        nowUtc: DateTime.utc(2026, 10, 8, 8),
        zones: TimeZoneDatabase(),
        timeZoneId: 'Asia/Shanghai',
        openBreakdown: openBreakdown,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('M3 四个页签', () {
    testWidgets('四个页签都在，且默认停在「时间分配」', (tester) async {
      await _pump(tester);

      for (final (key, label) in [
        ('analytics-tab-time', '时间分配'),
        ('analytics-tab-quality', '计划质量'),
        ('analytics-tab-rest', '休息与作息'),
        ('analytics-tab-adjustments', '调整记录'),
      ]) {
        expect(
          find.byKey(Key(key)),
          findsOneWidget,
          reason: '§3.1 要求四个页签：缺少「$label」',
        );
      }

      // 默认页签「时间分配」：领域占比在。
      expect(find.byKey(const Key('analytics-area-share')), findsOneWidget);
      // 其余三页的内容**不该**同时出现——那说明页签只是装饰，内容还堆在一起。
      expect(
        find.byKey(const Key('analytics-plan-quality')),
        findsNothing,
        reason: '「时间分配」页签上不该同时渲染计划质量的内容',
      );
      expect(find.byKey(const Key('analytics-rest')), findsNothing);
      expect(find.byKey(const Key('analytics-evidence')), findsNothing);
    });

    testWidgets('切到「计划质量」只显示那一页的内容', (tester) async {
      await _pump(tester);

      await tester.tap(find.byKey(const Key('analytics-tab-quality')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('analytics-plan-quality')), findsOneWidget);
      expect(find.byKey(const Key('analytics-area-share')), findsNothing);
      expect(find.byKey(const Key('analytics-rest')), findsNothing);
    });

    testWidgets('切到「休息与作息」只显示休息三卡', (tester) async {
      await _pump(tester);

      await tester.tap(find.byKey(const Key('analytics-tab-rest')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('analytics-rest')), findsOneWidget);
      expect(find.byKey(const Key('analytics-area-share')), findsNothing);
    });

    testWidgets('切到「调整记录」显示中断与调整，且反馈也在这一页', (tester) async {
      await _pump(tester);

      await tester.tap(find.byKey(const Key('analytics-tab-adjustments')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('analytics-evidence')), findsOneWidget);
      expect(find.textContaining('常见中断'), findsWidgets);
      expect(find.byKey(const Key('analytics-area-share')), findsNothing);
    });
  });

  group('M3 首页四项摘要（§3.1）', () {
    testWidgets('四项摘要都在，且总时长不显示裸分钟（§7.1 第 3 条）', (tester) async {
      await _pump(tester);

      expect(find.byKey(const Key('analytics-overview')), findsOneWidget);
      for (final key in [
        'analytics-summary-planned',
        'analytics-summary-completion',
        'analytics-summary-rest',
        'analytics-summary-issue',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: '缺少摘要项 $key');
      }

      // 1195 + 60 = 1255 分钟 = 20 小时 55 分钟。**绝不允许出现 "1255 分钟"**：
      // §7.1 第 3 条举的例子就是这一类裸分钟（1195 必须写成 19 小时 55 分钟）。
      // 摘要卡一处 + 矩阵表若干处（表里也改成「小时 + 分钟」了），因此不限定个数。
      expect(find.text('20 小时 55 分钟'), findsWidgets);
      expect(
        find.text('1255 分钟'),
        findsNothing,
        reason: '§7.1 第 3 条：主图数值不显示裸分钟',
      );
    });

    testWidgets('完成率摘要同时写出分子与分母（§7.1 第 6 条）', (tester) async {
      await _pump(tester);

      final card = find.byKey(const Key('analytics-summary-completion'));
      expect(
        find.descendant(of: card, matching: find.text('75%')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.textContaining('完成 3 / ')),
        findsOneWidget,
        reason: '§7.1 第 6 条：所有比例显示分子与分母',
      );
    });

    testWidgets('分母为 0 时完成率写"暂无数据"，而不是 0%', (tester) async {
      await _pump(
        tester,
        report: _report(
          completion: const RatioMetric(numerator: 0, denominator: 0),
        ),
      );

      final card = find.byKey(const Key('analytics-summary-completion'));
      expect(
        find.descendant(of: card, matching: find.text('暂无数据')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('0%')),
        findsNothing,
      );
    });

    testWidgets('最需处理的问题：有未排计划的领域时点名它', (tester) async {
      await _pump(tester);

      final card = find.byKey(const Key('analytics-summary-issue'));
      expect(
        find.descendant(of: card, matching: find.text('未排计划：科研')),
        findsOneWidget,
      );
    });

    testWidgets('没有保护时间时达成率写"未设置"，而不是 0%', (tester) async {
      await _pump(tester, report: _report(rest: null));

      final card = find.byKey(const Key('analytics-summary-rest'));
      expect(
        find.descendant(of: card, matching: find.text('未设置')),
        findsOneWidget,
      );
      // 0% 会让用户以为"保护时间全被占了"，而实际是他还没设过保护时间——两件事。
      expect(
        find.descendant(of: card, matching: find.text('0%')),
        findsNothing,
      );
    });
  });

  group('M3 来源明细（§7.1 第 6 条、§11 Task 4）', () {
    testWidgets('点摘要能打开它的来源明细，且每行带分钟数', (tester) async {
      await _pump(tester);

      await tester.tap(find.byKey(const Key('analytics-summary-planned')));
      await tester.pumpAndSettle();

      expect(find.byType(AnalyticsBreakdownSheet), findsOneWidget);
      expect(find.text('计划总时长'), findsWidgets);
      // 两个领域各一行，且都写成"小时 + 分钟"。
      expect(find.text('学业'), findsWidgets);
      expect(find.text('19 小时 55 分钟'), findsWidgets);
      expect(find.text('1 小时'), findsWidgets);
    });

    testWidgets('明细的口径说明写明分子与分母', (tester) async {
      await _pump(tester);

      await tester.tap(find.byKey(const Key('analytics-summary-completion')));
      await tester.pumpAndSettle();

      expect(find.textContaining('完成 3 个 / 范围内到期或完成 4 个任务'), findsOneWidget);
    });

    testWidgets('没有来源时给解释，而不是一张空列表', (tester) async {
      await _pump(
        tester,
        report: _report(
          domains: const [
            DomainTimeMetric(
              id: 'study',
              label: '学业',
              plannedMinutes: 0,
              actualMinutes: 0,
            ),
          ],
        ),
      );

      await tester.tap(find.byKey(const Key('analytics-summary-planned')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('analytics-breakdown-empty')),
        findsOneWidget,
        reason: '§11 Task 4 Step 6：无来源时给出解释，不显示空列表',
      );
      expect(find.byKey(const Key('analytics-breakdown-rows')), findsNothing);
      expect(
        find.textContaining('生成计划或导入课表之后'),
        findsOneWidget,
        reason: '解释里要给出下一步，而不只是说"没有数据"',
      );
    });

    testWidgets('注入的明细端口优先（装配层可以用自己的面板）', (tester) async {
      final opened = <(String, String)>[];
      await _pump(
        tester,
        openBreakdown: (title, subtitle) => opened.add((title, subtitle)),
      );

      await tester.tap(find.byKey(const Key('analytics-summary-planned')));
      await tester.pumpAndSettle();

      expect(opened, hasLength(1));
      expect(opened.single.$1, '计划总时长');
      // 端口接管之后，内置面板不该同时弹出来。
      expect(find.byType(AnalyticsBreakdownSheet), findsNothing);
    });
  });

  group('M3 §7.1 第 5 条：空白时间不叫"休息"', () {
    testWidgets('四个页签的文字里没有"空着的休息"这类说法', (tester) async {
      await _pump(tester);

      for (final tab in [
        'analytics-tab-time',
        'analytics-tab-quality',
        'analytics-tab-rest',
        'analytics-tab-adjustments',
      ]) {
        await tester.tap(find.byKey(Key(tab)));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('空着的休息'),
          findsNothing,
          reason: '§7.1 第 5 条：空白时间必须叫"可用空闲"或"未安排"',
        );
      }
    });
  });
}
