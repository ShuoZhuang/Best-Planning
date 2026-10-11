// 1.8.0（设计规范 §8，计划 Task 6）：类型化的日期／时间字段。
//
// 修复前的缺陷（§2.7）：固定日程编辑器与日视图的"改这一次"对话框让用户手输
// `YYYY-MM-DD` 与 `HH:mm`。项目里已经有 `plannerPickerBuilder`，任务编辑器也已经有
// `showDatePicker` / `showTimePicker` 路径——因此这属于**控件不一致**，不是缺少基础能力。
//
// 本文件钉三件事：
// 1. 点击与键盘都能打开选择器；取消不改值；确认更新值；
// 2. 时长联动（§8.2）的三条规则；
// 3. 语义标签带上当前值——只读字段没有输入框那条语义通路，不显式给就只剩一个字段名。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/design/planner_date_time_fields.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/design/planner_theme.dart';

/// 选择器里的按钮文案（"取消／确定"）来自 **`MaterialLocalizations`**，它必须显式配。
///
/// **两个都要，缺一个都不行**（第一版只给了 delegates，测试当场报"找不到 '取消'"）：
/// - `localizationsDelegates`：不给就回落到 Flutter 内置的 `DefaultMaterialLocalizations`
///   ——**只有英文**，选择器上是 `Cancel` / `OK`；
/// - `locale`：**不给就跟随系统语言**，测试环境是 `en`，于是即使配了 delegates 仍然出英文。
///   线上由 `PlannerApp` 钉死 `PlannerLocalization.locale`（界面文案全是中文，没有多语言），
///   测试必须照抄这一行，否则测的是一套和线上不同的文案。
Widget _app(Widget child) => MaterialApp(
  theme: PlannerTheme.dark(),
  locale: PlannerLocalization.locale,
  localizationsDelegates: PlannerLocalization.delegates,
  supportedLocales: PlannerLocalization.supportedLocales,
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(24), child: child),
  ),
);

/// 框本身的那条按钮。字段除了框还有上方标签与下方提示，它们都不该是点击目标
/// （点标签就打开选择器会让"复制标签文字"变得不可能）。
Finder _fieldButton(String key) => find.descendant(
  of: find.byKey(Key(key)),
  matching: find.byType(TextButton),
);

/// 当前焦点所在控件的语义名。**按语义名认控件而不是按 Key**：焦点常常落在控件内部的
/// 渲染对象上（带着一个内部 Key），往上找"最近的带 Key 祖先"会先命中那个内部 key。
/// 语义名也正是屏幕阅读器会念的东西，因此顺带验证了"这个控件有名字"。
String _focusedLabel(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return '';
  try {
    return tester
        .getSemantics(find.byElementPredicate((e) => e == context))
        .label;
  } on Object {
    return '';
  }
}

/// 连续按 Tab 直到焦点落在语义名含 [needle] 的控件上。返回是否走到。
Future<bool> _tabToField(
  WidgetTester tester,
  String needle, {
  int maxSteps = 12,
}) async {
  for (var step = 0; step < maxSteps; step++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    if (_focusedLabel(tester).contains(needle)) return true;
  }
  return false;
}

