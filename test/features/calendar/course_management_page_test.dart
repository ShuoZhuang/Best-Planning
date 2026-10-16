// 1.8.0（设计规范 §10.1，计划 Task 10）：按学期列出的课程管理页。
//
// 修复前的缺陷（§2.4）：导入课程只有"从某一天改一次"的入口，产品没有按学期列出的课程
// 管理页。用户要改"那门课时间错了"，得先知道它在哪一天，再翻到那天点卡片。
//
// 与仓储层的分工：聚合查询的 SQL 行为由 `course_series_repository_test.dart` 用真库守着，
// 本文件只钉**页面**——列什么、怎么显示、点进去带什么 id、空状态说什么。
//
// 用**只读仓储替身**而不是替身 `CourseManagementService`：后者是具体类，
// 用 `noSuchMethod` 去 stub 具体类既脆弱又绕（第一版那么写，analyzer 直接拒绝）。
// 页面本来只调 `currentTermId` / `listCourses` 两个查询，替身仓储正好够。
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
import 'package:personal_planner/features/calendar/courses/course_management_page.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required List<CourseSeriesSummary> courses,
    void Function(String)? onOpenCourse,
    VoidCallback? onImportTimetable,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: CourseManagementPage(
            service: CourseManagementService(
              courses: _Courses(courses),
              calendar: CalendarService(
                repository: const _NoopCalendar(),
                clock: const _Clock(),
                idGenerator: const _Ids(),
                zones: TimeZoneDatabase(),
              ),
              deletion: const _NoopDeletion(),
              gateway: const _NoopGateway(),
            ),
            onOpenCourse: onOpenCourse,
            onImportTimetable: onImportTimetable,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('列出课程，每行带星期、时间、周次、地点与教师', (tester) async {
    await pumpPage(tester, courses: [_calcCourse]);

    expect(find.text('管理课程'), findsOneWidget);
    expect(find.text('高等数学(上)'), findsOneWidget);
    final summary = tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const Key('course-course-calc-a')),
            matching: find.textContaining('周一 08:00–08:45'),
          ),
        )
        .data;
    expect(summary, contains('1-16 周单'));
    expect(summary, contains('D206'));
    expect(summary, contains('赵敏'));
  });

  testWidgets('同名不同 logicalCourseId 的课程各占一行，且箭头带各自的 id', (tester) async {
    final opened = <String>[];
    await pumpPage(
      tester,
      courses: [_calcCourse, _calcCourseB],
      onOpenCourse: opened.add,
    );

    expect(find.text('高等数学(上)'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('manage-course-course-calc-b')));
    await tester.pumpAndSettle();

    expect(opened, [
      'course-calc-b',
    ], reason: '深链必须带 logicalCourseId，否则会打开同名的另一门课');
  });

  testWidgets('没有课程时给出空状态与「导入课表」入口', (tester) async {
    var imports = 0;
    await pumpPage(
      tester,
      courses: const [],
      onImportTimetable: () => imports++,
    );

    expect(find.byKey(const Key('course-empty')), findsOneWidget);
    expect(find.textContaining('还没有课程'), findsOneWidget);
    await tester.tap(find.byKey(const Key('course-empty-import')));
    await tester.pumpAndSettle();
    expect(imports, 1);
  });

  testWidgets('未注入打开回调时不给箭头（不给死入口）', (tester) async {
    await pumpPage(tester, courses: [_calcCourse]);

    expect(
      find.byKey(const Key('manage-course-course-calc-a')),
      findsNothing,
      reason: '端口为空时不显示那个箭头',
    );
  });

  testWidgets('未注入导入回调时空状态不给「导入课表」按钮', (tester) async {
    await pumpPage(tester, courses: const []);

    expect(find.byKey(const Key('course-empty-import')), findsNothing);
  });
}

CourseSeriesSummary get _calcCourse => CourseSeriesSummary(
  logicalCourseId: 'course-calc-a',
  title: '高等数学(上)',
  termId: 'term-autumn',
  anchorEventIds: const ['evt-a-odd', 'evt-a-even'],
  weekday: DateTime.monday,
  startMinute: 8 * 60,
  endMinute: 8 * 60 + 45,
  weekSpans: const [
    WeekSpan(startWeek: 1, endWeek: 16, parity: WeekParity.odd),
  ],
  location: 'D206',
  teacher: '赵敏',
);

CourseSeriesSummary get _calcCourseB => CourseSeriesSummary(
  logicalCourseId: 'course-calc-b',
  title: '高等数学(上)',
  termId: 'term-autumn',
  anchorEventIds: const ['evt-b-odd'],
  weekday: DateTime.tuesday,
  startMinute: 10 * 60,
  endMinute: 10 * 60 + 45,
  weekSpans: const [WeekSpan(startWeek: 1, endWeek: 16)],
  location: 'E101',
);

final class _Courses implements CourseSeriesRepository {
  const _Courses(this.courses);
  final List<CourseSeriesSummary> courses;

  @override
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) async => [
    for (final course in courses)
      if (termId == null || course.termId == termId) course,
  ];

  @override
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) async => null;

  @override
  // 与页面默认查询一致：页面先问 currentTermId() 再按它过滤，_calcCourse 的
  // 	ermId 正是这个值，因此替身也必须报同一个学期——两边不一致会让列表看起来是空的。
  Future<String?> currentTermId() async => 'term-autumn';
}

final class _NoopCalendar implements CalendarRepository {
  const _NoopCalendar();
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];
  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _NoopDeletion implements CalendarEventDeletion {
  const _NoopDeletion();

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

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 1);
}

final class _Ids implements IdGenerator {
  const _Ids();
  @override
  String next() => 'id';
}
