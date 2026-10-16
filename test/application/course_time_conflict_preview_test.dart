// 1.8.0（设计规范 §10.2 最后一条）：`CourseManagementService.previewTimeChange`。
//
// 纯函数的判据由 `course_time_conflict_test.dart` 逐值钉住；本文件钉的是**服务层的接线**——
// 它要读既有占用、要排除这门课自己的其它片段与**被编辑的锚点**。
// 后者是最容易写错的一处：不排除锚点自己的旧位置，"把课挪一下"就永远报冲突。
//
// 用替身仓库而不是真库：这一层被测的是"读什么、排除谁"，
// 真库的展开行为已由 `course_series_repository_test.dart` 与日历仓储的用例覆盖。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';

void main() {
  final day = DateTime.utc(2026, 10, 12);
  DateTime at(int hour) => day.add(Duration(hours: hour));

  CalendarOccurrence occurrence({
    required String id,
    required int startHour,
    required int endHour,
    String title = '已有安排',
    CalendarEventKind kind = CalendarEventKind.fixed,
    String? logicalCourseId,
  }) => CalendarOccurrence(
    eventId: id,
    title: title,
    range: TimeRange(startUtc: at(startHour), endUtc: at(endHour)),
    locked: true,
    kind: kind,
    logicalCourseId: logicalCourseId,
  );

  CourseManagementService service({
    required List<CalendarOccurrence> existing,
    required CourseSeriesDetail? detail,
  }) => CourseManagementService(
    courses: _Courses(detail),
    calendar: CalendarService(
      repository: _Calendar(existing),
      clock: const _Clock(),
      idGenerator: const _Ids(),
      zones: TimeZoneDatabase(),
    ),
    deletion: const _NoopDeletion(),
    gateway: const _NoopGateway(),
  );

  CourseSeriesDetail detailWithSegments(List<String> eventIds) =>
      CourseSeriesDetail(
        summary: CourseSeriesSummary(
          logicalCourseId: 'course-calc',
          title: '高等数学(上)',
          termId: 'term-autumn',
          anchorEventIds: eventIds,
          weekday: DateTime.monday,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          weekSpans: const [WeekSpan(startWeek: 1, endWeek: 16)],
        ),
        segments: [
          for (final id in eventIds)
            CourseSeriesSegment(
              eventId: id,
              timeZoneId: 'Asia/Shanghai',
              title: '高等数学(上)',
              weekday: DateTime.monday,
              startMinute: 9 * 60,
              endMinute: 10 * 60,
              intervalWeeks: 1,
              validFromLocalDate: DateTime(2026, 9, 7),
              updatedAtUtc: DateTime.utc(2026, 10, 1),
            ),
        ],
      );

  test('把课挪到空着的位置时没有冲突（锚点自己的旧位置被排除）', () async {
    // **这条就是最容易写错的那一处**：库里既有"这门课自己 09:00–10:00 的锚点"，
    // 而我们要把它挪到 14:00–15:00。若不排除锚点自己的旧位置，
    // 提议时段与它并不重叠（14:00 vs 09:00），其实不会误报；
    // 因此下面那条"原地不动"的用例才是真正咬人的。
    final found =
        await service(
          existing: [
            occurrence(
              id: 'evt-own',
              startHour: 9,
              endHour: 10,
              title: '高等数学(上)',
              logicalCourseId: 'course-calc',
            ),
          ],
          detail: detailWithSegments(['evt-own']),
        ).previewTimeChange(
          logicalCourseId: 'course-calc',
          proposed: [
            (
              eventId: 'evt-own',
              range: TimeRange(startUtc: at(14), endUtc: at(15)),
            ),
          ],
        );

    expect(found, isEmpty);
  });

  test('**原地不动**时不报冲突（若把锚点自己当障碍，这条必然失败）', () async {
    final found =
        await service(
          existing: [
            occurrence(
              id: 'evt-own',
              startHour: 9,
              endHour: 10,
              title: '高等数学(上)',
              logicalCourseId: 'course-calc',
            ),
          ],
          detail: detailWithSegments(['evt-own']),
        ).previewTimeChange(
          logicalCourseId: 'course-calc',
          proposed: [
            (
              eventId: 'evt-own',
              range: TimeRange(startUtc: at(9), endUtc: at(10)),
            ),
          ],
        );

    expect(found, isEmpty, reason: '提议时段与锚点自己的旧位置完全相同；不排除它就等于"保存"永远报冲突');
  });

  test('挪到与**同一门课另一个片段**重叠时报 sameCourse', () async {
    final found =
        await service(
          existing: [
            occurrence(
              id: 'evt-own',
              startHour: 9,
              endHour: 10,
              title: '高等数学(上)',
              logicalCourseId: 'course-calc',
            ),
            occurrence(
              id: 'evt-own-b',
              startHour: 14,
              endHour: 15,
              title: '高等数学(上)',
              logicalCourseId: 'course-calc',
            ),
          ],
          detail: detailWithSegments(['evt-own', 'evt-own-b']),
        ).previewTimeChange(
          logicalCourseId: 'course-calc',
          // 只改第一个片段，把它挪到第二个片段上。
          proposed: [
            (
              eventId: 'evt-own',
              range: TimeRange(startUtc: at(14), endUtc: at(15)),
            ),
          ],
        );

    expect(found, hasLength(1));
    expect(found.single.kind, CourseTimeConflictKind.sameCourse);
  });

  test('挪到与保护时间重叠时报 protectedTime（这一类最严重）', () async {
    final found =
        await service(
          existing: [
            occurrence(
              id: 'evt-own',
              startHour: 9,
              endHour: 10,
              title: '高等数学(上)',
              logicalCourseId: 'course-calc',
            ),
            occurrence(
              id: 'evt-lunch',
              startHour: 12,
              endHour: 13,
              title: '午餐',
              kind: CalendarEventKind.protected,
            ),
          ],
          detail: detailWithSegments(['evt-own']),
        ).previewTimeChange(
          logicalCourseId: 'course-calc',
          proposed: [
            (
              eventId: 'evt-own',
              range: TimeRange(startUtc: at(12), endUtc: at(13)),
            ),
          ],
        );

    expect(found.single.kind, CourseTimeConflictKind.protectedTime);
    expect(found.single.title, '午餐');
  });

  test('挪到与别的课重叠时报 otherCourse', () async {
    final found =
        await service(
          existing: [
            occurrence(
              id: 'evt-own',
              startHour: 9,
              endHour: 10,
              title: '高等数学(上)',
              logicalCourseId: 'course-calc',
            ),
            occurrence(
              id: 'evt-physics',
              startHour: 14,
              endHour: 15,
              title: '大学物理',
              logicalCourseId: 'course-physics',
            ),
          ],
          detail: detailWithSegments(['evt-own']),
        ).previewTimeChange(
          logicalCourseId: 'course-calc',
          proposed: [
            (
              eventId: 'evt-own',
              range: TimeRange(startUtc: at(14), endUtc: at(15)),
            ),
          ],
        );

    expect(found.single.kind, CourseTimeConflictKind.otherCourse);
    expect(found.single.title, '大学物理');
  });

  test('课程不存在时返回空清单，而不是抛异常', () async {
    final found = await service(existing: const [], detail: null)
        .previewTimeChange(
          logicalCourseId: 'nope',
          proposed: [
            (
              eventId: 'evt-own',
              range: TimeRange(startUtc: at(9), endUtc: at(10)),
            ),
          ],
        );

    expect(found, isEmpty);
  });

  test('提议为空时返回空清单，且**不去读库**', () async {
    final calendar = _Calendar(const []);
    final found = await CourseManagementService(
      courses: _Courses(detailWithSegments(['evt-own'])),
      calendar: CalendarService(
        repository: calendar,
        clock: const _Clock(),
        idGenerator: const _Ids(),
        zones: TimeZoneDatabase(),
      ),
      deletion: const _NoopDeletion(),
      gateway: const _NoopGateway(),
    ).previewTimeChange(logicalCourseId: 'course-calc', proposed: const []);

    expect(found, isEmpty);
    expect(calendar.readCount, 0, reason: '没有提议就没有可查的时段；空跑一次读库是白费');
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

final class _Calendar implements CalendarRepository {
  _Calendar(this.items);
  final List<CalendarOccurrence> items;

  /// 读了几次——用于断言"空提议不查库"。
  int readCount = 0;

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    readCount++;
    return [
      for (final item in items)
        if (item.range.overlaps(TimeRange(startUtc: startUtc, endUtc: endUtc)))
          item,
    ];
  }

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
  Future<void> deleteSeriesWithExceptions(Set<String> anchorEventIds) async {}

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