Future<void> _pumpDate(
  WidgetTester tester,
  DateTime initial, {
  ValueChanged<DateTime>? onChanged,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app(
      SizedBox(
        width: 260,
        child: PlannerDateField(
          key: const Key('d'),
          value: initial,
          label: '开始日期',
          onChanged: onChanged ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpTime(
  WidgetTester tester, {
  TimeOfDay initial = const TimeOfDay(hour: 9, minute: 30),
  ValueChanged<TimeOfDay>? onChanged,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app(
      SizedBox(
        width: 200,
        child: PlannerTimeField(
          key: const Key('t'),
          value: initial,
          onChanged: onChanged ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ── 字段交互与键盘 ──────────────────────────────────────────────────────

  group('PlannerDateField', () {
    testWidgets('字段显示本地格式，而不是要求用户输入 YYYY-MM-DD', (tester) async {
      await _pumpDate(tester, DateTime(2026, 10, 12));

      expect(find.text('2026 年 10 月 12 日'), findsOneWidget);
      // 由选择器完成，因此界面上不该出现 ISO 提示串。
      expect(find.text('YYYY-MM-DD'), findsNothing);
      expect(_fieldButton('d'), findsOneWidget, reason: '框本身必须是一条可点的按钮');
    });

    testWidgets('点击打开选择器，取消不改值', (tester) async {
      await _pumpDate(tester, DateTime(2026, 10, 12));

      await tester.tap(_fieldButton('d'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(find.text('2026 年 10 月 12 日'), findsOneWidget, reason: '取消必须不改值');
    });

    testWidgets('确认后更新值', (tester) async {
      DateTime? changed;
      await _pumpDate(
        tester,
        DateTime(2026, 10, 12),
        onChanged: (value) => changed = value,
      );

      await tester.tap(_fieldButton('d'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(changed, isNotNull);
      expect(changed!.day, 15);
      expect(changed!.month, 10);
    });

    testWidgets('按 Enter 能打开选择器（键盘用户不能只能靠鼠标）', (tester) async {
      await _pumpDate(tester, DateTime(2026, 10, 12));

      // **Tab 到本字段再按 Enter**：把焦点直接塞给内部 `FocusNode` 是做不到的
      // （`TextButton.focusNode` 为 null，它的焦点节点在内部），而从 element 往上找
      // `Focus` 祖先会先命中别的节点。用户实际做的事就是 Tab 走过来——照做最诚实。
      //
      // 这条也是回归守卫：第一版用 `InkWell` 包只读文本，Tab 能得到焦点但 Enter 什么都不做。
      final reached = await _tabToField(tester, '开始日期');
      expect(reached, isTrue, reason: 'Tab 必须能走到日期字段上');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(
        find.byType(DatePickerDialog),
        findsOneWidget,
        reason: '规范 §9：所有新入口支持键盘操作。只读字段必须能被 Enter 激活',
      );
    });

    testWidgets('字段不可用时点不开', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 260,
            child: PlannerDateField(
              key: const Key('d'),
              value: DateTime(2026, 10, 12),
              enabled: false,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<TextButton>(_fieldButton('d')).onPressed, isNull);
    });

    testWidgets('语义标签包含字段名与当前值', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpDate(tester, DateTime(2026, 10, 12));

      // 语义节点可能被合并，因此读**焦点控件**的语义标签——那正是屏幕阅读器会念出来的
      // 那串字。先 Tab 到字段上（同一条用户路径），再读。
      final reached = await _tabToField(tester, '开始日期');
      expect(reached, isTrue, reason: 'Tab 必须能走到日期字段上');

      final label = _focusedLabel(tester);
      expect(label, contains('开始日期'), reason: '只读字段的语义里必须有字段名');
      expect(
        label,
        contains('2026 年 10 月 12 日'),
        reason: '只读字段没有输入框语义，必须显式给出当前值',
      );
      handle.dispose();
    });
  });

  group('PlannerTimeField', () {
    testWidgets('显示 HH:mm，点击打开时间选择器，取消不改值', (tester) async {
      TimeOfDay? changed;
      await _pumpTime(tester, onChanged: (value) => changed = value);

      expect(find.text('09:30'), findsOneWidget);
      expect(find.text('HH:mm'), findsNothing);

      await tester.tap(_fieldButton('t'));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(changed, isNull);
      expect(find.text('09:30'), findsOneWidget);
    });

    testWidgets('按空格也能打开选择器', (tester) async {
      await _pumpTime(tester);

      final reached = await _tabToField(tester, '09:30');
      expect(reached, isTrue, reason: 'Tab 必须能走到时间字段上');

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(find.byType(TimePickerDialog), findsOneWidget);
    });
  });

  // ── 时长联动（§8.2）─────────────────────────────────────────────────────

  group('时长联动', () {
    LocalDateRangeController controller({
      DateTime? startDate,
      TimeOfDay startTime = const TimeOfDay(hour: 14, minute: 0),
      DateTime? endDate,
      TimeOfDay endTime = const TimeOfDay(hour: 15, minute: 30),
    }) => LocalDateRangeController(
      startDate: startDate ?? DateTime(2026, 10, 12),
      startTime: startTime,
      endDate: endDate ?? DateTime(2026, 10, 12),
      endTime: endTime,
    );

    test('改开始时间默认保持原时长并联动结束时间', () {
      final range = controller();
      expect(range.durationMinutes, 90);

      range.setStartTime(const TimeOfDay(hour: 16, minute: 0));

      expect(range.startTime, const TimeOfDay(hour: 16, minute: 0));
      expect(
        range.endTime,
        const TimeOfDay(hour: 17, minute: 30),
        reason: '规范 §8.2：改开始时间时默认保持原时长并联动结束时间',
      );
      expect(range.durationMinutes, 90);
    });

    test('用户手动改过结束时间后，再改开始时间只在新的结束不晚于开始时才自动修正', () {
      final range = controller();
      // 用户把结束手动设成 15:00（时长变成 60 分钟）。
      range.setEndTime(const TimeOfDay(hour: 15, minute: 0));
      expect(range.endTouched, isTrue);
      expect(range.durationMinutes, 60);

      // 开始后移到 14:30 ⇒ 结束 15:00 仍然晚于开始，**不动它**。
      range.setStartTime(const TimeOfDay(hour: 14, minute: 30));
      expect(
        range.endTime,
        const TimeOfDay(hour: 15, minute: 0),
        reason: '用户刚亲手设过结束时间，无条件覆盖等于把他那一次编辑扔掉',
      );

      // 开始后移到 15:00 ⇒ 结束 15:00 与开始相同时才自动修正。
      //
      // **为什么是 15:00 而不是 16:00**：规则 2 的判据是"新的结束不晚于开始"。
      // 移到 16:00 时"原时长"（30 分钟）会把结束一起挪到 16:30，于是区间仍然合法、
      // 那条分支根本不会触发——测试通过也证明不了什么。移到 15:00 才真的让结束
      // 与开始重合，此时必须修正。
      range.setStartTime(const TimeOfDay(hour: 15, minute: 0));
      expect(
        range.endsNotAfterStart,
        isFalse,
        reason: '结束不晚于开始时必须被修正，不能留下一个非法区间',
      );
      expect(range.durationMinutes, greaterThan(0), reason: '修正后必须是一个正的时长');
    });

    test('结束早于或等于开始时如实报出，不做静默猜测', () {
      final range = controller(
        startTime: const TimeOfDay(hour: 22, minute: 0),
        endTime: const TimeOfDay(hour: 21, minute: 0),
      );

      expect(range.endsNotAfterStart, isTrue);
      expect(
        range.crossesMidnight,
        isFalse,
        reason: '同一天的 22:00→21:00 不是跨日，而是填错了；规范 §8.2 要求问用户',
      );
    });

    test('跨日由结束日期表达，不由钟点大小猜', () {
      final range = controller(
        startTime: const TimeOfDay(hour: 22, minute: 0),
        endDate: DateTime(2026, 10, 13),
        endTime: const TimeOfDay(hour: 1, minute: 0),
      );

      expect(range.crossesMidnight, isTrue);
      expect(range.endsNotAfterStart, isFalse);
      expect(range.durationMinutes, 180);
    });

    test('结束日期落在开始之前时，改开始日期会把结束日期一起搬过去', () {
      final range = controller(endDate: DateTime(2026, 10, 12));

      range.setStartDate(DateTime(2026, 10, 20));

      expect(range.startDate, DateTime(2026, 10, 20));
      expect(
        range.endDate,
        DateTime(2026, 10, 20),
        reason: '用户改的是"哪一天"，不该顺手制造一个结束早于开始的区间',
      );
    });
  });
}
