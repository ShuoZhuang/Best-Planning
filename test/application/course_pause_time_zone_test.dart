// 1.8.0（设计规范 §10.2 第四条）：`pauseFrom` 的**截断日期**必须落在用户说的那一天。
//
// 规范原文："暂停课程：从指定本地日期起停止生成，但保留历史。"
//
// `pauseFrom` 把"停用日所在周的上一周周日"当作切点，交给
// `deleteFollowingOccurrences(occurrenceStartUtc: ...)`。而后者的契约是
// **按该时刻在规则自己时区里的本地日期**去截断（见 `_validatedSplitDate`）。
//
// 于是问题来了：`pauseFrom` 用一个 `DateTime.utc(y, m, d)`（UTC 零点）表达"那一天"。
// 当时区是**负偏移**时，`2026-10-18 00:00Z` 在 America/New_York 是 `2026-10-17 20:00`
// ——**本地日期变成了前一天**，截断因此早了一天：该停的那一周还留着一次课。
//
// 东八区（本项目的主用例）看不出来：`+08:00` 之下 UTC 零点仍是同一天。
// 这正是"只在别的时区表现为结果错误、不报错"的那一类缺陷（规范 §3 第 1 条点名过它）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/course_series_repository.dart';
import 'package:personal_planner/domain/repositories/course_write_gateway.dart';

void main() {
  late _DeletionSpy deletion;
  final zones = TimeZoneDatabase();

  setUp(() => deletion = _DeletionSpy());

  /// 一段**起点在 2026-09-07（周一）**、每周一的规则，学期到 12-20。
  CourseSeriesDetail oneSegment() => CourseSeriesDetail(
    summary: CourseSeriesSummary(
      logicalCourseId: 'course-calc',
      title: '高等数学(上)',
      termId: 'term-autumn',
      anchorEventIds: const ['evt-mon'],
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
        validUntilLocalDate: DateTime(2026, 12, 20),
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
    ],
  );

  CourseManagementService service(
    CourseSeriesDetail detail, {
    required String timeZoneId,
  }) => CourseManagementService(
    courses: _Courses(detail),
    calendar: CalendarService(
      repository: const _NoopCalendar(),
      deletion: deletion,
      clock: const _Clock(),
      idGenerator: const _Ids(),
      zones: zones,
    ),
    deletion: deletion,
    gateway: const _NoopGateway(),
    // 1.8.0：`pauseFrom` 必须知道"用户说的是哪个时区的哪一天"。
    // **两个都要给**：只给 `timeZoneId` 而没有 `zones`，实现会退回 UTC 零点兜底，
    // 测试就验不到真正的换算路径（第一版正是如此，于是红了两次、原因看起来像实现没改）。
    zones: zones,
    timeZoneId: timeZoneId,
  );

  test('东八区：切点的本地日期就是"停用日所在周的上一周周日"', () async {
    await service(oneSegment(), timeZoneId: 'Asia/Shanghai').pauseFrom(
      logicalCourseId: 'course-calc',
      // 2026-10-21 是周三 ⇒ 该周周一 10-19、上一周周日 10-18。
      fromLocalDate: DateTime(2026, 10, 21),
    );

    final instant = deletion.deleteFollowingCalls.single.$2;
    expect(
      zones.toLocal(instant, 'Asia/Shanghai').day,
      18,
      reason: '东八区下这个断言本来就会通过——它不是本文件要抓的缺陷',
    );
    expect(zones.toLocal(instant, 'Asia/Shanghai').month, 10);
  });

  test('**西五区：切点的本地日期不能因为负偏移而退到前一天**', () async {
    await service(oneSegment(), timeZoneId: 'America/New_York').pauseFrom(
      logicalCourseId: 'course-calc',
      fromLocalDate: DateTime(2026, 10, 21),
    );

    final instant = deletion.deleteFollowingCalls.single.$2;
    final local = zones.toLocal(instant, 'America/New_York');

    expect(local.month, 10, reason: '切点必须落在 10 月，而不是因为负偏移掉到 9 月或 11 月');
    expect(
      local.day,
      18,
      reason:
          '切点的**本地日期**必须是 10-18；用 UTC 零点表达会让它变成 10-17，'
          '于是该停的那一周还留着一次课——而且不报错',
    );
  });

  test('西五区：切点必须正好落在**本地**零点或当天之内，不能落到前一天傍晚', () async {
    await service(oneSegment(), timeZoneId: 'America/New_York').pauseFrom(
      logicalCourseId: 'course-calc',
      fromLocalDate: DateTime(2026, 10, 21),
    );

    final local = zones.toLocal(
      deletion.deleteFollowingCalls.single.$2,
      'America/New_York',
    );

    expect(
      local.hour,
      0,
      reason:
          '用"当天本地零点"表达那一天是最不容易误解的写法；'
          '落到 20:00 说明它是 UTC 零点被换算过来的',
    );
  });

  test('**未装配时区时退回 UTC 零点**——记录兜底行为，以免它被误当成"正确"', () async {
    // 这一条是**故意**钉住兜底的：生产组合根（`main.dart`）必须传 `zones` 与
    // `timeZoneId`，否则真实的暂停会走这条兜底、在负偏移时区下早截一天。
    //
    // 加它的原因很具体：实现改对之后，"只给 `timeZoneId` 而不给 `zones`"的构造方式
    // 仍然退回兜底，而**全量 1850 条用例全绿**——因为它们都不带时区组合去调 `pauseFrom`。
    // "实现对了"与"生产接上了"是两件事，这条用例把后者的边界写下来。
    await CourseManagementService(
      courses: _Courses(oneSegment()),
      calendar: CalendarService(
        repository: const _NoopCalendar(),
        deletion: deletion,
        clock: const _Clock(),
        idGenerator: const _Ids(),
        zones: zones,
      ),
      deletion: deletion,
      gateway: const _NoopGateway(),
      // 刻意只给 timeZoneId，不给 zones。
      timeZoneId: 'America/New_York',
    ).pauseFrom(
      logicalCourseId: 'course-calc',
      fromLocalDate: DateTime(2026, 10, 21),
    );

    final local = zones.toLocal(
      deletion.deleteFollowingCalls.single.$2,
      'America/New_York',
    );
    expect(local.day, 17, reason: '兜底就是 UTC 零点：本地日期退到前一天。看到 17 说明兜底被触发了');
  });
}

final class _Courses implements CourseSeriesRepository {
  _Courses(this.detail);
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
  /// (anchorId, occurrenceStartUtc)
  final List<(String, DateTime)> deleteFollowingCalls = [];

  @override
  Future<void> deleteFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime updatedAtUtc,
  }) async {
    deleteFollowingCalls.add((anchorId, occurrenceStartUtc));
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
    DateTime? updateExceptionsFromUtc,
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
