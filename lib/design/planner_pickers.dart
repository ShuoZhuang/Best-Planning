import 'package:flutter/material.dart';

import 'package:personal_planner/design/planner_theme.dart';

/// 日期／时间选择器在本应用深色主题下的**高对比外观**。
///
/// **为什么需要它（真实缺陷，2026-10-07 用户反馈）**：全局 `textButtonTheme` 把前景色设成
/// [PlannerPalette.textSecondary]（灰），而 `showDateRangePicker`／`showDatePicker`／
/// `showTimePicker` 顶部的"取消／应用（确定）"**正是 `TextButton`**——它们在深色选择器面板上
/// 几乎看不见，用户的原话是"右上角的两个按钮不明显，容易被看不见"。
///
/// 修在**一处**而不是九处：`lib/` 下共有 9 个调用点（统计范围、任务到期日、执行时间、学期日期、
/// 节次时间…），它们继承的是同一个主题，因此缺陷也是同一个。给每个调用点各写一遍样式，
/// 迟早只改到其中几个——本项目在"两端约定不一致"上已经吃过一次亏（技术设计 §13.0 的 W5）。
///
/// 用到它的方式是给选择器加 `builder: plannerPickerBuilder`（见该函数的注释）。
///
/// **背景必须保持半透明**：本应用的 `ColorScheme.surface` 取的是**玻璃色**（如 `0xcc142131`），
/// 所以选择器的日历区原本能透出下面的界面。2026-10-07 第一版修复把这里写成不透明的
/// `PlannerPalette.surface`，用户当场反馈"选择统计范围下面日历区域原先是有透明度的，可以看到
/// 下面，现在没了"。因此这里统一从 [PlannerGlassTheme] 取色，**只改对比度、不改透光**。
ThemeData plannerPickerTheme(ThemeData base) {
  // 取当前玻璃模式下的表面色（半透明）。没有扩展时退回调色板表面色——那只在测试里会走到。
  final glass = base.extension<PlannerGlassTheme>();
  final surface = glass?.surface ?? PlannerPalette.surface;
  final surfaceHighlight =
      glass?.surfaceHighlight ?? PlannerPalette.surfaceRaised;

  return base.copyWith(
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        // 前景取**主文本色**而不是次要灰：这是"看得见"的关键一步，也是本缺陷的根因所在。
        foregroundColor: PlannerPalette.textPrimary,
        backgroundColor: PlannerPalette.surfaceHover,
        side: const BorderSide(color: PlannerPalette.outline),
        minimumSize: const Size(64, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    // 选择器面板自身的配色也一并给全：不给的话它会用 Material 的**浅色**默认值，
    // 与本应用的深色外壳拼在一起像两个程序。**但底色用玻璃色**，保留透光。
    datePickerTheme: DatePickerThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: surfaceHighlight,
      headerForegroundColor: PlannerPalette.textPrimary,
      rangePickerBackgroundColor: surface,
      rangePickerSurfaceTintColor: Colors.transparent,
      rangePickerHeaderBackgroundColor: surfaceHighlight,
      rangePickerHeaderForegroundColor: PlannerPalette.textPrimary,
      rangeSelectionBackgroundColor: PlannerPalette.surfaceHover,
      // ── 日期格的前景／背景 ─────────────────────────────────────────────────────
      //
      // **两个真实缺陷（2026-10-07 用户两次反馈），根因都在这一块，且都是我先写错。**
      //
      // 这一版 Flutter 里真正渲染日期格的是 `calendar_date_picker.dart` 的 `_Day`
      // （**不是** `date_picker.dart` 里那份——那里还有一段同名的旧实现，读错了就会得出
      // 完全相反的结论，我就是这么错了两次）。它的关键是：
      //
      //   final decoration = widget.isToday
      //       ? ShapeDecoration(color: dayBackgroundColor,   // ← 「今天」取的是 todayBackgroundColor
      //                          shape: dayShape.copyWith(side: todayBorderSide))
      //       : ShapeDecoration(color: dayBackgroundColor, shape: dayShape);
      //
      // 而 `dayForegroundColor`／`dayBackgroundColor` 的取色在这一版里**按 `isToday` 分流**：
      //
      //   widget.isToday ? theme?.todayForegroundColor : theme?.dayForegroundColor
      //   widget.isToday ? theme?.todayBackgroundColor : theme?.dayBackgroundColor
      //
      // 于是：
      //
      // 1. 我曾把 `todayBackgroundColor` 写成 `transparent`，并在注释里断言"那个圆由
      //    `_HighlightPainter` 画、一覆盖就抹掉"——**那个断言是错的**。圆就是
      //    `dayBackgroundColor` 本身。结果：**今天那格被抹掉了圆**。
      //    用户看到的现象是"点了别的日期，圆圈还是留在 7 号不动"——因为 7 号（今天）
      //    根本不再显示选中圆，而表头确实变了，两者对不上。
      //
      // 2. 我曾把 `todayForegroundColor` 写成 accent。那让**未被选中的今天**用 accent 描边、
      //    还算对；但"今天被选中"时数字也是 accent 色，画在深色面板上几乎看不见——
      //    用户的原话是"图一不还是看不见，只有鼠标移过去看得见"（悬停那层 overlay 让它勉强可辨）。
      //
      // 修法：**照抄 Flutter 自己的 M3 默认结构**（`date_picker_theme.dart` 的
      // `_DayThemeDefaultsM3`），只把颜色换成调色板里的值——
      // 选中态 = accent 实心圆 + `textPrimary` 文字（对比度 **4.68:1**，满足 WCAG AA 4.5:1），
      // 未选中态 = 无底色 + `textPrimary` 文字，今天额外用 accent 描一圈。
      //
      // **不要再靠"猜哪个属性管什么"来调**：改动前先读 `calendar_date_picker.dart` 的
      // `_Day.build`，它就是唯一的事实来源。回归测试见
      // `test/design/date_picker_selection_test.dart`。
      dayForegroundColor: const WidgetStatePropertyAll(
        PlannerPalette.textPrimary,
      ),
      dayBackgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.selected)) {
          return PlannerPalette.accent;
        }
        return Colors.transparent;
      }),
      dayOverlayColor: const WidgetStatePropertyAll(
        PlannerPalette.surfaceHover,
      ),
      todayForegroundColor: const WidgetStatePropertyAll(
        PlannerPalette.textPrimary,
      ),
      // 「今天」被选中时必须有实心圆——这正是缺陷 1 丢掉的东西。
      todayBackgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.selected)) {
          return PlannerPalette.accent;
        }
        return Colors.transparent;
      }),
      todayBorder: const BorderSide(color: PlannerPalette.accent),
      yearForegroundColor: const WidgetStatePropertyAll(
        PlannerPalette.textPrimary,
      ),
      weekdayStyle: const TextStyle(color: PlannerPalette.textSecondary),
      dividerColor: PlannerPalette.outline,
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: surface,
      dialBackgroundColor: PlannerPalette.surfaceRaised,
      dialHandColor: PlannerPalette.accent,
      dialTextColor: PlannerPalette.textPrimary,
      hourMinuteColor: PlannerPalette.surfaceHover,
      hourMinuteTextColor: PlannerPalette.textPrimary,
      entryModeIconColor: PlannerPalette.textSecondary,
      helpTextStyle: const TextStyle(color: PlannerPalette.textSecondary),
    ),
    // **刻意不覆盖 `dialogTheme`**：第一版覆盖成了不透明的 `PlannerPalette.surface`，那会把
    // 对话框形态下的选择器也变成一块实心板。这里要的只是"按钮看得见"，不是把玻璃外壳换掉。
  );
}

/// 给 `showDatePicker`／`showDateRangePicker`／`showTimePicker` 用的 `builder`。
///
/// **只用它还不够**：选择器的"取消／应用"按钮由 `textButtonTheme` 决定，而那个主题来自
/// **弹出的那个 context**。因此每个调用点都要写上 `builder: plannerPickerBuilder`——
/// 光在 `PlannerTheme` 里加 `datePickerTheme` 不会让按钮变清楚（第一版就是这么以为的）。
Widget plannerPickerBuilder(BuildContext context, Widget? child) => Theme(
  data: plannerPickerTheme(Theme.of(context)),
  // `child` 在选择器构建早期可能为 null；给一个空盒子而不是 `child!`，避免为了一个主题包裹
  // 引入一次崩溃机会。
  child: child ?? const SizedBox.shrink(),
);
