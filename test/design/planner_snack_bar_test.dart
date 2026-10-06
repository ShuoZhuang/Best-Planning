import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';

void main() {
  Future<void> pumpHost(
    WidgetTester tester, {
    required void Function(BuildContext context) onPressed,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => onPressed(context),
              child: const Text('触发'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('an actionable bubble still expires on its own', (tester) async {
    // Flutter defaults `SnackBar.persist` to true whenever an action is
    // present, which is exactly how the app ended up with bubbles that never
    // went away. This guards the explicit lifetime.
    await pumpHost(
      tester,
      onPressed: (context) => showPlannerMessage(
        context,
        message: '课表已导入',
        action: SnackBarAction(label: '撤销本次导入', onPressed: () {}),
      ),
    );

    await tester.tap(find.text('触发'));
    // The auto-dismiss timer is only armed once the entrance animation has
    // finished, so settle first and measure from there.
    await tester.pumpAndSettle();
    expect(find.text('课表已导入'), findsOneWidget);
    expect(find.text('撤销本次导入'), findsOneWidget);

    // Still there just before the actionable lifetime ends…
    await tester.pump(
      plannerActionableMessageDuration - const Duration(seconds: 1),
    );
    expect(find.text('课表已导入'), findsOneWidget);

    // …and gone shortly after it, with no user interaction at all.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('课表已导入'), findsNothing);
  });

  testWidgets('an ordinary bubble expires on its own', (tester) async {
    await pumpHost(
      tester,
      onPressed: (context) => showPlannerMessage(context, message: '计划已更新'),
    );

    await tester.tap(find.text('触发'));
    await tester.pumpAndSettle();
    expect(find.text('计划已更新'), findsOneWidget);

    await tester.pump(plannerMessageDuration + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('计划已更新'), findsNothing);
  });

  testWidgets('a raw actionable SnackBar outlives its duration', (
    tester,
  ) async {
    // Characterises the framework behaviour the helper exists for:
    // `snack_bar.dart` does `persist = persist ?? action != null`, so a plain
    // SnackBar carrying an action ignores its own duration. If Flutter ever
    // stops doing that, this test fails and the explicit `persist: false` in
    // [plannerSnackBar] can be reconsidered — it is never harmful.
    await pumpHost(
      tester,
      onPressed: (context) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: plannerMessageDuration,
          content: const Text('裸提示'),
          action: SnackBarAction(label: '按钮', onPressed: () {}),
        ),
      ),
    );

    await tester.tap(find.text('触发'));
    await tester.pumpAndSettle();
    expect(find.text('裸提示'), findsOneWidget);

    await tester.pump(plannerMessageDuration * 3);
    await tester.pumpAndSettle();
    expect(find.text('裸提示'), findsOneWidget);
  });

  testWidgets('the close control sits on the left and dismisses the bubble', (
    tester,
  ) async {
    await pumpHost(
      tester,
      onPressed: (context) => showPlannerMessage(
        context,
        message: '课表已导入',
        action: SnackBarAction(label: '撤销本次导入', onPressed: () {}),
      ),
    );

    await tester.tap(find.text('触发'));
    await tester.pumpAndSettle();

    final close = find.byKey(const Key('snack-bar-close'));
    expect(close, findsOneWidget);
    expect(
      tester.getCenter(close).dx,
      lessThan(tester.getCenter(find.text('课表已导入')).dx),
      reason: '关闭按钮必须在文字左侧',
    );
    expect(
      tester.getCenter(close).dx,
      lessThan(tester.getCenter(find.text('撤销本次导入')).dx),
    );

    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.text('课表已导入'), findsNothing);
  });
}
