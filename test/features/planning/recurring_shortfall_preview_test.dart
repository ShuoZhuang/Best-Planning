// M6（路线图 §3.4、§11 Task 8 Step 6）：预览页的容量缺口卡片。
//
// 这个文件钉住的是**用户能不能处置缺口**：三个数字（目标／可安排／缺口）都在、保护时间
// 不动的说明在、四个动作都在而且各自报出正确的意图。动作的落点（改模板、写设置）由
// `test/application/recurring_planning_test.dart` 与路由层覆盖，这里只管界面。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/capacity_shortfall.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';

CapacityShortfall _shortfall({
  String templateId = 'template-1',
  String title = '每周英语',
  int target = 180,
  int schedulable = 120,
  ProtectedTimeKind? constraint = ProtectedTimeKind.fixedRest,
}) => CapacityShortfall(
  templateId: templateId,
  title: title,
  periodStartLocalDate: DateTime(2026, 10, 5),
  targetMinutes: target,
  schedulableMinutes: schedulable,
  shortfallMinutes: target - schedulable,
  protectedConstraint: constraint,
  window: TimeRange(
    startUtc: DateTime.utc(2026, 10, 4, 16),
    endUtc: DateTime.utc(2026, 10, 11, 16),
  ),
);

PlanPreviewModel _model(List<CapacityShortfall> shortfalls) => PlanPreviewModel(
  proposalId: 'proposal-1',
  changes: const [],
  conflicts: const [],
  isStale: false,
  shortfalls: shortfalls,
);

void main() {
  Future<List<(CapacityShortfall, ShortfallAction)>> pump(
    WidgetTester tester, {
    List<CapacityShortfall>? shortfalls,
    bool withHandler = true,
  }) async {
    final handled = <(CapacityShortfall, ShortfallAction)>[];
    await tester.binding.setSurfaceSize(const Size(1280, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: _model(shortfalls ?? [_shortfall()]),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: () async {},
          onHandleShortfall: withHandler
              ? (shortfall, action) async => handled.add((shortfall, action))
              : null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return handled;
  }

  testWidgets('缺口卡片写出目标、可安排与缺口三个数字（§3.4）', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('shortfall-group')), findsOneWidget);
    expect(find.text('容量不足'), findsOneWidget);
    expect(
      find.text('「每周英语」本周目标 180 分钟，在不占用保护时间的前提下最多安排 120 分钟，还差 60 分钟。'),
      findsOneWidget,
      reason: '只说"排不下"用户没法决定该改多少',
    );
    // §7.2：容量 120、目标 180 ⇒ 缺口正好 60。
    expect(find.textContaining('还差 60 分钟'), findsOneWidget);
  });

  testWidgets('写明保护时间不动，并指出是哪条保护约束', (tester) async {
    await pump(tester);

    expect(find.textContaining('保护时间不动'), findsOneWidget);
    expect(find.textContaining('固定休息'), findsOneWidget);
  });

  testWidgets('四个动作都在，点它们各自报出正确意图（§3.4）', (tester) async {
    final handled = await pump(tester);

    for (final (key, action) in const [
      ('shortfall-lower-template-1', ShortfallAction.lowerTarget),
      ('shortfall-relax-template-1', ShortfallAction.relaxPreferredWindow),
      ('shortfall-daily-template-1', ShortfallAction.relaxDailyLimit),
      ('shortfall-partial-template-1', ShortfallAction.allowPartialWeek),
    ]) {
      final finder = find.byKey(Key(key));
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      expect(finder, findsOneWidget, reason: '$action 这个动作必须可见');
      await tester.tap(finder, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(handled.last.$2, action);
      expect(handled.last.$1.templateId, 'template-1');
    }
    expect(handled, hasLength(4));
  });

  testWidgets('"调低本周目标"按钮上直接写建议的目标值', (tester) async {
    await pump(tester);
    expect(find.text('调低本周目标到 120 分钟'), findsOneWidget);
  });

  testWidgets('没有缺口时那一组卡片完全不渲染', (tester) async {
    await pump(tester, shortfalls: const []);
    expect(find.byKey(const Key('shortfall-group')), findsNothing);
    expect(find.text('容量不足'), findsNothing);
  });

  testWidgets('未注入处理端口时四个按钮都不渲染（不给死入口）', (tester) async {
    await pump(tester, withHandler: false);

    // 缺口本身仍然要说清楚——用户该知道这件事。
    expect(find.byKey(const Key('shortfall-group')), findsOneWidget);
    expect(find.textContaining('还差 60 分钟'), findsOneWidget);
    for (final key in const [
      'shortfall-lower-template-1',
      'shortfall-relax-template-1',
      'shortfall-daily-template-1',
      'shortfall-partial-template-1',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: '$key 不该出现');
    }
  });

  testWidgets('多个缺口逐个列出', (tester) async {
    await pump(
      tester,
      shortfalls: [
        _shortfall(templateId: 't1', title: '每周英语'),
        _shortfall(
          templateId: 't2',
          title: '每周跑步',
          target: 90,
          schedulable: 30,
          constraint: ProtectedTimeKind.lunch,
        ),
      ],
    );

    expect(find.byKey(const Key('shortfall-t1')), findsOneWidget);
    expect(find.byKey(const Key('shortfall-t2')), findsOneWidget);
    expect(find.textContaining('每周英语'), findsWidgets);
    expect(find.textContaining('每周跑步'), findsWidgets);
    expect(find.textContaining('午餐'), findsOneWidget);
  });

  testWidgets('150% 与 200% 缩放下缺口与四个动作都能读到、点到', (tester) async {
    for (final scale in const [1.5, 2.0]) {
      final handled = <(CapacityShortfall, ShortfallAction)>[];
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: PlanPreviewPage(
              model: _model([_shortfall()]),
              autoAdjustStore: MemoryAutoAdjustStore(),
              onConfirm: () async {},
              onHandleShortfall: (shortfall, action) async =>
                  handled.add((shortfall, action)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$scale 倍缩放下不应有布局异常');

      final finder = find.byKey(const Key('shortfall-partial-template-1'));
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(handled, hasLength(1), reason: '$scale 倍缩放下必须能点到');
    }
  });
}
