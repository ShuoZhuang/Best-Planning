import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Material 自带控件的语言设置，**全应用共用一份**。
///
/// **为什么必须显式给**：`MaterialApp` 不配 `localizationsDelegates` 时会回落到 Flutter 内置的
/// **英文** `MaterialLocalizations`，于是日期／时间选择器、对话框按钮、月份与星期名全是英文——
/// 2026-10-07 实测到的现象是：统计页"自定义范围"打开的日期选择器里，右上角确认按钮显示 **`Save`**、
/// 月份显示 `October 2026`、星期显示 `S M T W T F S`。用户面对一个纯中文界面，那两个按钮
/// （`Save` + 一个 X 图标）自然"看不懂、容易被看不见"。
///
/// **为什么把 `locale` 也钉死成中文**：这个应用的**自身文案全是中文**，没有做多语言。若跟随系统
/// 语言，英文系统上会出现"中文界面 + 英文控件"的混搭——那正是本文件要消除的东西。
/// 因此这里显式指定简体中文；将来真要做多语言时，改这一处并补 ARB 即可。
abstract final class PlannerLocalization {
  /// 简体中文。`Locale('zh', 'CN')` 而不是只给 `zh`：后者会命中"中文（通用）"，
  /// 部分控件（如日期格式）会退回英文样式。
  static const Locale locale = Locale('zh', 'CN');

  static const List<Locale> supportedLocales = [locale, Locale('en')];

  /// 三份委托缺一不可：Material（选择器与按钮文案）、Widgets（方向与语义）、Cupertino
  /// （少数 iOS 风格控件，例如滚轮选择器）。
  static const List<LocalizationsDelegate<Object>> delegates = [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];
}
