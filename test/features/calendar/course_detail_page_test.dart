// 1.8.0（规范 §10.1）：课程详情页要展示**每个逻辑课程的聚合信息**。
//
// 规范原文把字段逐个列了出来："课程名、星期与节次/时间、周次、单双周、**地点、教师**、
// 领域、项目、启用状态、来源批次。"
//
// **这个文件此前不存在**：详情页一条用例也没有，于是"哪些字段真的显示了"从来没有被核对过。
// 管理列表那一边有 5 条用例（其中一条断言了地点与教师），详情页这一边是零。
// 结果就是教师字段在列表里显示、在详情页里**从来不显示**——而详情页正是用户点进来
// "确认这是哪门课、谁教的"的地方。
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
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';
import 'package:personal_planner/features/calendar/courses/course_detail_page.dart';

void main() {
  CourseSeriesDetail detail({
    String teacher = '赵敏',
    String location = 'D206',
    List<CourseIntegrityIssue> issues = const [],
  }) => CourseSeriesDetail(
    summary: CourseSeriesSummary(
      logicalCourseId: 'course-calc',
      title: '高等数学(上)',
      termId: 'term-autumn',
      anchorEventIds: const ['evt-a'],
      weekday: DateTime.monday,
      startMinute: 8 * 60,
      endMinute: 8 * 60 + 45,
      weekSpans: const [WeekSpan(startWeek: 1, endWeek: 16)],
      location: location,
      teacher: teacher,
    ),
    segments: [
      CourseSeriesSegment(
        eventId: 'evt-a',
        timeZoneId: 'Asia/Shanghai',
        title: '高等数学(上)',
        weekday: DateTime.monday,
        startMinute: 8 * 60,
        endMinute: 8 * 60 + 45,
        intervalWeeks: 2,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
        location: location,
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
    ],
    integrityIssues: issues,
  );

  Future<void> pumpDetail(
    WidgetTester tester, {
    String teacher = '赵敏',
    String location = 'D206',
    VoidCallback? onEditCourse,
    List<CourseIntegrityIssue> issues = const [],
    bool restoreAvailable = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: CourseDetailPage(
            service: CourseManagementService(
              courses: _Courses(
                detail(teacher: teacher, location: location, issues: issues),
              ),
              calendar: CalendarService(
                repository: const _NoopCalendar(),
                deletion: const _NoopCalendar(),
                clock: const _Clock(),
                idGenerator: const _Ids(),
                zones: TimeZoneDatabase(),
              ),
              deletion: const _NoopCalendar(),
              gateway: const _NoopGateway(),
            ),
            logicalCourseId: 'course-calc',
            onEditCourse: onEditCourse,
            restoreFromTimetableAvailable: restoreAvailable,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Task 4（课程编辑完整性修复计划）：**旧版损伤提示与两条恢复路径**（LI1、LI3、LI4）
  // ───────────────────────────────────────────────────────────────────────────

  testWidgets('LI1：命中旧版损伤时显示结构化提示与两条真实恢复路径', (tester) async {
    var repaired = 0;
    await pumpDetail(
      tester,
      onEditCourse: () => repaired++,
      issues: [
        CourseIntegrityIssue(
          kind: CourseIntegrityIssueKind.legacyPlaceholderTitle,
          affectedAnchorIds: const ['evt-a'],
        ),
      ],
    );

    expect(
      find.byKey(const Key('course-integrity-banner')),
      findsOneWidget,
      reason: '命中确定性判据时必须让用户看见，而不是把损坏数据当正常课程继续保存',
    );
    expect(find.textContaining('检测到这门课程可能受旧版时间修改问题影响'), findsOneWidget);
    expect(
      find.textContaining('无法自动还原'),
      findsOneWidget,
      reason: '必须明确说清系统做不到什么，否则用户会去找一个不存在的按钮',
    );
    expect(
      find.byKey(const Key('course-integrity-placeholder')),
      findsOneWidget,
      reason: '标题仍是旧占位文字时要点名到具体字段',
    );
    expect(find.byKey(const Key('course-integrity-repair')), findsOneWidget);
    expect(
      find.byKey(const Key('course-integrity-restore')),
      findsNothing,
      reason:
          '恢复路径二依赖 Task 7–10 的批次状态与同图重导入；'
          '能力未齐备时放它出来会把用户送到"删了却导不回来"的死路（Task 4 Step 4）',
    );

    await tester.tap(find.byKey(const Key('course-integrity-repair')));
    await tester.pumpAndSettle();
    expect(repaired, 1);
  });

  testWidgets('LI2：正常课程（空教师、空地点、无领域）不显示任何提示', (tester) async {
    await pumpDetail(tester, teacher: '', location: '');

    expect(
      find.byKey(const Key('course-integrity-banner')),
      findsNothing,
      reason: '空教师/空地点可能只是用户没填：误报会挂上一条永远消不掉的提示',
    );
  });

  testWidgets('LI4：能力齐备（feature gate 打开）后出现「从原课表恢复」', (tester) async {
    await pumpDetail(
      tester,
      restoreAvailable: true,
      issues: [
        CourseIntegrityIssue(
          kind: CourseIntegrityIssueKind.eventRuleTimeZoneMismatch,
          affectedAnchorIds: const ['evt-a'],
        ),
      ],
    );

    expect(find.byKey(const Key('course-integrity-restore')), findsOneWidget);
    await tester.tap(find.byKey(const Key('course-integrity-restore')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('course-restore-dialog')),
      findsOneWidget,
      reason: '删掉这门课之前必须先让用户确认"我已经备份、并且还有那张课表图片"',
    );
    expect(find.textContaining('逐次调整'), findsOneWidget);
  });

  testWidgets('详情页显示教师与地点（规范 §10.1 的字段清单）', (tester) async {
    await pumpDetail(tester);

    expect(
      find.byKey(const Key('course-detail-teacher')),
      findsOneWidget,
      reason:
          '§10.1 把"教师"列为本页要展示的字段；课表导入把教师名写在 `notes` 里，'
          '列表页显示了它，详情页此前从来不显示',
    );
    expect(
      find.textContaining('赵敏'),
      findsOneWidget,
      reason: '显示的是教师名本身，不是一个空标签',
    );
    expect(find.byKey(const Key('course-detail-location')), findsOneWidget);
    expect(find.textContaining('D206'), findsWidgets);
  });

  testWidgets('教师为空时不显示空标签（不写"教师："后什么都没有）', (tester) async {
    await pumpDetail(tester, teacher: '');

    expect(
      find.byKey(const Key('course-detail-teacher')),
      findsNothing,
      reason: '没有教师时不该出现一个空行——那是"没数据"冒充"有字段"',
    );
  });

  testWidgets('片段行显示单双周间隔与地点（§10.1 的"单双周"）', (tester) async {
    await pumpDetail(tester);

    expect(find.byKey(const Key('course-segment-evt-a')), findsOneWidget);
    expect(
      find.textContaining('每 2 周'),
      findsOneWidget,
      reason: '§10.1 要求展示"单双周"；间隔为 2 时必须能看出来',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 1（课程编辑完整性修复计划 §2.0）：**整门课程只有一个入口**
  //
  // 这一页此前有**两个**指向整门课程的按钮：「编辑课程」与「改时间」。后者只提交时间，
  // 标题与时区靠两张进程内缓存补齐，缓存里没有就写 `未命名事项` 与 `UTC`——
  // 用户只改一次钟点，课程名、教师、地点、领域、项目就都没了（计划 §1.1）。
  //
  // 处置：删掉「改时间」及其固定日期载体 `DateTime(2026, 1, 5)`，钟点编辑并入
  // 「编辑课程」——那里保存走 `previewCourseEdit()` → `saveCourse()` 的**单事务**链路。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**「改时间」入口已删除**（两个同义入口合并成一个安全事务入口）', (tester) async {
    await pumpDetail(tester);

    expect(
      find.byKey(const Key('course-edit-time')),
      findsNothing,
      reason:
          '它走的是只提交时间的 `CalendarService.replaceSeries` 循环：'
          '标题、教师、地点、领域、项目会在一次"只改钟点"的保存里全部丢失。'
          '移除它不等于删除功能——钟点编辑已并入「编辑课程」的单事务保存',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 1（课程与保护时间管理修复计划）：**整门课程资料编辑的入口**
  //
  // 计划 §1.1 记录的偏差：详情页的范围选择器**没有接进** `_editTime()`——
  // 无论用户选哪一项，代码都调 `editWholeCourse()`。也就是说"仅本次"是一个
  // **说了但没做**的选项，用户以为只改一次，实际改了整门课。
  //
  // 处置（计划 §2.1／§2.2）：详情页**删掉**那个汇总范围选择器，改为
  //   · 「编辑课程」→ 新的整门课程编辑页（资料 + 上课安排）；
  //   · 具体课次的范围编辑只能从**日历上的那一节**进入（那里才有真实发生时间）。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**详情页有「编辑课程」入口**（整门课程资料的唯一入口）', (tester) async {
    var opened = 0;
    await pumpDetail(tester, onEditCourse: () => opened++);

    final entry = find.byKey(const Key('course-edit-course'));
    expect(
      entry,
      findsOneWidget,
      reason:
          '计划 §2.1："课程管理页的『编辑课程』保存的是整个课程快照"。'
          '没有这个入口，用户就只能改钟点，名称/教师/地点/星期/周次全都改不了',
    );
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('**未装配编辑入口时不显示按钮**（不给点了没反应的入口）', (tester) async {
    await pumpDetail(tester);

    expect(
      find.byKey(const Key('course-edit-course')),
      findsNothing,
      reason: '与「改时间」同一条口径：没有去处就不留按钮',
    );
  });

  testWidgets('**详情页不再有全局范围选择器**（它说了但没做）', (tester) async {
    await pumpDetail(tester);

    expect(
      find.byKey(const Key('course-edit-scope')),
      findsNothing,
      reason:
          '计划 §2.1 最后一句：这个选择器"没有接进 `_editTime()`"——'
          '无论选哪一项都调 `editWholeCourse()`。留着它等于对用户说谎；'
          '范围编辑改由日历上的具体课次入口承担',
    );
  });
}

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5, 9);
}

final class _Ids implements IdGenerator {
  const _Ids();
  @override
  String next() => 'id';
}

final class _Courses implements CourseSeriesRepository {
  const _Courses(this.detail);
  final CourseSeriesDetail detail;

  @override
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) async => [
    detail.summary,
  ];

  @override
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) async =>
      detail.summary.logicalCourseId == logicalCourseId ? detail : null;

  @override
  Future<String?> currentTermId() async => 'term-autumn';
}

final class _NoopCalendar implements CalendarRepository, CalendarEventDeletion {
  const _NoopCalendar();

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

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
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    RecurrenceEditDraft? recurrence,
    DateTime? updateExceptionsFromUtc,
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

final class _NoopGateway implements CourseWriteGateway {
  const _NoopGateway();
  @override
  Future<CourseDeletionResult> deleteSeriesWithExceptions({
    required Set<String> anchorEventIds,
    required DateTime deletedAtUtc,
  }) async => CourseDeletionResult.empty;

  @override
  Future<int> countExceptions(String anchorEventId) async => 0;

  @override
  Future<int> countExceptionsInvalidatedBy({
    required String anchorEventId,
    required CourseScheduleDraft replacement,
    required String zoneId,
  }) async => 0;

  @override
  Future<void> replaceCourseSeries({
    required List<CourseWriteRow> rows,
    required CourseProfileDraft profile,
    required String zoneId,
    required DateTime updatedAtUtc,
    required CourseSeriesProvenance provenance,
    required String expectedFingerprint,
  }) async {}
}
