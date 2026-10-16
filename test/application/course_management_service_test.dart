// 1.8.0（设计规范 §10.2，计划 Task 9 Step 2／3）：课程管理命令的范围语义与事务。
//
// 用替身而不是真库：这一层被测的是**范围解析**——"仅本次 / 此次及以后 / 整个课程"
// 分别该碰哪些锚点。那是纯粹的编排逻辑，真库只会让断言更难读。
// 仓储层的 SQL 行为由 `course_series_repository_test.dart` 用真库守着。
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
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';

void main() {
  late _DeletionSpy deletion;
  late _GatewaySpy gateway;
  late CourseManagementService service;

  setUp(() {
    deletion = _DeletionSpy();
    gateway = _GatewaySpy();
    service = CourseManagementService(
      courses: _Courses(_twoSegmentCourse),
      calendar: CalendarService(
        repository: _NoopCalendar(),
        deletion: deletion,
        clock: const _Clock(),
        idGenerator: _Ids(),
        zones: TimeZoneDatabase(),
      ),
      deletion: deletion,
      gateway: gateway,
    );
  });

  test('previewDelete 报出片段数与**具体次数**', () async {
    final preview = await service.previewDelete('course-calc');

    expect(preview, isNotNull);
    expect(preview!.title, '高等数学(上)');
    expect(preview.affectedSeriesCount, 2);
    expect(
      preview.affectedOccurrenceCount,
      greaterThan(preview.affectedSeriesCount),
      reason: '只报"2 条系列"没有意义——用户要看懂的是"还剩多少次课"',
    );
  });

  test('deleteCourse 把全部锚点交给网关，一次事务删干净', () async {
    final result = await service.deleteCourse('course-calc');

    expect(result.isSuccess, isTrue);
    expect(gateway.deletedSets.single, {
      'evt-odd',
      'evt-even',
    }, reason: '锚点必须一次全交出去，否则删到一半会留下孤儿例外');
  });

  test('pauseFrom 按周截断到停用日所在周的上一周周日', () async {
    final result = await service.pauseFrom(
      logicalCourseId: 'course-calc',
      // 2026-10-21 是周三 ⇒ 该周周一 10-19、上一周周日 10-18。
      fromLocalDate: DateTime(2026, 10, 21),
    );

    expect(result.isSuccess, isTrue);
    expect(deletion.deleteFollowingCalls, hasLength(2));
    for (final call in deletion.deleteFollowingCalls) {
      expect(
        call.$2,
        DateTime.utc(2026, 10, 18),
        reason: '切点是"停用日所在周的上一周周日"，不是停用日本身',
      );
    }
  });

  test('已经结束的片段在 pauseFrom 里不再动一次', () async {
    final service = CourseManagementService(
      courses: _Courses(_endedCourse),
      calendar: CalendarService(
        repository: _NoopCalendar(),
        deletion: deletion,
        clock: const _Clock(),
        idGenerator: _Ids(),
        zones: TimeZoneDatabase(),
      ),
      deletion: deletion,
      gateway: gateway,
    );

    final result = await service.pauseFrom(
      logicalCourseId: 'course-ended',
      fromLocalDate: DateTime(2026, 10, 21),
    );

    expect(result.isSuccess, isTrue);
    expect(
      deletion.deleteFollowingCalls,
      isEmpty,
      reason: '再截一次会凭空记一条重排原因（统计里会多出一条实际没发生的变更）',
    );
  });

  test('找不到课程时每条命令都给出原因而不是抛异常', () async {
    final missing = CourseManagementService(
      courses: _Courses(null),
      calendar: CalendarService(
        repository: _NoopCalendar(),
        deletion: deletion,
        clock: const _Clock(),
        idGenerator: _Ids(),
        zones: TimeZoneDatabase(),
      ),
      deletion: deletion,
      gateway: gateway,
    );

    expect((await missing.previewDelete('nope')), isNull);
    expect((await missing.deleteCourse('nope')).error, contains('找不到'));
    expect(
      (await missing.saveCourse(
        CourseSaveRequest(
          logicalCourseId: 'nope',
          expectedRevisions: const {},
          expectedFingerprint: '',
          profile: CourseProfileDraft(
            logicalCourseId: 'nope',
            title: '不存在的课',
            schedule: [
              CourseScheduleDraft(
                startMinute: 8 * 60,
                endMinute: 9 * 60,
                weekdays: const {DateTime.monday},
                validFromLocalDate: DateTime(2026, 9, 7),
              ),
            ],
          ),
        ),
      )).error,
      contains('已删除或链接过期'),
    );
  });
}

