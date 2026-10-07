// 新手教程：分步前后翻、跳过、以及"图真的在仓库里"。
//
// 用户 2026-10-07 的要求是"做一个软件新手教程出来，这样用户第一次使用的时候可以跟着图片&
// 其他引导来走一遍软件的功能"。因此这里除了交互，还钉住两件容易烂掉的事：
// ① 缺图不能让教程崩（打包漏了资源时给可读的替代文案，而不是红屏）；
// ② 步骤里写的截图**必须真的存在**——否则"加了步骤忘了截图"要等到用户第一次打开才发现。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_steps.dart';

const _steps = [
  TutorialStep(
    title: '第一步',
    body: '说明一',
    assetPath: 'assets/tutorial/nope-1.png',
  ),
  TutorialStep(
    title: '第二步',
    body: '说明二',
    assetPath: 'assets/tutorial/nope-2.png',
  ),
  TutorialStep(title: '第三步', body: '说明三'),
];

Future<void> _pump(
  WidgetTester tester, {
  required VoidCallback onComplete,
  List<TutorialStep> steps = _steps,
}) => tester.pumpWidget(
  MaterialApp(
    home: TutorialPage(onComplete: onComplete, steps: steps),
  ),
);

void main() {
  testWidgets('从第一步开始，显示进度与说明，且没有"上一步"可点', (tester) async {
    await _pump(tester, onComplete: () {});
    await tester.pumpAndSettle();

    expect(find.text('第 1 / 3 步'), findsOneWidget);
    expect(find.text('说明一'), findsOneWidget);
    expect(find.text('第一步'), findsWidgets);
    // 第一步的"上一步"是**禁用**而不是消失：消失会让"下一步"的位置跳一下。
    final previous = tester.widget<OutlinedButton>(
      find.byKey(const Key('tutorial-previous')),
    );
    expect(previous.onPressed, isNull);
  });

  testWidgets('下一步前进、上一步后退', (tester) async {
    await _pump(tester, onComplete: () {});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 3 步'), findsOneWidget);
    expect(find.text('说明二'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('tutorial-previous')))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('tutorial-previous')));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 3 步'), findsOneWidget);
  });

  testWidgets('最后一步的按钮是"开始使用"，点了就结束', (tester) async {
    var completed = 0;
    await _pump(tester, onComplete: () => completed++);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();

    expect(find.text('第 3 / 3 步'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);
    expect(find.text('跳过'), findsNothing, reason: '最后一步"完成"与"跳过"是同一件事');

    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
    expect(completed, 1);
  });

  testWidgets('中途"跳过"同样算结束', (tester) async {
    var completed = 0;
    await _pump(tester, onComplete: () => completed++);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tutorial-skip')));
    await tester.pumpAndSettle();
    expect(completed, 1);
  });

  testWidgets('缺图时给可读文案，而不是崩或红屏', (tester) async {
    await _pump(tester, onComplete: () {});
    await tester.pumpAndSettle();

    // 测试环境里资源包里没有这些图，`Image.asset` 会走 errorBuilder。
    expect(find.textContaining('这一步的截图没有打包进来'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('步骤列表为空时不崩，并给一条出得去的路', (tester) async {
    var completed = 0;
    await _pump(tester, onComplete: () => completed++, steps: const []);
    await tester.pumpAndSettle();

    expect(find.text('教程暂时没有内容。'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(completed, 1);
  });

  test('真实教程的每一步：标题与说明非空，截图文件确实存在', () {
    expect(
      tutorialSteps.length,
      greaterThanOrEqualTo(5),
      reason: '用户要的是"走一遍软件的功能"，两三步讲不完',
    );
    for (final step in tutorialSteps) {
      expect(step.title.trim(), isNotEmpty);
      expect(step.body.trim(), isNotEmpty);
      final asset = step.assetPath;
      if (asset == null) continue;
      expect(
        asset.startsWith('assets/tutorial/'),
        isTrue,
        reason: '教程截图统一放在 assets/tutorial/ 下（pubspec 也是按目录登记的）',
      );
      expect(
        File(asset).existsSync(),
        isTrue,
        reason:
            '步骤「${step.title}」写了 $asset，但仓库里没有这个文件——'
            '加了步骤却忘了截图，要等到用户第一次打开教程才会发现',
      );
    }
  });
}
