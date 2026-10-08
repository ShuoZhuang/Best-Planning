// M8 引导首页（用户 2026-10-07 定案）。
//
// 用户原话：
//   引导首页继续提供：
//     [创建第一个任务]
//     [导入课表]
//     [了解主要界面]
//   如果用户**已经有任务**，文案改为「再创建一个任务」，**避免假装这是第一次使用**。
//
// **"已经有任务"的判据是本文件最容易做错的一处**：只看"还有未完成的"会漏掉
// "只用过、已经全部完成"的用户——他同样是老用户，却被叫做"创建**第一个**任务"。
// 因此判据是**存在过任何任务**（含已完成／已取消）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/features/onboarding/onboarding_home_page.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool hasExistingTasks,
    VoidCallback? onCreateTask,
    VoidCallback? onImportTimetable,
    VoidCallback? onLearnUi,
    VoidCallback? onSkip,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: OnboardingHomePage(
          hasExistingTasks: hasExistingTasks,
          onCreateTask: onCreateTask ?? () {},
          onImportTimetable: onImportTimetable ?? () {},
          onLearnUi: onLearnUi ?? () {},
          onSkip: onSkip,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('M8 没有任务时是「创建第一个任务」', (tester) async {
    await pump(tester, hasExistingTasks: false);

    expect(find.text('创建第一个任务'), findsOneWidget);
    expect(find.text('再创建一个任务'), findsNothing);
    expect(find.text('导入课表'), findsOneWidget);
    expect(find.text('了解主要界面'), findsOneWidget);
  });

  testWidgets('M8 已经有任务时改成「再创建一个任务」，不假装是第一次', (tester) async {
    await pump(tester, hasExistingTasks: true);

    expect(find.text('再创建一个任务'), findsOneWidget, reason: '老用户不该被告知"创建第一个任务"');
    expect(find.text('创建第一个任务'), findsNothing, reason: '两种文案不能同时存在');
  });

  testWidgets('M8 三个入口各自触发自己的回调（不是点了没反应）', (tester) async {
    var created = 0;
    var imported = 0;
    var learned = 0;
    await pump(
      tester,
      hasExistingTasks: false,
      onCreateTask: () => created++,
      onImportTimetable: () => imported++,
      onLearnUi: () => learned++,
    );

    await tester.tap(find.text('创建第一个任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入课表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('了解主要界面'));
    await tester.pumpAndSettle();

    expect(created, 1);
    expect(imported, 1);
    expect(learned, 1);
  });

  testWidgets('M8 装配了跳过时给「跳过引导」，点了触发回调', (tester) async {
    var skipped = 0;
    await pump(tester, hasExistingTasks: false, onSkip: () => skipped++);

    final skip = find.text('跳过引导');
    expect(skip, findsOneWidget);
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(skipped, 1);
  });

  testWidgets('M8 未装配跳过时不渲染该按钮（不留点了没反应的入口）', (tester) async {
    await pump(tester, hasExistingTasks: false, onSkip: null);
    expect(find.text('跳过引导'), findsNothing, reason: '与"未装配的入口不渲染"同一口径');
  });
}
