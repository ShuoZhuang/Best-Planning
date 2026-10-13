// Task 5（课程与保护时间管理修复计划）：**整门课程资料编辑页**。
//
// 这一页只做"整门课的属性"：名称、教师、地点、领域、项目、星期、周次、频率。
// "仅本次／此次及以后"那三种范围必须从**日历上的一次课**进入（计划 §2.2），
// 因为"这次"要有一个真实发生时间；把它们混进这一页就会出现"选了『仅本次』
// 却改了整门课"这种说了但没做的状态（计划 §1.1 的实际偏差）。
//
// 本文件钉住四件事：
// 1. 资料字段能从详情**预填**，保存出去的是修改后的值；
// 2. **领域／项目联动**：换领域后旧项目若不属于新领域，立即清空并说明；
// 3. **冲突预览**：有效字段先出影响摘要与冲突；阻断冲突没有「确认保存」；
//    警告冲突要勾选「我已查看课程冲突」才可保存；任何字段变化**立即作废旧预览**；
// 4. **stale 时零写入**，并给出返回入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';
import 'package:personal_planner/features/calendar/courses/course_editor_page.dart';

void main() {
  late _Courses courses;
  late _Gateway gateway;
  late _Calendar calendar;
  late CourseManagementService service;

  final nowUtc = DateTime.utc(2026, 10, 12, 1, 30);

  setUp(() {
    courses = _Courses();
    gateway = _Gateway();
    calendar = _Calendar();
    service = CourseManagementService(
      courses: courses,
      calendar: CalendarService(
        repository: calendar,
        deletion: calendar,
        clock: _Clock(nowUtc),
        idGenerator: _Ids(),
        zones: TimeZoneDatabase(),
      ),
      deletion: calendar,
      gateway: gateway,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: _Clock(nowUtc),
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    String logicalCourseId = 'course-calc',
    List<PlannerArea> areas = const [],
    List<PlannerProject> projects = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: CourseEditorPage(
            service: service,
            logicalCourseId: logicalCourseId,
            loadAreas: areas.isEmpty ? null : () async => areas,
            loadProjects: projects.isEmpty ? null : () async => projects,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> editField(WidgetTester tester, String key, String text) async {
    final field = find.byKey(Key(key));
    await tester.ensureVisible(field);
    await tester.enterText(field, text);
    await tester.pumpAndSettle();
  }

  /// 点一次「保存」出预览，再点一次「确认保存」真的写。
  ///
  /// **只点一次「保存」**：出预览，不写库。
  ///
  /// 这一版必须先有它：`previewAndSave` 会**点两次**（第二次真的写），
  /// 因此在它之后再断言「确认保存按钮是否可用」，看到的已经是**下一版状态**——
  /// 那问的就不是「预览阶段的守卫」了。两条守卫用例（阻断冲突、警告需勾选）
  /// 都因为这一点而失败过。
  Future<void> previewOnly(WidgetTester tester) async {
    final save = find.byKey(const Key('course-editor-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
  }

  /// 点一次「保存」出预览，再点一次「确认保存」真的写。
  ///
  /// **两次各自 `find` 一次**：按钮的 key 会随状态从 `…-save` 变成
  /// `…-confirm-save`，复用同一个 finder 会在第二次点到**已经不存在的旧 key**——
  /// 而 `tap` 找不到目标时会静默什么都不做。
  Future<void> previewAndSave(WidgetTester tester) async {
    await previewOnly(tester);
    final confirm = find.byKey(const Key('course-editor-confirm-save'));
    if (confirm.evaluate().isEmpty) return;
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // 1. 预填与保存
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**资料字段从详情预填**（不是空框）', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('course-editor-page')), findsOneWidget);
    expect(find.text('编辑「高等数学(上)」'), findsOneWidget, reason: '标题要说清正在编辑哪一门课');
    for (final (key, expected) in const [
      ('course-title', '高等数学(上)'),
      ('course-teacher', '赵敏'),
      ('course-location', 'D206'),
    ]) {
      final field = tester.widget<TextField>(find.byKey(Key(key)));
      expect(
        field.controller?.text,
        expected,
        reason: '空框会让用户以为这一项本来就是空的，从而把它覆盖掉',
      );
    }
  });

  testWidgets('**保存出去的是修改后的值**', (tester) async {
    await pump(tester);

    await editField(tester, 'course-title', '高等数学(下)');
    await editField(tester, 'course-teacher', '李娜');
    await previewAndSave(tester);

    expect(gateway.savedProfile, isNotNull);
    expect(gateway.savedProfile!.title, '高等数学(下)');
    expect(gateway.savedProfile!.teacher, '李娜');
    expect(gateway.savedProfile!.logicalCourseId, 'course-calc');
    expect(gateway.savedRows.map((row) => row.reuseAnchorId).toList(), [
      'evt-a',
    ], reason: '既有片段必须沿用原锚点 id，否则它名下的例外会一起消失');
  });

  testWidgets('**空标题时挡住保存并指出该改哪一处**', (tester) async {
    await pump(tester);

    await editField(tester, 'course-title', '   ');
    await previewAndSave(tester);

    expect(find.text('课程名称不能为空'), findsWidgets);
    expect(gateway.savedProfile, isNull, reason: '校验在写之前');
  });

  testWidgets('**深链到不存在的课程**：说清并给返回入口', (tester) async {
    await pump(tester, logicalCourseId: 'nope');

    expect(find.byKey(const Key('course-editor-missing')), findsOneWidget);
    expect(
      find.byKey(const Key('course-title')),
      findsNothing,
      reason: '不给空表单：那会让用户一保存就把原课程清成空白',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 2. 领域／项目联动（计划 Task 5 Step 2）
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**换领域后旧项目被清空并说明**（不得留下不属于新领域的项目）', (tester) async {
    await pump(
      tester,
      areas: [
        PlannerArea(
          id: 'area-study',
          name: '学业',
          color: 0xff456789,
          sortOrder: 0,
          createdAtUtc: nowUtc,
          updatedAtUtc: nowUtc,
        ),
        PlannerArea(
          id: 'area-lab',
          name: '科研',
          color: 0xff456789,
          sortOrder: 0,
          createdAtUtc: nowUtc,
          updatedAtUtc: nowUtc,
        ),
      ],
      projects: [
        PlannerProject(
          id: 'proj-calc',
          areaId: 'area-study',
          name: '高数复习',
          createdAtUtc: nowUtc,
          updatedAtUtc: nowUtc,
        ),
      ],
    );

    // 先选领域「学业」，再选它的项目。
    await tester.tap(find.byKey(const Key('course-area')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学业').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('course-project')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高数复习').last);
    await tester.pumpAndSettle();

    // 再换成「科研」：旧项目不属于它。
    await tester.tap(find.byKey(const Key('course-area')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('科研').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('course-project-cleared')),
      findsOneWidget,
      reason:
          '**必须当场说明**。悄悄留着"高数复习"会让这门课挂在'
          '一个不属于所选领域的项目上，而用户以为自己只是换了领域',
    );
    await previewAndSave(tester);
    expect(gateway.savedProfile!.projectId, isNull, reason: '被清空的项目不能又被写回去');
  });

  testWidgets('**没有项目也能保存**，且不隐式创建项目', (tester) async {
    await pump(
      tester,
      areas: [
        PlannerArea(
          id: 'area-study',
          name: '学业',
          color: 0xff456789,
          sortOrder: 0,
          createdAtUtc: nowUtc,
          updatedAtUtc: nowUtc,
        ),
      ],
    );

    await previewAndSave(tester);

    expect(gateway.savedProfile, isNotNull);
    expect(gateway.savedProfile!.areaId, isNull);
    expect(gateway.savedProfile!.projectId, isNull);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 3. 冲突预览（计划 Task 5 Step 3）
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**字段有效后先出影响摘要**，保存要过一次确认', (tester) async {
    await pump(tester);
    await editField(tester, 'course-location', 'E101');

    // **只点一次**：这一步验的正是"第一次点击只出预览、不写库"。
    final save = find.byKey(const Key('course-editor-save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('course-editor-preview')),
      findsOneWidget,
      reason: '计划 §2.1：预览必须明确列出新增/删除片段数、受影响课次数与会删的例外数',
    );
    expect(gateway.savedProfile, isNull, reason: '第一次点击是预览，不是写入');
  });

  testWidgets('**任何字段变化立即作废旧预览**', (tester) async {
    await pump(tester);
    await editField(tester, 'course-location', 'E101');
    // **只出预览、不保存**：保存成功后预览本来就该消失（它说的是"将要发生什么"），
    // 因此用 `previewAndSave` 会让这一条的**前置断言**直接失败。
    await previewOnly(tester);
    expect(find.byKey(const Key('course-editor-preview')), findsOneWidget);

    await editField(tester, 'course-location', 'E102');

    expect(
      find.byKey(const Key('course-editor-preview')),
      findsNothing,
      reason:
          '留着旧预览会让用户按**过期的数字**做决定——'
          '而那个数字正是他用来判断"要不要真的删掉这一段"的依据',
    );
  });

  testWidgets('**有阻断冲突时没有「确认保存」**', (tester) async {
    // 撞上保护时间：它的语义是"这段时间不许安排"，因此是硬阻断（规范 §10.2 末条）。
    //
    // **时段必须真的与提议时段相交**：这门课是周一 08:00–08:45 本地
    // （= 00:00–00:45 UTC），因此冲突块放在 08:30–09:00 本地（00:30–01:00 UTC）。
    // 放在别的钟点上只会证明"不重叠时不报冲突"——那不是这条用例要问的问题。
    calendar.existing = [
      CalendarOccurrence(
        eventId: 'protected-1',
        title: '午休保护',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 9, 7, 0, 30),
          endUtc: DateTime.utc(2026, 9, 7, 1),
        ),
        locked: true,
        kind: CalendarEventKind.protected,
      ),
    ];
    await pump(tester);
    // **只出预览、不保存**：阻断冲突下"确认保存"根本不该存在，而
    // `previewAndSave` 会去点它（点不到就静默跳过，于是断言看到的是别的状态）。
    await previewOnly(tester);

    expect(
      find.byKey(const Key('course-editor-blocking')),
      findsOneWidget,
      reason: '硬冲突必须说清撞上了什么，而不是一句"有冲突"',
    );
    expect(
      find.byKey(const Key('course-editor-confirm-save')),
      findsNothing,
      reason:
          '规范 §10.2：让"确认一次"就覆盖保护时间，等于把它降级成建议——'
          '而它的语义正是"这段时间不许安排"',
    );
    expect(gateway.savedProfile, isNull);
  });

  testWidgets('**警告冲突要勾选「我已查看课程冲突」才可保存**', (tester) async {
    // 撞上另一门课：课表内部拥挤在真实课表里是常态，做成硬阻断会让用户
    // 根本无法保存自己真实的课表（`isBlockingCourseTimeConflict` 的分工）。
    calendar.existing = [
      CalendarOccurrence(
        eventId: 'other-course-1',
        title: '线性代数',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 9, 7, 0, 30),
          endUtc: DateTime.utc(2026, 9, 7, 1),
        ),
        locked: true,
        logicalCourseId: 'course-linalg',
      ),
    ];
    await pump(tester);

    // **只点一次出预览**，然后检查按钮**当时**的状态。
    //
    // 用 `previewAndSave` 会点第二次（即真的保存），于是随后看到的
    // `course-editor-confirm-save` 属于**下一版状态**——在那上面断言按钮是否可用，
    // 问的已经不是"预览阶段的守卫"了。
    await tester.tap(find.byKey(const Key('course-editor-save')));
    await tester.pumpAndSettle();

    final confirm = find.byKey(const Key('course-editor-confirm-save'));
    expect(confirm, findsOneWidget);
    expect(
      tester.widget<FilledButton>(confirm).onPressed,
      isNull,
      reason: '没勾「我已查看」之前不能保存：这个勾选就是用户真的看过冲突的凭据',
    );

    await tester.tap(find.byKey(const Key('course-editor-ack-conflicts')));
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(gateway.savedProfile, isNotNull);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 4. stale（计划 Task 5 Step 4）
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**数据过期时零写入并给返回入口**', (tester) async {
    courses.staleAfterLoad = true;
    await pump(tester);
    await editField(tester, 'course-location', 'E101');
    await previewAndSave(tester);

    expect(find.textContaining('重新打开'), findsWidgets);
    expect(gateway.savedProfile, isNull, reason: 'stale 是零写入');
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 5. 键盘与语义（计划 Task 5 Step 7）
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**每行的删除按钮语义带上课程名与星期**', (tester) async {
    await pump(tester);

    final tooltip = tester.widget<IconButton>(
      find.byKey(const Key('course-remove-0')),
    );
    expect(
      tooltip.tooltip,
      allOf(contains('高等数学(上)'), contains('周一')),
      reason:
          '只说"删除"的按钮，读屏用户不知道自己在删哪一条——'
          '而这个页面上可能有好几行',
    );
  });

  testWidgets('**有未保存改动时取消要问「放弃更改？」**', (tester) async {
    var cancelled = false;
    await tester.binding.setSurfaceSize(const Size(1280, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: CourseEditorPage(
            service: service,
            logicalCourseId: 'course-calc',
            onCancel: () => cancelled = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await editField(tester, 'course-location', 'E101');
    await tester.tap(find.byKey(const Key('editor-cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('course-editor-discard')), findsOneWidget);
    expect(cancelled, isFalse, reason: '还没确认放弃，不能就这么走了');

    await tester.tap(find.byKey(const Key('course-editor-discard-confirm')));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
  });

  testWidgets('**没有改动时取消直接返回**（不打扰用户）', (tester) async {
    var cancelled = false;
    await tester.binding.setSurfaceSize(const Size(1280, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: CourseEditorPage(
            service: service,
            logicalCourseId: 'course-calc',
            onCancel: () => cancelled = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('editor-cancel')));
    await tester.pumpAndSettle();

    expect(cancelled, isTrue);
    expect(find.byKey(const Key('course-editor-discard')), findsNothing);
  });
}

// ───────────────────────────────────────────────────────────────────────────────
// 替身
// ───────────────────────────────────────────────────────────────────────────────

final class _Courses implements CourseSeriesRepository {
  /// 读完之后让详情"变旧"：模拟别处改过这门课（`saveCourse` 会返回 stale）。
  bool staleAfterLoad = false;

  CourseSeriesDetail? _detail;

  CourseSeriesDetail _build() {
    final segment = CourseSeriesSegment(
      eventId: 'evt-a',
      title: '高等数学(上)',
      weekdays: const {DateTime.monday},
      startMinute: 8 * 60,
      endMinute: 8 * 60 + 45,
      intervalWeeks: 1,
      validFromLocalDate: DateTime(2026, 9, 7),
      validUntilLocalDate: DateTime(2026, 12, 20),
      location: 'D206',
      // **教师读自 `notes`**：课表导入正是用这一列存教师名的。
      teacher: '赵敏',
      weekSpan: const WeekSpan(startWeek: 1, endWeek: 16),
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );
    return CourseSeriesDetail(
      summary: CourseSeriesSummary(
        logicalCourseId: 'course-calc',
        title: '高等数学(上)',
        termId: 'term-autumn',
        anchorEventIds: const ['evt-a'],
        weekday: DateTime.monday,
        startMinute: 8 * 60,
        endMinute: 8 * 60 + 45,
        weekSpans: const [WeekSpan(startWeek: 1, endWeek: 16)],
      ),
      segments: [segment],
    );
  }

  @override
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) async {
    if (logicalCourseId != 'course-calc') return null;
    final detail = _detail;
    if (detail == null) return _detail = _build();
    if (staleAfterLoad) {
      // 同一次会话里第二次读到的修订号更新 ⇒ 页面手上的那一份过期了。
      return CourseSeriesDetail(
        summary: detail.summary,
        segments: [
          CourseSeriesSegment(
            eventId: 'evt-a',
            title: '高等数学(上)',
            weekdays: const {DateTime.monday},
            startMinute: 8 * 60,
            endMinute: 8 * 60 + 45,
            intervalWeeks: 1,
            validFromLocalDate: DateTime(2026, 9, 7),
            validUntilLocalDate: DateTime(2026, 12, 20),
            weekSpan: const WeekSpan(startWeek: 1, endWeek: 16),
            updatedAtUtc: DateTime.utc(2026, 11, 1),
          ),
        ],
      );
    }
    return detail;
  }

  @override
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) async => [
    (await findCourse('course-calc'))!.summary,
  ];

  @override
  Future<String?> currentTermId() async => 'term-autumn';
}

final class _Gateway implements CourseWriteGateway {
  CourseProfileDraft? savedProfile;
  List<CourseWriteRow> savedRows = const [];

  @override
  Future<void> deleteSeriesWithExceptions(Set<String> anchorEventIds) async {}

  @override
  Future<int> countExceptions(String anchorEventId) async => 0;

  @override
  Future<void> replaceCourseSeries({
    required List<CourseWriteRow> rows,
    required CourseProfileDraft profile,
    required String zoneId,
    required DateTime updatedAtUtc,
  }) async {
    savedProfile = profile;
    savedRows = rows;
  }
}

final class _Calendar implements CalendarRepository, CalendarEventDeletion {
  List<CalendarOccurrence> existing = [];

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => existing;

  @override
  Future<void> save(CalendarEvent event) async {}

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
    required CalendarEventEditDraft event,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventEditDraft event,
    RecurrenceEditDraft? recurrence,
    required DateTime updatedAtUtc,
    DateTime? updateExceptionsFromUtc,
  }) async {}

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventEditDraft event,
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

final class _Clock implements Clock {
  const _Clock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'generated-${++_count}';
}
