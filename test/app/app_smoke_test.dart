import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';

void main() {
  testWidgets('主导航可在今日、任务和日历之间切换', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: PlannerApp()));
    await tester.pumpAndSettle();

    expect(find.text('今日'), findsWidgets);

    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    expect(find.text('任务'), findsWidgets);
    expect(find.text('任务清单'), findsOneWidget);

    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    expect(find.text('日历'), findsWidgets);
    expect(find.text('七日日历'), findsOneWidget);
  });
}
