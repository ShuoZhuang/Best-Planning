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
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/protected_time_series.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/protected_time_series_repository.dart';
import 'package:personal_planner/features/calendar/protected_time/protected_time_series_editor_page.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/features/calendar/protected_time/protected_time_editor_page.dart';

void main() {
  late _MemoryCalendarRepository repository;

  setUp(() => repository = _MemoryCalendarRepository());

  CalendarService service([CalendarEventDeletion? deletion]) => CalendarService(
    repository: repository,
    recurringRepository: repository,
    // **编写入口必须显式给**：不给时 `updateEvent` 返回 `unsupported`，
    // 于是"编辑模式"看起来永远保存不了——而那会掩盖真正的判据。
    deletion: deletion ?? _RecordingDeletion(),
    clock: const _Clock(),
    idGenerator: _Ids(),
    zones: TimeZoneDatabase(),
  );

  Future<void> pumpEditor(
    WidgetTester tester, {
    String initialNotes = '',
  }) async {
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
            initialNotes: initialNotes,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 打开**编辑模式**（走系列编辑器：先读详情再预填）。
  Future<void> pumpEdit(
    WidgetTester tester, {
    required _RecordingDeletion deletion,
    ProtectedTimeSeries? series,
  }) async {
    final anchor =
        series ??
        ProtectedTimeSeries(
          anchorId: 'p1',
          title: '午休',
          timeZoneId: 'Asia/Shanghai',
          startMinute: 14 * 60,
          endMinute: 15 * 60,
          weekdays: const {DateTime.tuesday},
          validFromLocalDate: DateTime(2026, 10, 6),
          validUntilLocalDate: DateTime(2026, 12, 20),
          notes: '原备注',
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        );
    // 让库里的锚点与详情一致：过期判定因此走"没人改过"这条正常路径。
    repository.anchors
      ..clear()
      ..add((
        eventId: anchor.anchorId,
        title: anchor.title,
        startUtc: TimeZoneDatabase().localDateTimeToUtc(
          anchor.validFromLocalDate,
          anchor.startMinute,
          anchor.timeZoneId,
        ),
        endUtc: TimeZoneDatabase().localDateTimeToUtc(
          anchor.validFromLocalDate,
          anchor.endMinute,
          anchor.timeZoneId,
        ),
        updatedAtUtc: anchor.updatedAtUtc,
      ));
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: ProtectedTimeSeriesEditorPage(
            reader: _FixedSeries(anchor),
            calendar: service(deletion),
            anchorId: anchor.anchorId,
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

  testWidgets('备注被真的保存下去（规范 §9.2 把它列为这一页的字段）', (tester) async {
    // **这条用例是本轮补的，它此前不可能存在**：`EventDraft` 根本没有 `notes` 字段，
    // 因此保存路径从草稿构造事件时就把它丢掉了 —— `CalendarEvent.notes` 与
    // `calendar_events.notes` 一直都在（课表导入还用它装教师名），但**没有任何编辑器
    // 能写它**。症状是"备注"是一列只读不可写的字段：导入的课有备注，手建的永远没有。
    await pumpEditor(tester);

    await tester.enterText(
      find.byKey(const Key('protected-notes')),
      '这段时间用来吃饭，不安排任务',
    );
    await tester.ensureVisible(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    expect(
      repository.saved.single.notes,
      '这段时间用来吃饭，不安排任务',
      reason: '备注必须一路走到 `CalendarEvent.notes`；丢掉它等于这一页少了一个字段',
    );
  });

  testWidgets('不填备注时存成空串，而不是把 null 或占位文字写进去', (tester) async {
    await pumpEditor(tester);

    await tester.ensureVisible(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();

    expect(repository.saved.single.notes, '');
  });

  testWidgets('**编辑既有事项时原备注被原样写回**，不会被静默抹掉', (tester) async {
    // 这一条守的是加备注字段时最容易引入的回归：编辑器新建时备注为空、
    // 保存时就把空串写回去，于是"编辑一次"= **清空备注**。
    // 课表导入正是用 `notes` 存教师名，所以抹掉的可能是用户看得见的信息。
    //
    // 与"能读的字段必须也能原样写回"是同一条：新增一个可写字段时，
    // 必须同时问"已经有值的那一条会发生什么"。
    await pumpEditor(tester, initialNotes: '教师：张伟');

    await tester.ensureVisible(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();

    expect(
      repository.saved.single.notes,
      '教师：张伟',
      reason: '没有改动备注时，保存必须把它原样写回；写成空串就是静默丢数据',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 8 Step 1／Step 5：**编辑模式更新原记录，绝不新建**
  //
  // 旧测试的写法是"传 `initialNotes` 再创建新事项"，然后断言那条**新记录**带着备注。
  // 那只能证明"初始备注会被再次创建"，**没有证明更新了原记录**——而真实缺陷正是
  // 每次保存都新建一条：改一次名字，管理页就多一行。
  //
  // 这里换成真正的判据：原 `event id` 不变、**记录数不增加**、标题与备注已更新。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**编辑模式更新原记录**：id 不变、记录数不增加、标题与备注已更新', (tester) async {
    final deletion = _RecordingDeletion();
    final anchor = ProtectedTimeSeries(
      anchorId: 'p1',
      title: '午休',
      timeZoneId: 'Asia/Shanghai',
      startMinute: 14 * 60,
      endMinute: 15 * 60,
      weekdays: const {DateTime.tuesday},
      validFromLocalDate: DateTime(2026, 10, 6),
      validUntilLocalDate: DateTime(2026, 12, 20),
      notes: '原备注',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    // 让库里的锚点与详情一致：过期判定因此走"没人改过"这条正常路径。
    repository.anchors
      ..clear()
      ..add((
        eventId: anchor.anchorId,
        title: anchor.title,
        startUtc: TimeZoneDatabase().localDateTimeToUtc(
          anchor.validFromLocalDate,
          anchor.startMinute,
          anchor.timeZoneId,
        ),
        endUtc: TimeZoneDatabase().localDateTimeToUtc(
          anchor.validFromLocalDate,
          anchor.endMinute,
          anchor.timeZoneId,
        ),
        updatedAtUtc: anchor.updatedAtUtc,
      ));
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: ProtectedTimeSeriesEditorPage(
            reader: _FixedSeries(anchor),
            calendar: service(deletion),
            anchorId: 'p1',
            timeZoneId: 'Asia/Shanghai',
            zones: TimeZoneDatabase(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 标题与备注都从详情预填。
    expect(
      find.text('午休'),
      findsWidgets,
      reason: '编辑模式的标题栏与标题字段都要显示原有名称，否则用户以为在新建',
    );

    await tester.enterText(find.byKey(const Key('protected-title')), '看医生');
    await tester.enterText(find.byKey(const Key('protected-notes')), '带医保卡');
    await tester.ensureVisible(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();

    expect(
      deletion.replacedSeries,
      ['p1'],
      reason:
          '**必须更新 p1 本身**。走到 `replaceSeries` 之外的任何一条路都意味着'
          '要么新建了一条（改一次名字多一行），要么改错了对象',
    );
    expect(deletion.lastEdit!.title, '看医生');
    expect(deletion.lastEdit!.notes, '带医保卡');
    expect(
      repository.saved,
      isEmpty,
      reason:
          '**绝不能走 `CalendarService.save()`**：它会生成新的 `CalendarEvent`，'
          '而"改一次名字变成又建了一条"正是本批次要修的缺陷（计划 §1.2）',
    );
    expect(repository.rules, isEmpty, reason: '整条系列编辑不改规则行本身，因此不该产生新的规则写入');
  });

  testWidgets('**编辑模式更新原记录**（同一件事的第二条判据）：写入次数恰好一次', (tester) async {
    final deletion = _RecordingDeletion();
    await pumpEdit(tester, deletion: deletion);

    await tester.enterText(find.byKey(const Key('protected-title')), '健身');
    await tester.ensureVisible(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-protected-time')));
    await tester.pumpAndSettle();

    expect(
      deletion.replacedSeries.length,
      1,
      reason: '一次点击只写一次。写两次会让第二条覆盖第一条，且重排原因多记一条',
    );
  });

  testWidgets('**不存在的系列给一个说清楚的页面**，而不是空表单', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: ProtectedTimeSeriesEditorPage(
            reader: _FixedSeries(null),
            calendar: service(_RecordingDeletion()),
            anchorId: 'gone',
            timeZoneId: 'Asia/Shanghai',
            zones: TimeZoneDatabase(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('protected-series-missing')), findsOneWidget);
    expect(
      find.byKey(const Key('protected-title')),
      findsNothing,
      reason:
          '**不给空表单**：那会让用户以为这条规则是空的，一保存就把它的名称、'
          '时间与重复规则全部覆盖掉',
    );
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

/// 一个只有一条（或没有）系列的读模型替身。
final class _FixedSeries implements ProtectedTimeSeriesReader {
  const _FixedSeries(this.series);
  final ProtectedTimeSeries? series;

  @override
  Future<List<ProtectedTimeSeries>> listProtectedSeries() async =>
      series == null ? const [] : [series!];

  @override
  Future<ProtectedTimeSeries?> findProtectedSeries(String anchorId) async =>
      series?.anchorId == anchorId ? series : null;
}

/// 记录改写调用的删除端口（Task 8 Step 5 的判据都落在它身上）。
final class _RecordingDeletion implements CalendarEventDeletion {
  final List<String> replacedSeries = [];
  CalendarEventPatch? lastEdit;

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    RecurrenceEditDraft? recurrence,
    required DateTime updatedAtUtc,
    DateTime? updateExceptionsFromUtc,
  }) async {
    replacedSeries.add(anchorId);
    lastEdit = patch;
  }

  @override
  Future<void> deleteEvent(String eventId) async {}

  @override
  Future<void> deleteOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> deleteFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    RecurrenceEditDraft? recurrence,
    required String newRuleId,
    required String newEventId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> setEventArea({
    required String eventId,
    required String? areaId,
    required DateTime updatedAtUtc,
  }) async {}
}

final class _MemoryCalendarRepository
    implements CalendarRepository, RecurringCalendarRepository {
  final List<CalendarEvent> saved = [];
  final List<RecurrenceRule> rules = [];

  /// 库里"当前存在"的锚点（由测试预置，供过期判定读取）。
  final List<
    ({
      String eventId,
      String title,
      DateTime startUtc,
      DateTime endUtc,
      DateTime updatedAtUtc,
    })
  >
  anchors = [];
  List<
    ({
      String eventId,
      String title,
      DateTime startUtc,
      DateTime endUtc,
      DateTime updatedAtUtc,
    })
  >
  get _anchors => anchors;

  /// **返回锚点当前的样子**：`CalendarService.updateEvent` 的过期判定要用它。
  ///
  /// 这里返回与详情相同的修订号，模拟"用户打开页面之后没有人改过"这条正常路径。
  /// "别处改过 ⇒ stale" 的判据在 `protected_time_edit_service_test.dart` 里用真实库验，
  /// 不在此重复——那一条需要真的写入才能证明"零写入"。
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => [
    for (final anchor in _anchors)
      if (!anchor.startUtc.isBefore(startUtc) &&
          anchor.startUtc.isBefore(endUtc))
        CalendarOccurrence(
          eventId: anchor.eventId,
          title: anchor.title,
          range: TimeRange(startUtc: anchor.startUtc, endUtc: anchor.endUtc),
          locked: true,
          kind: CalendarEventKind.protected,
          updatedAtUtc: anchor.updatedAtUtc,
        ),
  ];

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
