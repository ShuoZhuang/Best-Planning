// M6（路线图 §11 Task 7 Step 1）：新建入口的**四条去向**。
//
// 这个文件只回答"新建时用户能不能分清要做哪一类"。它刻意不挂真实路由：页面拿的是注入的
// 回调，因此这里断言的是"点了哪一张卡就报哪一类"——那正是路由层唯一需要知道的事。
// 真实路由的接线由 `test/app/recurring_task_route_test.dart` 覆盖。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/features/tasks/task_type_chooser.dart';

void main() {
  Future<List<PlannerNewItemKind>> pump(
    WidgetTester tester, {
    bool Function(PlannerNewItemKind kind)? isAvailable,
    VoidCallback? onCancel,
  }) async {
    final selected = <PlannerNewItemKind>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskTypeChooserPage(
            onSelect: selected.add,
            isAvailable: isAvailable,
            onCancel: onCancel,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return selected;
  }

  testWidgets('四类去向都出现，且各有清楚的名字', (tester) async {
    await pump(tester);

    for (final (key, label) in const [
      ('new-type-task', '普通任务'),
      ('new-type-recurring', '周期目标'),
      ('new-type-fixed-event', '固定日程'),
      ('new-type-protected-time', '保护时间'),
    ]) {
      expect(
        find.byKey(Key(key)),
        findsOneWidget,
        reason: '§11 Task 7 Step 1：新建入口要有「$label」这条去向',
      );
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('周期目标那一张必须写明"具体做在哪天由排程决定"', (tester) async {
    await pump(tester);

    // 这正是它与普通任务的区别：用户不该以为要自己挑时间。
    expect(find.textContaining('由排程决定'), findsOneWidget);
    expect(find.textContaining('每周'), findsWidgets);
  });

  testWidgets('保护时间写明"排程绝不会占用它"', (tester) async {
    await pump(tester);
    expect(find.textContaining('绝不会占用'), findsOneWidget);
  });

  testWidgets('点哪一张卡就报哪一类', (tester) async {
    final selected = await pump(tester);

    await tester.tap(find.byKey(const Key('new-type-recurring')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-type-fixed-event')));
    await tester.pumpAndSettle();

    expect(selected, [
      PlannerNewItemKind.recurringGoal,
      PlannerNewItemKind.fixedEvent,
    ]);
  });

  testWidgets('不可达的去向不渲染那张卡（不给死入口）', (tester) async {
    await pump(
      tester,
      isAvailable: (kind) => kind != PlannerNewItemKind.recurringGoal,
    );

    expect(find.byKey(const Key('new-type-recurring')), findsNothing);
    expect(find.byKey(const Key('new-type-task')), findsOneWidget);
    expect(find.byKey(const Key('new-type-fixed-event')), findsOneWidget);
    expect(find.byKey(const Key('new-type-protected-time')), findsOneWidget);
  });

  testWidgets('返回按钮只在注入了回调时出现', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('new-type-cancel')), findsNothing);

    var returned = 0;
    await pump(tester, onCancel: () => returned++);
    // **必须先滚动到它**：1.8.0 起选择器分了组、内容比一屏高，底部那个返回按钮在
    // 1280×720 下落在视口外。这不是测试的将就——正是因此真实返回动作改到了顶部
    // （`new-item-back`），下面那条用例钉的就是它。
    final cancel = find.byKey(const Key('new-type-cancel'));
    await tester.scrollUntilVisible(cancel, 200);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(returned, 1);
  });

  testWidgets('顶部返回按钮始终在视口内，不需要滚动就能点到', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskTypeChooserPage(onSelect: (_) {}, onBack: () => backs++),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final back = find.byKey(const Key('new-item-back'));
    expect(back, findsOneWidget);
    // 720 高（外壳默认窗口尺寸）下它必须在视口内，否则"始终可达"就是空话。
    expect(
      tester.getRect(back).bottom,
      lessThanOrEqualTo(720.0),
      reason: '顶部返回按钮必须落在视口内',
    );
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(backs, 1);
  });

  testWidgets('150% 与 200% 文字缩放下四张卡都能看到并点到', (tester) async {
    for (final scale in const [1.5, 2.0]) {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final selected = <PlannerNewItemKind>[];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(body: TaskTypeChooserPage(onSelect: selected.add)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '$scale 倍缩放下不应有布局异常');
      for (final key in const [
        'new-type-task',
        'new-type-recurring',
        'new-type-fixed-event',
        'new-type-protected-time',
      ]) {
        final finder = find.byKey(Key(key));
        expect(finder, findsOneWidget);
        await tester.scrollUntilVisible(finder, 120);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }
      expect(selected, hasLength(4), reason: '$scale 倍缩放下四张卡都要能点到');
    }
  });
}
