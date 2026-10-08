import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/design/planner_glass.dart';
import 'package:personal_planner/design/planner_theme.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    bool reduceMotion = false,
    PlannerMaterialMode mode = PlannerMaterialMode.liquid,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PlannerTheme.dark(glassMode: mode),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion),
          child: PlannerBackdrop(child: child!),
        ),
        home: const Scaffold(
          body: Row(
            children: [
              Expanded(child: PlannerGlassSurface(child: SizedBox.expand())),
              Expanded(child: PlannerGlassSurface(child: SizedBox.expand())),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('跨越不同玻璃面板时全局唯一高光仍跟随指针，背景不挡住内容', (tester) async {
    await pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(100, 100));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(220, 180));
    await tester.pumpAndSettle();
    var light = tester.widget<AnimatedPositioned>(
      find.byKey(const Key('app-pointer-highlight')),
    );
    expect(light.left, -60);
    expect(light.top, -100);
    await mouse.moveTo(const Offset(650, 350));
    await tester.pumpAndSettle();
    light = tester.widget<AnimatedPositioned>(
      find.byKey(const Key('app-pointer-highlight')),
    );
    expect(light.left, 370);
    expect(light.top, 70);
    expect(find.byKey(const Key('liquid-specular-highlight')), findsNothing);
    expect(find.byKey(const Key('liquid-refraction-edge')), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果时指针移动不改变背景高光位置', (tester) async {
    await pump(tester, reduceMotion: true);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(100, 100));
    addTearDown(mouse.removePointer);
    final before = tester.widget<AnimatedPositioned>(
      find.byKey(const Key('app-pointer-highlight')),
    );
    await mouse.moveTo(const Offset(650, 350));
    await tester.pumpAndSettle();
    final after = tester.widget<AnimatedPositioned>(
      find.byKey(const Key('app-pointer-highlight')),
    );
    expect(after.left, before.left);
    expect(after.top, before.top);
  });

  testWidgets('减少动态效果时高光**过渡时长为零**（不是"位置没变"而已）', (tester) async {
    // 路线图 §6 要求"`prefers-reduced-motion` 生效时，关闭跟随指针高光的**平滑拖尾**"。
    // 只断言"位置没变"证明不了这一点：位置没变也可能是因为鼠标事件压根没接上。
    // 这里直接断言**过渡时长被压到 Duration.zero**，那才是"取消平滑拖尾"的机制本身。
    await pump(tester, reduceMotion: true);
    final light = tester.widget<AnimatedPositioned>(
      find.byKey(const Key('app-pointer-highlight')),
    );
    expect(light.duration, Duration.zero, reason: '减弱动画时高光不应再做平滑过渡');
  });

  testWidgets('未开启减少动态效果时高光仍有正常过渡时长（对照）', (tester) async {
    // 上一条如果没有这条对照，可能只是"时长恒为 0"这个 bug 的另一种写法。
    await pump(tester, reduceMotion: false);
    final light = tester.widget<AnimatedPositioned>(
      find.byKey(const Key('app-pointer-highlight')),
    );
    expect(light.duration, isNot(Duration.zero));
    expect(light.duration, greaterThan(Duration.zero));
  });

  testWidgets('无玻璃模式不绘制背景指针高光', (tester) async {
    await pump(tester, mode: PlannerMaterialMode.off);
    expect(find.byKey(const Key('app-pointer-highlight')), findsNothing);
  });
}
