// 1.8.0（设计规范 §10.2 第三条）：`editWholeCourse` 的**时间映射**。
//
// 规范原文："编辑整个课程：修改该逻辑课程在当前学期内的全部系列片段。"
//
// 单双周课程在库里就是**几段各有自己星期与钟点**的规则（周一一段、周四一段）。
// "改整个课程"要改的是**这门课的时间**，而**不是**把几段压成同一段——
// 后者会让周一与周四的课都跑到周一去，等于每周少上一次课。
//
// 这一条此前没有用例：`course_management_service_test.dart` 只断言了
// "调用了两次 `replaceSeries`"（块数对），**没有断言两个片段分别落在哪里**。
// 那正是本文件要补的：**每段保留自己的星期，只把钟点换成新的**。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';

void main() {
  late _DeletionSpy deletion;

  setUp(() => deletion = _DeletionSpy());

  CourseManagementService service(CourseSeriesDetail? detail) =>
      CourseManagementService(
        courses: _Courses(detail),
        calendar: CalendarService(
          repository: const _NoopCalendar(),
          deletion: deletion,
          clock: const _Clock(),
          idGenerator: const _Ids(),
          zones: TimeZoneDatabase(),
        ),
        deletion: deletion,
        gateway: const _NoopGateway(),
      );

  /// 单双周：周一 08:00 一段、周四 10:00 一段（本地 UTC+0，便于逐值断言）。
  CourseSeriesDetail twoSegments() => CourseSeriesDetail(
    summary: CourseSeriesSummary(
      logicalCourseId: 'course-calc',
      title: '高等数学(上)',
      termId: 'term-autumn',
      anchorEventIds: const ['evt-mon', 'evt-thu'],
      weekday: DateTime.monday,
      startMinute: 8 * 60,
      endMinute: 8 * 60 + 45,
      weekSpans: const [WeekSpan(startWeek: 1, endWeek: 16)],
    ),
    segments: [
      CourseSeriesSegment(
        eventId: 'evt-mon',
        title: '高等数学(上)',
        weekday: DateTime.monday,
        startMinute: 8 * 60,
        endMinute: 8 * 60 + 45,
        intervalWeeks: 1,
        validFromLocalDate: DateTime(2026, 9, 7),
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      CourseSeriesSegment(
        eventId: 'evt-thu',
        title: '高等数学(上)',
        weekday: DateTime.thursday,
        startMinute: 10 * 60,
        endMinute: 10 * 60 + 45,
        intervalWeeks: 1,
        validFromLocalDate: DateTime(2026, 9, 7),
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
    ],
  );

  test('改整个课程时**每一段保留自己的星期与日期**，只换钟点', () async {
    // 2026-09-07 是周一，09-10 是周四。
    final monday = DateTime.utc(2026, 9, 7, 14);
    final thursday = DateTime.utc(2026, 9, 10, 14);

    await service(twoSegments()).editWholeCourse(
      logicalCourseId: 'course-calc',
      newStartUtc: monday,
      newEndUtc: monday.add(const Duration(minutes: 45)),
    );

    expect(deletion.replaceSeriesCalls, hasLength(2));
    final byAnchor = {
      for (final call in deletion.replaceSeriesCalls) call.$1: call.$2,
    };
    expect(byAnchor['evt-mon'], monday, reason: '周一那一段应当落在周一的新钟点上');
    expect(
      byAnchor['evt-thu'],
      thursday,
      reason: '周四那一段必须**留在周四**；把它也放到周一会让每周少上一次课',
    );
  });

  test('两段**不会**被压到同一个时刻', () async {
    final monday = DateTime.utc(2026, 9, 7, 14);

    await service(twoSegments()).editWholeCourse(
      logicalCourseId: 'course-calc',
      newStartUtc: monday,
      newEndUtc: monday.add(const Duration(minutes: 45)),
    );

    final starts = [for (final call in deletion.replaceSeriesCalls) call.$2];
    expect(starts.toSet(), hasLength(2), reason: '两段的开始时刻必须不同——相同就意味着两段叠在了一起');
  });

  test('单片段课程仍然落在给定的时刻上（不为多片段牺牲简单情形）', () async {
    final detail = CourseSeriesDetail(
      summary: twoSegments().summary,
      segments: [twoSegments().segments.first],
    );
    final monday = DateTime.utc(2026, 9, 7, 14);

    await service(detail).editWholeCourse(
      logicalCourseId: 'course-calc',
      newStartUtc: monday,
      newEndUtc: monday.add(const Duration(minutes: 45)),
    );

    expect(deletion.replaceSeriesCalls.single.$2, monday);
  });
}

final class _Courses implements CourseSeriesRepository {
  _Courses(this.detail);
  final CourseSeriesDetail? detail;

  @override
  Future<List<CourseSeriesSummary>> listCourses({String? termId}) async =>
      detail == null ? const [] : [detail!.summary];

  @override
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId) async =>
      detail?.summary.logicalCourseId == logicalCourseId ? detail : null;

  @override
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

final class _DeletionSpy implements CalendarEventDeletion {
  /// (anchorId, newStartUtc, newEndUtc)
  final List<(String, DateTime, DateTime)> replaceSeriesCalls = [];

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventEditDraft event,
    RecurrenceEditDraft? recurrence,
    DateTime? updateExceptionsFromUtc,
    required DateTime updatedAtUtc,
  }) async {
    replaceSeriesCalls.add((anchorId, event.startAtUtc, event.endAtUtc));
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
    required CalendarEventEditDraft event,
    required String exceptionId,
    required DateTime updatedAtUtc,
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

final class _NoopGateway implements CourseWriteGateway {
  const _NoopGateway();
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
  }) async {}
}

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 12, 4);
}

final class _Ids implements IdGenerator {
  const _Ids();
  @override
  String next() => 'id';
}
