// M3 追加（2026-10-07 用户两次反馈）：日期选择器「今天」那格的颜色与选中圆。
//
// 用户反馈两条：
//   1. "为什么选择日期的时候今日的这个数字不见了"——选中 7 号（当天）后数字看不见。
//   2. "我点击其他日期怎么还是选定在这里"——表头变成 10月15日，但圆圈仍留在 7 号。
//
// **两条的根因是同一个，而且都在 `planner_pickers.dart` 里我写错的两个属性**。
// 关键在于：这一版 Flutter 真正渲染日期格的是
// `flutter/lib/src/material/calendar_date_picker.dart` 的 `_Day`，**不是** `date_picker.dart`
// 里那段同名的旧实现。按后者推理会得出完全相反的结论——我前后错了两次，都是因为读了错的源码。
//
// 真实取色逻辑（`_Day.build`）：
//
//   final decoration = widget.isToday
//       ? ShapeDecoration(color: dayBackgroundColor, shape: ...)   // 今天用的其实是
//       : ShapeDecoration(color: dayBackgroundColor, shape: ...);  // todayBackgroundColor
//
//   dayForegroundColor = resolve(widget.isToday ? todayForegroundColor : dayForegroundColor)
//   dayBackgroundColor = resolve(widget.isToday ? todayBackgroundColor : dayBackgroundColor)
//
// 所以本文件**直接断言"今天"那两个属性在 selected 状态下解析出什么**——
// 那正是画到屏幕上的值，比事后从控件树里猜要可靠。
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

  double ratio(Color a, Color b) {
    final la = lum(a);
    final lb = lum(b);
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// 在**选择器内部**取到生效的 `DatePickerThemeData`。
  ///
  /// 直接从某个日期格的 `BuildContext` 上取：日期格是选择器子树的一部分，
  /// 因此它拿到的正是 `plannerPickerBuilder` 套上去的那份主题。
  /// **不按"确定／OK"按钮找 context**：测试环境是英文（那按钮叫 `OK`），
  /// 而应用是中文——按文案找会让测试与语言绑定。
  DatePickerThemeData themeFromPicker(WidgetTester tester) {
    final ctx = tester.element(find.text('15'));
    return DatePickerTheme.of(ctx);
  }

  /// 把选择器打开，并把它的 `DatePickerTheme` 交出来。
  Future<DatePickerThemeData> openPicker(
    WidgetTester tester,
    DateTime initialDate,
  ) async {
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
    return themeFromPicker(tester);
  }

  const selected = <WidgetState>{WidgetState.selected};
  const unselected = <WidgetState>{};

  testWidgets('今天被选中时必须有实心圆（缺陷：圆被 transparent 抹掉）', (tester) async {
    final theme = await openPicker(tester, DateTime.utc(2026, 10, 7));

    final background = theme.todayBackgroundColor?.resolve(selected);
    expect(background, isNotNull, reason: '今天被选中时必须解析出一个底色');
    expect(
      background!.a,
      greaterThan(0),
      reason:
          '今天被选中时底色不能是全透明——那个圆就是靠它画的。'
          '曾经写成 `transparent`，于是 7 号永远没有选中圆，'
          '用户看到的是"点了别的日期，圆圈还是留在 7 号不动"。实际=$background',
    );
    expect(
      background,
      PlannerPalette.accent,
      reason: '选中圆应当用 accent 实心色（与 Flutter M3 默认结构一致）',
    );
  });

  testWidgets('今天被选中时数字必须与圆底有足够对比（缺陷：数字看不见）', (tester) async {
    final theme = await openPicker(tester, DateTime.utc(2026, 10, 7));

    final foreground = theme.todayForegroundColor?.resolve(selected);
    final background = theme.todayBackgroundColor?.resolve(selected);
    expect(foreground, isNotNull);
    expect(background, isNotNull);

    final measured = ratio(foreground!, background!);
    expect(
      measured,
      greaterThanOrEqualTo(4.5),
      reason:
          '今天被选中时，数字与圆的对比度必须达到 WCAG AA 的 4.5:1。'
          '曾经把前景写成 accent（与圆同色，1.0:1），用户看到的就是"数字不见了"。'
          '实测 前景=$foreground 圆底=$background 对比度=${measured.toStringAsFixed(2)}:1',
    );
  });

  testWidgets('未被选中的今天不画实心圆（否则它会看起来像被选中）', (tester) async {
    final theme = await openPicker(tester, DateTime.utc(2026, 10, 7));

    final background = theme.todayBackgroundColor?.resolve(unselected);
    expect(
      background == null || background.a == 0,
      isTrue,
      reason:
          '未被选中的今天只该有一圈 accent 描边，不该有实心底色——'
          '有实心底色会让它和"已选中"看起来一样。实际=$background',
    );
  });

  testWidgets('非今天的日期被选中时同样有实心圆（不然只有今天能看到选中）', (tester) async {
    final theme = await openPicker(tester, DateTime.utc(2026, 10, 7));

    final background = theme.dayBackgroundColor?.resolve(selected);
    expect(
      background,
      PlannerPalette.accent,
      reason: '选中任何日期都应当画 accent 实心圆，不只今天。实际=$background',
    );
  });

  testWidgets('点其他日期后，选中语义标记必须离开原来那一天', (tester) async {
    await openPicker(tester, DateTime.utc(2026, 10, 7));

    await tester.tap(find.text('15'));
    await tester.pumpAndSettle();

    final selectedLabels = <String>[];
    // `binding.pipelineOwner` 被标记弃用，但仍是唯一能拿到当前语义根的入口。
    // **点完再取根**：语义根会随重建变化，点之前抓到的那个已经过期。
    // ignore: deprecated_member_use
    final root = tester.binding.pipelineOwner.semanticsOwner?.rootSemanticsNode;
    void walk(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.flagsCollection.isSelected == Tristate.isTrue) {
        selectedLabels.add(data.label);
      }
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    expect(root, isNotNull, reason: '取不到语义根，这条断言就无从谈起');
    walk(root!);
    expect(selectedLabels, isNotEmpty, reason: '必须有且只有一天带选中标记');
    expect(
      selectedLabels.any((label) => label.trimLeft().startsWith('15')),
      isTrue,
      reason: '点 15 号之后，选中标记应当落在 15 号上。实际带选中标记的是：${selectedLabels.join(" | ")}',
    );
    expect(
      selectedLabels.any((label) => label.trimLeft().startsWith('7,')),
      isFalse,
      reason: '选中标记必须离开 7 号。实际带选中标记的是：${selectedLabels.join(" | ")}',
    );
  });
}
