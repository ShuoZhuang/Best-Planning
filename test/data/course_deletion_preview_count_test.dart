// 1.8.0（设计规范 §10.2 第六条）：`previewDelete` 报出的**次数**必须与展开器一致。
//
// 规范原文："删除：先预览受影响次数，再二次确认。"
// 用户在确认框里看到的是"共 N 次课"——**这个数字必须是真的**，
// 因为它决定用户按不按下删除。
//
// `previewDelete` 的次数由 `_occurrenceCount` 自己算（周数 ÷ 间隔周数，向上取整），
// 而没有用展开器。**两份实现对同一件事就一定会分叉**，因此这里拿**真库 + 真实展开器**
// 当作唯一真相，逐值比对。
//
// 用真库的理由：展开行为（单双周、validUntil 的边界、例外）是仓储与展开器共同决定的，
// 替身证明不了它。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent, RecurrenceRule;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_course_series_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';

void main() {
  late AppDatabase database;
  late DriftCalendarRepository calendar;
  late CourseManagementService service;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    calendar = DriftCalendarRepository(database);
    service = CourseManagementService(
      courses: DriftCourseSeriesRepository(
        database,
        clock: _Clock(DateTime.utc(2026, 10, 12, 4)),
        zones: TimeZoneDatabase(),
        timeZoneId: 'Asia/Shanghai',
      ),
      calendar: CalendarService(
        repository: calendar,
        deletion: calendar,
        clock: _Clock(DateTime.utc(2026, 10, 12, 4)),
        idGenerator: const _Ids(),
        zones: TimeZoneDatabase(),
      ),
      deletion: calendar,
      gateway: calendar,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
    );

    await database.customInsert('''
      INSERT INTO academic_terms
        (id, name, first_week_monday_local_date, total_weeks, time_zone_id,
         created_at_utc, updated_at_utc)
      VALUES ('term-autumn', '2026 秋季学期', '2026-09-07', 16,
              'Asia/Shanghai', 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO timetable_import_batches
        (id, term_id, source_image_hash, source_file_name, status,
         created_event_count, created_at_utc, updated_at_utc)
      VALUES ('batch-autumn', 'term-autumn', 'sha256:x', 'schedule.png',
              'committed', 1, 1, 1)
    ''');
  });

  tearDown(() => database.close());

  Future<void> addSeries({
    required String eventId,
    required String ruleId,
    required String logicalCourseId,
    required DateTime validFrom,
    required DateTime validUntil,
    int intervalWeeks = 1,
    int weekday = DateTime.monday,
  }) async {
    await calendar.saveRecurring(
      CalendarEvent(
        id: eventId,
        title: '高等数学(上)',
        startAtUtc: DateTime.utc(2026, 9, 7, 0),
        endAtUtc: DateTime.utc(2026, 9, 7, 0, 45),
        timeZoneId: 'Asia/Shanghai',
        recurrenceRuleId: ruleId,
        sourceKind: CalendarEventSourceKind.timetableImport,
        importBatchId: 'batch-autumn',
        logicalCourseId: logicalCourseId,
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: ruleId,
        weekdays: {weekday},
        localStartMinute: 8 * 60,
        durationMinutes: 45,
        intervalWeeks: intervalWeeks,
        validFromLocalDate: validFrom,
        validUntilLocalDate: validUntil,
        timeZoneId: 'Asia/Shanghai',
      ),
    );
  }

  /// 展开器给出的**真相**：这门课在每个片段有效期内一共展开出多少次。
  Future<int> expandedCount(String logicalCourseId) async {
    final detail = await service.findCourse(logicalCourseId);
    expect(detail, isNotNull, reason: '前置条件：课程必须存在');
    var total = 0;
    for (final segment in detail!.segments) {
      final occurrences = await calendar.occurrencesBetween(
        // 覆盖从片段起点到终点的整个窗口，各边留一天。
        DateTime.utc(
          segment.validFromLocalDate.year,
          segment.validFromLocalDate.month,
          segment.validFromLocalDate.day - 1,
        ).subtract(const Duration(hours: 8)),
        DateTime.utc(
          segment.validUntilLocalDate!.year,
          segment.validUntilLocalDate!.month,
          segment.validUntilLocalDate!.day + 1,
        ).subtract(const Duration(hours: 8)),
      );
      total += occurrences.where((o) => o.eventId == segment.eventId).length;
    }
    return total;
  }

  test('单个每周片段：预览次数 == 展开次数', () async {
    await addSeries(
      eventId: 'evt-a',
      ruleId: 'rule-a',
      logicalCourseId: 'course-a',
      validFrom: DateTime(2026, 9, 7),
      validUntil: DateTime(2026, 12, 20),
    );

    final truth = await expandedCount('course-a');
    final preview = await service.previewDelete('course-a');

    expect(preview, isNotNull);
    expect(
      preview!.affectedOccurrenceCount,
      truth,
      reason: '用户看到的就是这个数字；它与展开器不一致就是谎报',
    );
  });

  test('**单双周的两段**：预览次数 == 两段展开次数之和', () async {
    await addSeries(
      eventId: 'evt-odd',
      ruleId: 'rule-odd',
      logicalCourseId: 'course-b',
      validFrom: DateTime(2026, 9, 7),
      validUntil: DateTime(2026, 12, 20),
      intervalWeeks: 2,
    );
    await addSeries(
      eventId: 'evt-even',
      ruleId: 'rule-even',
      logicalCourseId: 'course-b',
      validFrom: DateTime(2026, 9, 14),
      validUntil: DateTime(2026, 12, 20),
      intervalWeeks: 2,
      weekday: DateTime.thursday,
    );

    final truth = await expandedCount('course-b');
    final preview = await service.previewDelete('course-b');

    expect(
      preview!.affectedOccurrenceCount,
      truth,
      reason: '单双周是最容易被"周数 ÷ 间隔"算错的一类：两段各自只上一半的周',
    );
    expect(preview.affectedSeriesCount, 2);
  });

  test('**终点不是完整周**时预览次数仍然 == 展开次数', () async {
    // 09-07 起、09-30 止：跨 4 个日历周但最后一周只有到周三。
    await addSeries(
      eventId: 'evt-c',
      ruleId: 'rule-c',
      logicalCourseId: 'course-c',
      validFrom: DateTime(2026, 9, 7),
      validUntil: DateTime(2026, 9, 30),
    );

    final truth = await expandedCount('course-c');
    final preview = await service.previewDelete('course-c');

    expect(
      preview!.affectedOccurrenceCount,
      truth,
      reason: '终点落在周中时，"周数"怎么算最容易与展开器分叉',
    );
  });

  test('只有一次课（起点 == 终点）时预览次数是 1', () async {
    await addSeries(
      eventId: 'evt-once',
      ruleId: 'rule-once',
      logicalCourseId: 'course-once',
      validFrom: DateTime(2026, 9, 7),
      validUntil: DateTime(2026, 9, 7),
    );

    final preview = await service.previewDelete('course-once');

    expect(preview!.affectedOccurrenceCount, 1);
    expect(preview.affectedSeriesCount, 1);
  });

  test('**起点不是周一**（周三开始）时预览次数仍 == 展开次数', () async {
    // `validFromLocalDate` 不一定落在那一周的周一；"周数"怎么数就取决于实现。
    await addSeries(
      eventId: 'evt-wed',
      ruleId: 'rule-wed',
      logicalCourseId: 'course-wed',
      validFrom: DateTime(2026, 9, 9),
      validUntil: DateTime(2026, 12, 20),
      weekday: DateTime.wednesday,
    );

    final truth = await expandedCount('course-wed');
    final preview = await service.previewDelete('course-wed');

    expect(preview!.affectedOccurrenceCount, truth);
  });

  test('**间隔 3 周**时预览次数仍 == 展开次数', () async {
    await addSeries(
      eventId: 'evt-3w',
      ruleId: 'rule-3w',
      logicalCourseId: 'course-3w',
      validFrom: DateTime(2026, 9, 7),
      validUntil: DateTime(2026, 12, 20),
      intervalWeeks: 3,
    );

    final truth = await expandedCount('course-3w');
    final preview = await service.previewDelete('course-3w');

    expect(
      preview!.affectedOccurrenceCount,
      truth,
      reason: '向上取整在间隔 3 时与间隔 2 的表现不同；这类分歧只在非 1、2 时暴露',
    );
  });

  test('**三段、间隔各不相同**时预览次数仍 == 展开次数之和', () async {
    await addSeries(
      eventId: 'evt-s1',
      ruleId: 'rule-s1',
      logicalCourseId: 'course-multi',
      validFrom: DateTime(2026, 9, 7),
      validUntil: DateTime(2026, 10, 26),
    );
    await addSeries(
      eventId: 'evt-s2',
      ruleId: 'rule-s2',
      logicalCourseId: 'course-multi',
      validFrom: DateTime(2026, 9, 14),
      validUntil: DateTime(2026, 11, 30),
      intervalWeeks: 2,
      weekday: DateTime.tuesday,
    );
    await addSeries(
      eventId: 'evt-s3',
      ruleId: 'rule-s3',
      logicalCourseId: 'course-multi',
      validFrom: DateTime(2026, 10, 1),
      validUntil: DateTime(2026, 12, 20),
      intervalWeeks: 3,
      weekday: DateTime.friday,
    );

    final truth = await expandedCount('course-multi');
    final preview = await service.previewDelete('course-multi');

    expect(preview!.affectedSeriesCount, 3);
    expect(
      preview.affectedOccurrenceCount,
      truth,
      reason: '三段不同间隔时逐段比较才看得出是哪一段算错',
    );
  });
}

final class _Clock implements Clock {
  const _Clock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  const _Ids();
  @override
  String next() => 'id';
}