/// 两个片段的课程（单双周），加一个"同名另一门课"的锚点用于串台测试。
CourseSeriesDetail get _twoSegmentCourse => CourseSeriesDetail(
  summary: CourseSeriesSummary(
    logicalCourseId: 'course-calc',
    title: '高等数学(上)',
    termId: 'term-autumn',
    anchorEventIds: const ['evt-odd', 'evt-even'],
    weekday: DateTime.monday,
    startMinute: 8 * 60,
    endMinute: 8 * 60 + 45,
    weekSpans: const [
      WeekSpan(startWeek: 1, endWeek: 16, parity: WeekParity.odd),
      WeekSpan(startWeek: 1, endWeek: 16, parity: WeekParity.even),
    ],
  ),
  segments: [
    CourseSeriesSegment(
      eventId: 'evt-odd',
      timeZoneId: 'Asia/Shanghai',
      title: '高等数学(上)',
      weekday: DateTime.monday,
      startMinute: 8 * 60,
      endMinute: 8 * 60 + 45,
      intervalWeeks: 2,
      validFromLocalDate: DateTime(2026, 9, 7),
      validUntilLocalDate: DateTime(2026, 12, 20),
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    ),
    CourseSeriesSegment(
      eventId: 'evt-even',
      timeZoneId: 'Asia/Shanghai',
      title: '高等数学(上)',
      weekday: DateTime.thursday,
      startMinute: 8 * 60,
      endMinute: 8 * 60 + 45,
      intervalWeeks: 2,
      validFromLocalDate: DateTime(2026, 9, 7),
      validUntilLocalDate: DateTime(2026, 12, 20),
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    ),
  ],
);

/// 已经结束的课程：`validUntil` 早于停用日。
CourseSeriesDetail get _endedCourse => CourseSeriesDetail(
  summary: CourseSeriesSummary(
    logicalCourseId: 'course-ended',
    title: '已结束的课',
    termId: 'term-autumn',
    anchorEventIds: const ['evt-ended'],
    weekday: DateTime.monday,
    startMinute: 8 * 60,
    endMinute: 9 * 60,
    weekSpans: const [WeekSpan(startWeek: 1, endWeek: 4)],
  ),
  segments: [
    CourseSeriesSegment(
      eventId: 'evt-ended',
      timeZoneId: 'Asia/Shanghai',
      title: '已结束的课',
      weekday: DateTime.monday,
      startMinute: 8 * 60,
      endMinute: 9 * 60,
      intervalWeeks: 1,
      validFromLocalDate: DateTime(2026, 9, 7),
      validUntilLocalDate: DateTime(2026, 9, 28),
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    ),
  ],
);

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
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];
  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _DeletionSpy implements CalendarEventDeletion {
  /// 只保留 `deleteFollowingOccurrences` 的记录：`editOccurrence`／`editFollowing`／
  /// `editWholeCourse` 已被删除（计划 §2.0／Task 3 Step 6），只为它们存在的记录字段
  /// 随之去掉——留着"以后可能会用"的替身正是计划要求清理的东西。
  final List<(String, DateTime)> deleteFollowingCalls = [];

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
  }) async {
    deleteFollowingCalls.add((anchorId, occurrenceStartUtc));
  }

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

final class _GatewaySpy implements CourseWriteGateway {
  final List<Set<String>> deletedSets = [];

  @override
  Future<CourseDeletionResult> deleteSeriesWithExceptions({
    required Set<String> anchorEventIds,
    required DateTime deletedAtUtc,
  }) async {
    deletedSets.add(anchorEventIds);
    return CourseDeletionResult.empty;
  }

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
  var _next = 0;
  @override
  String next() => 'id-${_next++}';
}
