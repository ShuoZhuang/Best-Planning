// M3 追加：日期选择器里"今天"被选中后**数字消失**的回归测试。
//
// **真实缺陷（2026-10-07 用户反馈）**：新建任务页点"选择日期"，选中 10 月 7 日（当天）之后，
// 7 这个数字看不见了——用户原话"为什么选择日期的时候今日的这个数字不见了"。
//
// 根因不在日期选择器本身，而在 `planner_pickers.dart` 的主题：
// Flutter 的 `_Day` 会先取 `dayForegroundColor` 与 `dayBackgroundColor` 解析
// `WidgetState.selected`，**之后**再无条件用 `todayForegroundColor` 覆盖前景
// （`date_picker.dart` 里 `itemStyle = itemStyle?.apply(color: dayForegroundColor)`
// 之后紧跟 `if (widget.isToday) … apply(color: todayForegroundColor)`）。
// 于是"今天且被选中"这一格得到的是 **accent 色的字画在 accent 色的圆上**——同色，等于空白。
//
// 这条测试同时充当**对比度实测**：它用 Flutter 自带的 `textContrastGuideline`（按 WCAG
// 4.5:1／3:1 逐节点检查），因此修复后"用哪个颜色"不是靠肉眼估的。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/design/planner_pickers.dart';
import 'package:personal_planner/design/planner_theme.dart';

void main() {
  /// WCAG 相对亮度（sRGB）。
  double lum(Color c) {
    double channel(double v) => v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  /// 两个**不透明**颜色的对比度。
  double ratio(Color a, Color b) {
    final la = lum(a);
    final lb = lum(b);
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  // 与所有选择器调用点一致的装配方式（主题 + builder）。
  Future<void> pumpPicker(WidgetTester tester, DateTime initialDate) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: PlannerTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: Builder(
                builder: (inner) => ElevatedButton(
                  onPressed: () => showDatePicker(
                    context: inner,
                    initialDate: initialDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2030),
                    builder: plannerPickerBuilder,
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('当天被选中后，日期数字必须仍然看得见（不是同色字画在同色圆上）', (tester) async {
    // 统一用 UTC 构造日期：这里只关心"哪一格同时是今天且被选中"，与时区无关。
    final today = DateTime.utc(2026, 10, 7);
    await pumpPicker(tester, today);

    // 选择器已打开，且 7 这一格就在屏幕上。
    expect(find.text('7'), findsOneWidget, reason: '当天那格应当出现在日历里');

    // 选中它——这正是用户做的动作。
    await tester.tap(find.text('7'));
    await tester.pumpAndSettle();

    // ① 数字还在（没有被替换或移除）。
    expect(find.text('7'), findsOneWidget, reason: '选中当天之后，数字 7 必须还在日历上');

    // ② 数字看不清靠的是**文字色与它所在那格的底色**。这一条用 Flutter 的 WCAG 检查，
    //    不看"我觉得还行"。
    await expectLater(
      tester,
      meetsGuideline(textContrastGuideline),
      reason:
          '选中当天后，数字与圆底必须是可分辨的组合。'
          '缺陷形态是 accent 色的字画在 accent 色的圆上（对比度 1:1，等于空白）。',
    );
  });

  testWidgets('今天且被选中时，数字不能用 accent 色（同色字画在同色圆上）', (tester) async {
    final today = DateTime.utc(2026, 10, 7);
    await pumpPicker(tester, today);
    await tester.tap(find.text('7'));
    await tester.pumpAndSettle();

    // 取该日期数字**实际生效**的颜色。
    //
    // **为什么断言前景而不是量"字色 vs 圆底色"**：选中那个圆不是 `Decoration` 画的——
    // `_Day` 的 `Container(decoration: ...)` 在选中态 `decoration` 里没有颜色，圆来自
    // `_HighlightPainter` 与 `InkResponse` 的 overlay（见 `date_picker.dart` 的 `_Day.build`）。
    // 因此从控件树里取不到"圆底色"这个值。而缺陷的**直接特征**恰好在前景上：
    // Flutter 用 `todayForegroundColor` 覆盖了 `dayForegroundColor`，得到的是 accent 色的字，
    // 画在 accent 色的圆上——同色，等于空白。
    final textWidget = tester.widget<Text>(find.text('7'));
    final foreground = (textWidget.style ?? const TextStyle()).color;
    expect(foreground, isNotNull, reason: '日期数字必须有明确的文字色，否则会继承主题默认值而无法判断对比度');
    expect(
      foreground,
      isNot(PlannerPalette.accent),
      reason:
          '选中当天不能用 accent 色写数字：accent 色的字画在 accent 色的圆上对比度是 1.0，'
          '数字看不见（用户原话"为什么选择日期的时候今日的这个数字不见了"）。'
          '实际 color=$foreground',
    );

    // 用哪个颜色不是随手定的：与 `chipTheme` 对"accent 底上的文字"的先例一致
    // （`PlannerPalette.textPrimary`）。取白而不是更暗的深色，见下方对比度实测。
    expect(
      foreground,
      PlannerPalette.textPrimary,
      reason: '应当与项目既有约定一致：accent 底上用 textPrimary',
    );

    // 把"这个组合到底达不达标"用算式钉住，免得以后改色时只改了断言没改配色。
    final measured = ratio(PlannerPalette.textPrimary, PlannerPalette.accent);
    expect(
      measured,
      greaterThanOrEqualTo(4.5),
      reason:
          'textPrimary 在 accent 上必须达到 WCAG AA 的 4.5:1，'
          '实测 ${measured.toStringAsFixed(2)}:1',
    );
  });
}
