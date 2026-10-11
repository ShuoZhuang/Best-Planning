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
        title: '高等数学(上)',
        weekday: DateTime.monday,
        startMinute: 8 * 60,
        endMinute: 8 * 60 + 45,
        intervalWeeks: 2,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
        location: location,
      ),
    ],
  );

  Future<void> pumpDetail(
    WidgetTester tester, {
    String teacher = '赵敏',
    String location = 'D206',
    bool withZones = false,
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
              courses: _Courses(detail(teacher: teacher, location: location)),
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
            zones: withZones ? TimeZoneDatabase() : null,
            timeZoneId: withZones ? 'Asia/Shanghai' : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

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

  testWidgets('**未装配时区时不给「改时间」入口**（不给点了没反应的按钮）', (tester) async {
    await pumpDetail(tester);

    expect(
      find.byKey(const Key('course-edit-time')),
      findsNothing,
      reason:
          '对话框需要时区才能把本地钟点换算成 UTC 提议时段；'
          '没有它就只能"检测不到冲突"，那比没有按钮更糟',
    );
  });

  testWidgets('装配时区后出现「改时间」入口（§10.2 末条的界面入口）', (tester) async {
    await pumpDetail(tester, withZones: true);

    expect(
      find.byKey(const Key('course-edit-time')),
      findsOneWidget,
      reason:
          '规范 §10.2："修改课程时间…后必须重新检测冲突并预览。"'
          '这个入口此前**不存在**——`course_edit_dialog.dart` 是计划 Task 10 声明的交付物',
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
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
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
  Future<void> deleteSeriesWithExceptions(Set<String> anchorEventIds) async {}
}
