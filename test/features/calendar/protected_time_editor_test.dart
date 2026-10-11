// 1.8.0（设计规范 §9.2，计划 Task 8 Step 1）：自定义保护时间编辑器。
//
// 修复前的缺陷（§2.8）："新建 → 保护时间"直接跳到 `/settings/rules`。那个页面负责的是
// **长期默认规则**（午餐／晚餐／固定休息），它表达不了"某天 14:00–15:00 不安排"，
// 也表达不了"每周二自定义保护时间"。
//
// 本文件钉三件事：
// 1. 一次性与按周重复都能编出来，且保存出去的记录**是保护时间**（不是固定日程）；
// 2. 标题默认「保护时间」，用户可改；
// 3. 跨日错误在页面内被挡住，不做静默猜测。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/features/calendar/protected_time/protected_time_editor_page.dart';

void main() {
  late _MemoryCalendarRepository repository;

  setUp(() => repository = _MemoryCalendarRepository());

  CalendarService service() => CalendarService(
    repository: repository,
    recurringRepository: repository,
    clock: const _Clock(),
    idGenerator: _Ids(),
    zones: TimeZoneDatabase(),
  );

  Future<void> pumpEditor(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: ProtectedTimeEditorPage(
            service: service(),
            timeZoneId: 'Asia/Shanghai',
            zones: TimeZoneDatabase(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('标题默认「保护时间」，用户可改', (tester) async {
    await pumpEditor(tester);

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('protected-title')))
          .controller
          ?.text,
      '保护时间',
      reason: '规范 §9.2：标题默认「保护时间」',
    );

    await tester.enterText(
      find.byKey(const Key('protected-title')),
      '每周二下午不排事',
    );
    await tester.ensureVisible(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    expect(repository.saved.single.title, '每周二下午不排事');
  });

  testWidgets('保存出去的是**保护时间**，不是固定日程', (tester) async {
    await pumpEditor(tester);

    await tester.ensureVisible(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    expect(
      repository.saved.single.kind,
      CalendarEventKind.protected,
      reason: '这一页存在的全部意义就是把 kind 写成 protected（规范 §9.1）',
    );
    expect(repository.rules, isEmpty, reason: '一次性保护时间不该顺手建出一条重复规则');
  });

  testWidgets('按周重复时保存出星期规则与重复结束日期', (tester) async {
    await pumpEditor(tester);

    await tester.tap(find.byKey(const Key('protected-weekly')));
    await tester.pumpAndSettle();

    // 默认已选中开始日那一星期的同一天，这里再选周二以确保星期集合非空且可断言。
    await tester.tap(
      find.byKey(const Key('protected-weekday-${DateTime.tuesday}')),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    expect(repository.saved.single.kind, CalendarEventKind.protected);
    expect(repository.rules, hasLength(1));
    expect(
      repository.rules.single.weekdays,
      contains(DateTime.tuesday),
      reason: '按周重复必须把选中的星期写进规则',
    );
  });

  testWidgets('结束不晚于开始时在页面内报错，且不写库', (tester) async {
    await pumpEditor(tester);

    // 把结束日期改到开始日期之前 ⇒ 非法区间。
    await tester.tap(find.byKey(const Key('protected-end-date-box')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('editor-error-summary')),
      findsOneWidget,
      reason: '规范 §8.2：结束早于或等于开始必须明确报出，不做静默猜测',
    );
    expect(repository.saved, isEmpty, reason: '非法输入不得写库');
  });

  testWidgets('空标题时在页面内报错，且不写库', (tester) async {
    await pumpEditor(tester);

    await tester.enterText(find.byKey(const Key('protected-title')), '   ');
    await tester.ensureVisible(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();

    // 出现**两处**是有意的：字段下方的 `errorText` 指出该改哪一处，
    // 顶部的错误摘要给出全局提示（规范 §7.2 要求编辑器共用同一个错误摘要骨架）。
    expect(find.text('请填写标题'), findsWidgets);
    expect(
      find.byKey(const Key('editor-error-summary')),
      findsOneWidget,
      reason: '错误摘要必须出现在共享骨架里',
    );
    expect(repository.saved, isEmpty);
  });
}

final class _MemoryCalendarRepository
    implements CalendarRepository, RecurringCalendarRepository {
  final List<CalendarEvent> saved = [];
  final List<RecurrenceRule> rules = [];

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => [];

  @override
  Future<void> save(CalendarEvent event) async => saved.add(event);

  @override
  Future<void> saveRecurring(CalendarEvent event, RecurrenceRule rule) async {
    saved.add(event);
    rules.add(rule);
  }
}

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5, 2);
}

final class _Ids implements IdGenerator {
  var _next = 0;
  @override
  String next() => 'id-${_next++}';
}
