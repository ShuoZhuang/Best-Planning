// 日期／时间选择器右上角按钮必须在深色主题下看得见。
//
// 用户 2026-10-07 的原话是"自定义范围在选择统计范围的时候右上角的两个按钮不明显，容易被看不见"。
// 根因不在选择器，而在**全局** `textButtonTheme`：它把前景色设成 `PlannerPalette.textSecondary`
// （灰），而选择器的"取消／应用"正是 `TextButton`。因此这里同时钉住两件事：
// ① 基础主题**确实**是灰的（否则这条缺陷就不存在，测试也就没在测东西）；
// ② 选择器主题把它换成主文本色，且对比度达到 WCAG AA 的 4.5:1。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/design/planner_pickers.dart';
import 'package:personal_planner/design/planner_theme.dart';

double _linear(double channel) => channel <= 0.03928
    ? channel / 12.92
    : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color color) =>
    0.2126 * _linear(color.r) +
    0.7152 * _linear(color.g) +
    0.0722 * _linear(color.b);

double _contrast(Color a, Color b) {
  final first = _luminance(a);
  final second = _luminance(b);
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + 0.05) / (darker + 0.05);
}

/// 取某个按钮样式在默认状态下的前景色。
Color _foregroundOf(ButtonStyle? style) =>
    style!.foregroundColor!.resolve(const <WidgetState>{})!;

Color _backgroundOf(ButtonStyle? style) =>
    style!.backgroundColor!.resolve(const <WidgetState>{})!;

void main() {
  test('基础主题里 TextButton 的前景确实是次要灰——这就是缺陷本身', () {
    // 这一条不是"顺便断言"，它是整条缺陷的前提：如果基础主题不再是灰的，说明别的改动
    // 已经改变了前提，下面那条测试的"修复"就可能在测一个不存在的问题。
    final base = PlannerTheme.dark();
    expect(
      _foregroundOf(base.textButtonTheme.style),
      PlannerPalette.textSecondary,
    );
  });

  test('选择器主题把按钮前景换成主文本色，对比度达到 WCAG AA', () {
    final picker = plannerPickerTheme(PlannerTheme.dark());
    final foreground = _foregroundOf(picker.textButtonTheme.style);
    final background = _backgroundOf(picker.textButtonTheme.style);

    expect(foreground, PlannerPalette.textPrimary);
    expect(
      foreground,
      isNot(PlannerPalette.textSecondary),
      reason: '正是这个次要灰让按钮"容易被看不见"',
    );
    expect(
      _contrast(foreground, background),
      greaterThanOrEqualTo(4.5),
      reason: 'WCAG AA 正文对比度',
    );
    // 按钮还要有可见的边界：只有文字、没有底与框时，在深色面板上仍然像是"一段说明文字"。
    expect(picker.textButtonTheme.style!.backgroundColor, isNotNull);
    expect(picker.textButtonTheme.style!.side, isNotNull);
  });

  test('选择器面板保持深色且**保持透光**，不能变成一块实心板', () {
    final picker = plannerPickerTheme(PlannerTheme.dark());
    expect(
      picker.datePickerTheme.rangePickerHeaderForegroundColor,
      PlannerPalette.textPrimary,
    );
    // 用户 2026-10-07 的第二个反馈："选择统计范围下面日历区域原先是有透明度的，可以看到下面，
    // 现在没了"——第一版把底色写成了不透明的调色板色，透光就没了。这里直接钉住 alpha < 1。
    expect(
      picker.datePickerTheme.rangePickerBackgroundColor!.a,
      lessThan(1.0),
      reason: '选择器底色必须保留玻璃的半透明，否则日历区看不到下面的界面',
    );
    expect(picker.datePickerTheme.backgroundColor!.a, lessThan(1.0));
    expect(picker.datePickerTheme.headerBackgroundColor!.a, lessThan(1.0));
    expect(picker.timePickerTheme.backgroundColor!.a, lessThan(1.0));
  });

  testWidgets('plannerPickerBuilder 真的把选择器包进了那层主题', (tester) async {
    late ThemeData seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: PlannerTheme.dark(),
        home: Builder(
          builder: (context) => plannerPickerBuilder(
            context,
            Builder(
              builder: (inner) {
                seen = Theme.of(inner);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    expect(
      _foregroundOf(seen.textButtonTheme.style),
      PlannerPalette.textPrimary,
    );
  });

  testWidgets('child 为 null 时不崩（选择器构建早期会给 null）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: PlannerTheme.dark(),
        home: Builder(
          builder: (context) => plannerPickerBuilder(context, null),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
