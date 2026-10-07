// 2026-10-06 统计复盘改版的页面侧：图型可选、休息三卡、领域覆盖缺口。
//
// 用户的三条要求在这里被钉住：
// ① "各个统计的图表类型可以由我来选择" —— 切换要改图、且要写回设置；
// ② "有没有好好休息" —— 休息时长/作息规律性/工作休息比例三张卡都渲染；
// ③ "我规划得合不合理" —— 零占用的领域要被点名。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/chart_kind.dart';
import 'package:personal_planner/features/analytics/analytics_page.dart';
import 'package:personal_planner/features/analytics/chart_view.dart';

final class _Query implements AnalyticsQuery {
  _Query(this.report);
  final AnalyticsReport report;

  @override
  Future<AnalyticsReport> query(AnalyticsFilter filter) async => report;
}

AnalyticsReport _report() => AnalyticsReport(
  filter: AnalyticsFilter(
    startUtc: DateTime.utc(2026, 10, 4, 16),
    endUtc: DateTime.utc(2026, 10, 11, 16),
  ),
  plannedMinutes: 120,
  actualMinutes: 0,
  completionRate: const RatioMetric(numerator: 3, denominator: 4),
  onTimeCompletionRate: const RatioMetric(numerator: 2, denominator: 3),
  overdueRate: const RatioMetric(numerator: 1, denominator: 4),
  estimateVariance: const RatioMetric(numerator: 0, denominator: 0),
  lifeQuota: const LifeQuotaMetric(
    targetMinutes: 0,
    plannedMinutes: 0,
    actualMinutes: 0,
  ),
  domainDistribution: const [
    DomainTimeMetric(
      id: 'study',
      label: '学业',
      plannedMinutes: 60,
      actualMinutes: 0,
      fixedMinutes: 600,
    ),
    DomainTimeMetric(
      id: 'life',
      label: '生活',
      plannedMinutes: 60,
      actualMinutes: 0,
      fixedMinutes: 0,
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
  restSummary: const RestSummaryMetric(
    windows: [
      RestWindowMetric(label: '睡眠', minutes: 3360, invadedMinutes: 60),
      RestWindowMetric(label: '午餐', minutes: 420, invadedMinutes: 0),
    ],
    days: 7,
  ),
  workRest: const WorkRestMetric(
    workMinutes: 600,
    lifeMinutes: 60,
    restMinutes: 3300,
    idleMinutes: 6120,
  ),
  routine: RoutineMetric(
    perDay: [
      DailyRoutineMetric(
        localDate: DateTime.utc(2026, 10, 5),
        firstMinute: 480,
        lastMinute: 1240,
      ),
      DailyRoutineMetric(
        localDate: DateTime.utc(2026, 10, 6),
        firstMinute: 540,
        lastMinute: 1300,
      ),
    ],
  ),
  areaCoverage: const AreaCoverageMetric(
    covered: ['学业'],
    uncovered: ['科研', '竞赛', '工作'],
    totalAreas: 5,
  ),
);

final class _Recorder {
  final List<(AnalyticsChartSlot, ChartKind)> saved = [];
}

Future<void> _pump(
  WidgetTester tester, {
  Map<AnalyticsChartSlot, ChartKind>? initial,
  _Recorder? recorder,
}) async {
  tester.view.physicalSize = const Size(1400, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: AnalyticsPage(
        analytics: _Query(_report()),
        nowUtc: DateTime.utc(2026, 10, 8, 8),
        zones: TimeZoneDatabase(),
        timeZoneId: 'Asia/Shanghai',
        loadChartKinds: initial == null ? null : () async => initial,
        saveChartKind: recorder == null
            ? null
            : (slot, kind) async => recorder.saved.add((slot, kind)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 某张卡片里当前渲染用的图型。
ChartKind _kindOf(WidgetTester tester, String cardKey) => tester
    .widget<AnalyticsChart>(
      find.descendant(
        of: find.byKey(Key(cardKey)),
        matching: find.byType(AnalyticsChart),
      ),
    )
    .kind;

void main() {
  testWidgets('未选过的卡片用该位置的默认类型', (tester) async {
    await _pump(tester);

    // 领域占比的默认是饼图（allowedKinds 的第一个）。
    expect(
      _kindOf(tester, 'analytics-area-share'),
      AnalyticsChartSlot.areaShare.defaultKind,
    );
    expect(_kindOf(tester, 'analytics-area-share'), ChartKind.pie);
    // 时间总计的默认是柱状图。
    expect(_kindOf(tester, 'analytics-period-total'), ChartKind.bar);
  });

  testWidgets('注入的已保存选择会生效', (tester) async {
    await _pump(
      tester,
      initial: const {
        AnalyticsChartSlot.areaShare: ChartKind.horizontalBar,
        AnalyticsChartSlot.restDuration: ChartKind.pie,
      },
    );

    expect(_kindOf(tester, 'analytics-area-share'), ChartKind.horizontalBar);
    expect(_kindOf(tester, 'analytics-rest-duration'), ChartKind.pie);
  });

  testWidgets('切换图型：立刻改图，并把选择写回设置', (tester) async {
    final recorder = _Recorder();
    await _pump(tester, recorder: recorder);

    expect(_kindOf(tester, 'analytics-area-share'), ChartKind.pie);

    await tester.tap(find.byKey(const Key('chart-kind-areaShare')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('条形图').last);
    await tester.pumpAndSettle();

    // 界面先改（哪怕持久化失败也不该"点了没反应"）。
    expect(_kindOf(tester, 'analytics-area-share'), ChartKind.horizontalBar);
    expect(recorder.saved, [
      (AnalyticsChartSlot.areaShare, ChartKind.horizontalBar),
    ]);
  });

  testWidgets('图型选择器只列出该位置允许的类型', (tester) async {
    await _pump(tester);

    await tester.tap(find.byKey(const Key('chart-kind-areaShare')));
    await tester.pumpAndSettle();

    // **只看弹出菜单里的项**，不要满页找"折线图"——作息规律性那张卡的默认类型就是折线图，
    // 它的选择器上正显示着这三个字，满页找会把它一起数进来（第一版就是这么写错的）。
    final items = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(PopupMenuItem<ChartKind>),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data)
        .toList();

    // 顺序即 allowedKinds 的顺序；折线图不在其中——"领域占比"是在比构成，画成折线会让人
    // 以为它在讲趋势。
    expect(items, ['饼图', '条形图', '柱状图']);
  });

  testWidgets('休息三张卡都渲染，且口径只看计划侧', (tester) async {
    await _pump(tester);

    expect(find.byKey(const Key('analytics-rest')), findsOneWidget);

    // A 休息时长：睡眠 3360 分钟（56 小时）、被占用 60 → 达成 98%。
    expect(find.byKey(const Key('analytics-rest-duration')), findsOneWidget);
    expect(find.textContaining('睡眠 56 小时'), findsOneWidget);
    expect(find.textContaining('达成 98%'), findsOneWidget);

    // D 工作与休息的比例。
    expect(find.byKey(const Key('analytics-work-rest')), findsOneWidget);
    expect(find.textContaining('休息（含生活）占'), findsOneWidget);

    // C 作息规律性：两天的开工相差 60 分钟、收工相差 60 分钟。
    expect(find.byKey(const Key('analytics-routine')), findsOneWidget);
    expect(find.textContaining('开工相差 1 小时'), findsOneWidget);
    expect(find.textContaining('08:00–20:40'), findsOneWidget);
  });

  testWidgets('领域覆盖缺口点名零占用的领域', (tester) async {
    await _pump(tester);

    expect(find.byKey(const Key('analytics-area-coverage')), findsOneWidget);
    expect(find.text('未排计划：科研、竞赛、工作'), findsOneWidget);
    expect(find.textContaining('一个计划块、一场固定日程都没有'), findsOneWidget);
  });

  testWidgets('领域占比的口径包含固定日程', (tester) async {
    await _pump(tester);

    // 学业：计划 60 + 固定日程 600 = 660；生活：60。脚注必须把两个来源分开写清楚，
    // 否则用户看到"学业 11 小时"会以为是任务排出来的。
    expect(find.textContaining('计划 60 分钟 + 固定日程 600 分钟'), findsOneWidget);
  });

  testWidgets('页面上不再出现计划/实际那组内容', (tester) async {
    await _pump(tester);

    expect(find.text('计划 120 分钟'), findsNothing);
    expect(find.text('实际 0 分钟'), findsNothing);
    expect(find.text('计划 / 实际'), findsNothing);
    expect(find.text('每日趋势'), findsNothing);
    // 旧的"精力时段完成效果""休息保护"两行也随实际投入一起移除。
    expect(find.textContaining('投入'), findsNothing);
    expect(find.textContaining('被专注占用'), findsNothing);
  });
}
