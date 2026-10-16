// Task 3（课程编辑完整性修复计划）：**整门课程改时间的唯一事务路径**与本地时区矩阵。
//
// 本文件此前测的是 `CourseManagementService.editWholeCourse()`——那个方法逐片段调用
// `CalendarService.replaceSeries()`，并且用一个**固定日期载体** `DateTime(2026, 1, 5)`
// 承载"新钟点"，再由 `_mapToSegmentDay()` 用 `newStartUtc.weekday`（**UTC 日期**）
// 推导本地星期。它已被删除（计划 §2.0／Task 3 Step 3、6），因为：
//
// * 循环写入不是原子的：第一段提交后第二段失败会留下半完成的课程（C09）；
// * UTC `.weekday` 在 Asia/Shanghai 的 00:00–07:59 会把课程落到**前一天**（C10）；
// * 固定载体日期不覆盖跨午夜与夏令时（C11）。
//
// 现在整门课程的时间只能走 `saveCourse()` → `CourseWriteGateway.replaceCourseSeries()`
// 的**单事务**链路，星期与钟点由每个片段**自己的规则时区**解释。本文件因此改成
// 那一条路径上的时区／原子性回归矩阵（TZ1、TZ2、CE1、CE3）。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_course_series_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/recurrence_expander.dart';
import 'package:personal_planner/domain/services/recurrence_membership.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  final nowUtc = DateTime.utc(2026, 10, 12, 1, 30);
  late db.AppDatabase database;
  late DriftCalendarRepository repository;
  late DriftCourseSeriesRepository courses;
  late CourseManagementService service;

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftCalendarRepository(database, zones: zones);
    courses = DriftCourseSeriesRepository(
      database,
      clock: _Clock(nowUtc),
      zones: zones,
      timeZoneId: zoneId,
    );
    service = CourseManagementService(
      courses: courses,
      calendar: CalendarService(
        repository: repository,
        deletion: repository,
        recurringRepository: repository,
        clock: _Clock(nowUtc),
        idGenerator: _Ids(),
        zones: zones,
      ),
      deletion: repository,
      gateway: repository,
      zones: zones,
      timeZoneId: zoneId,
      clock: _Clock(nowUtc),
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
              'committed', 2, 1, 1)
    ''');
    // **领域与项目必须有真实行**：`calendar_events.area_id`／`project_id` 是外键，
    // 而 CE1 要断言的正是"只改钟点不会把它们清成 null"。用假 id 会被约束直接拒绝，
    // 那样测的就不是"保留"，而是"夹具坏了"。
    await database.customInsert('''
      INSERT INTO areas (id, name, color, sort_order, is_life,
                         created_at_utc, updated_at_utc)
      VALUES ('area-math', '数学', 1, 1, 0, 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO projects (id, area_id, name, created_at_utc, updated_at_utc)
      VALUES ('project-calc', 'area-math', '微积分', 1, 1)
    ''');
  });

  tearDown(() => database.close());

  /// 种一个课程片段。[startMinute] 与 [weekdays] 是**规则时区里的本地值**。
  Future<void> seedSegment({
    required String eventId,
    required String ruleId,
    Set<int> weekdays = const {DateTime.monday},
    int startMinute = 8 * 60,
    int durationMinutes = 45,
    int intervalWeeks = 1,
    String zone = zoneId,
    String title = '高等数学(上)',
    String teacher = '赵敏',
    String location = '教一 302',
    String? areaId = 'area-math',
    String? projectId = 'project-calc',
    DateTime? validFrom,
    DateTime? validUntil,
  }) async {
    final from = validFrom ?? DateTime(2026, 9, 7);
    final startUtc = zones.localDateTimeToUtc(from, startMinute, zone);
    await repository.saveRecurring(
      CalendarEvent(
        id: eventId,
        title: title,
        startAtUtc: startUtc,
        endAtUtc: startUtc.add(Duration(minutes: durationMinutes)),
        timeZoneId: zone,
        recurrenceRuleId: ruleId,
        sourceKind: CalendarEventSourceKind.timetableImport,
        importBatchId: 'batch-autumn',
        logicalCourseId: 'course-calc',
        location: location,
        notes: teacher,
        areaId: areaId,
        projectId: projectId,
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: ruleId,
        weekdays: weekdays,
        localStartMinute: startMinute,
        durationMinutes: durationMinutes,
        intervalWeeks: intervalWeeks,
        validFromLocalDate: from,
        validUntilLocalDate: validUntil ?? DateTime(2026, 12, 20),
        timeZoneId: zone,
      ),
    );
  }

  CourseScheduleDraft draft({
    required int startMinute,
    int durationMinutes = 45,
    Set<int> weekdays = const {DateTime.monday},
    int intervalWeeks = 1,
    DateTime? validFrom,
    DateTime? validUntil,
  }) => CourseScheduleDraft(
    startMinute: startMinute,
    endMinute: startMinute + durationMinutes,
    weekdays: weekdays,
    intervalWeeks: intervalWeeks,
    validFromLocalDate: validFrom ?? DateTime(2026, 9, 7),
    validUntilLocalDate: validUntil ?? DateTime(2026, 12, 20),
  );

  Future<db.CalendarEvent> anchorRow(String id) async => (database.select(
    database.calendarEvents,
  )..where((row) => row.id.equals(id))).getSingle();

  Future<db.RecurrenceRule> ruleRow(String id) async => (database.select(
    database.recurrenceRules,
  )..where((row) => row.id.equals(id))).getSingle();

  /// 把 `weekdays_mask` 还原成 `DateTime.monday`…`sunday`（周一是 bit 0）。
  Set<int> weekdaysOf(db.RecurrenceRule rule) => {
    for (var day = DateTime.monday; day <= DateTime.sunday; day++)
      if (rule.weekdaysMask & (1 << (day - 1)) != 0) day,
  };

  // ───────────────────────────────────────────────────────────────────────────
  // TZ1／C10：Asia/Shanghai 的清晨课程
  // ───────────────────────────────────────────────────────────────────────────

  test('TZ1：Asia/Shanghai 周一 07:30 的锚点在 UTC 里落在**周日**，'
      '但规则与本地星期仍然是周一', () async {
    await seedSegment(
      eventId: 'evt-mon',
      ruleId: 'rule-mon',
      startMinute: 7 * 60 + 30,
    );

    final anchor = await anchorRow('evt-mon');
    final rule = await ruleRow('rule-mon');

    // 本地 2026-09-07（周一）07:30 = 2026-09-06T23:30Z，而 09-06 是**周日**。
    expect(
      DateTime.fromMicrosecondsSinceEpoch(
        anchor.startAtUtc,
        isUtc: true,
      ).weekday,
      DateTime.sunday,
      reason: '这是那个陷阱本身：从 UTC `.weekday` 推导本地星期会得到"周日"',
    );
    expect(
      zones
          .toLocal(
            DateTime.fromMicrosecondsSinceEpoch(anchor.startAtUtc, isUtc: true),
            zoneId,
          )
          .weekday,
      DateTime.monday,
      reason: '按**规则自己的 IANA 时区**解释，它确实是周一',
    );
    expect(rule.localStartMinute, 7 * 60 + 30, reason: '本地钟点必须逐分钟保留');
    expect(
      recurrenceIncludesLocalDate(
        RecurrenceRule(
          id: rule.id,
          weekdays: {DateTime.monday},
          localStartMinute: rule.localStartMinute,
          durationMinutes: rule.durationMinutes,
          intervalWeeks: rule.intervalWeeks,
          validFromLocalDate: DateTime.parse(rule.validFromLocalDate),
          validUntilLocalDate: rule.validUntilLocalDate == null
              ? null
              : DateTime.parse(rule.validUntilLocalDate!),
          timeZoneId: rule.timeZoneId,
        ),
        DateTime(2026, 9, 7),
      ),
      isTrue,
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // CE1：只改钟点不得丢掉任何资料或身份
  // ───────────────────────────────────────────────────────────────────────────

  test('CE1：整门课程只改钟点后，标题／教师／地点／领域／项目／来源／批次／'
      '逻辑课程 id／规则时区逐值不变', () async {
    await seedSegment(eventId: 'evt-mon', ruleId: 'rule-mon');
    final before = await anchorRow('evt-mon');

    final detail = await courses.findCourse('course-calc');
    final result = await service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-calc',
        expectedRevisions: detail!.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-calc',
          title: '高等数学(上)',
          teacher: '赵敏',
          location: '教一 302',
          areaId: 'area-math',
          projectId: 'project-calc',
          // 只有钟点变了：08:00 → 14:00。
          schedule: [draft(startMinute: 14 * 60)],
        ),
      ),
    );

    expect(result.isSuccess, isTrue, reason: result.error ?? '');
    final after = await anchorRow('evt-mon');
    expect(after.title, before.title);
    expect(after.notes, before.notes, reason: '教师存在 notes 列里');
    expect(after.location, before.location);
    expect(after.areaId, before.areaId);
    expect(after.projectId, before.projectId);
    expect(after.sourceKind, before.sourceKind, reason: 'C16：不得被写成 manual');
    expect(after.importBatchId, before.importBatchId, reason: 'C17：不得丢批次');
    expect(after.logicalCourseId, before.logicalCourseId);
    expect(after.timeZoneId, before.timeZoneId);
    expect(after.kind, before.kind, reason: 'C06：类别不得被默认值覆盖');
    expect(
      zones
          .toLocal(
            DateTime.fromMicrosecondsSinceEpoch(after.startAtUtc, isUtc: true),
            zoneId,
          )
          .hour,
      14,
      reason: '钟点确实改成了本地 14:00',
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 多片段：每段保留自己的星期
  // ───────────────────────────────────────────────────────────────────────────

  test('多片段：周一与周四两段各保留自己的星期，不会被压到同一天', () async {
    await seedSegment(eventId: 'evt-mon', ruleId: 'rule-mon');
    await seedSegment(
      eventId: 'evt-thu',
      ruleId: 'rule-thu',
      weekdays: const {DateTime.thursday},
      startMinute: 10 * 60,
    );

    final detail = await courses.findCourse('course-calc');
    final result = await service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-calc',
        expectedRevisions: detail!.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-calc',
          title: '高等数学(上)',
          schedule: [
            draft(startMinute: 14 * 60),
            draft(startMinute: 10 * 60, weekdays: const {DateTime.thursday}),
          ],
        ),
      ),
    );
    expect(result.isSuccess, isTrue, reason: result.error ?? '');

    final mon = await anchorRow('evt-mon');
    final thu = await anchorRow('evt-thu');
    expect(
      mon.startAtUtc,
      isNot(thu.startAtUtc),
      reason: '两段不能被压到同一时刻——那意味着"周四那节课"跑到周一去了',
    );
    // **星期属于规则**（`weekdays_mask`），不是锚点行上的日期：锚点的起点是
    // 该片段的 `validFromLocalDate`（学期里的那一周），而"这一周上星期几"由规则表达。
    // 因此这里断言的是两条规则各自的星期集合与钟点都被逐值保留。
    expect(weekdaysOf(await ruleRow('rule-mon')), {DateTime.monday});
    expect(weekdaysOf(await ruleRow('rule-thu')), {DateTime.thursday});
    expect((await ruleRow('rule-mon')).localStartMinute, 14 * 60);
    expect((await ruleRow('rule-thu')).localStartMinute, 10 * 60);

    // 而且两段确实都进入了这一门课的详情（各自持有自己的规则与锚点）。
    final after = await courses.findCourse('course-calc');
    expect(after!.segments, hasLength(2));
    expect(
      {for (final segment in after.segments) segment.weekday},
      {DateTime.monday, DateTime.thursday},
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TZ2：跨午夜与夏令时
  // ───────────────────────────────────────────────────────────────────────────

  test('TZ2：23:30–次日 00:30 的系列改写按规则时区得到 60 分钟时长', () async {
    await seedSegment(
      eventId: 'evt-mon',
      ruleId: 'rule-mon',
      startMinute: 8 * 60,
    );

    final startUtc = zones.localDateTimeToUtc(
      DateTime(2026, 9, 7),
      23 * 60 + 30,
      zoneId,
    );
    final endUtc = zones.localDateTimeToUtc(DateTime(2026, 9, 8), 30, zoneId);
    await repository.replaceSeries(
      anchorId: 'evt-mon',
      patch: CalendarEventPatch(
        title: '高等数学(上)',
        notes: '赵敏',
        startAtUtc: startUtc,
        endAtUtc: endUtc,
      ),
      recurrence: RecurrenceEditDraft(
        weekdays: const {DateTime.monday},
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
      ),
      updatedAtUtc: DateTime.utc(2026, 10, 2),
    );

    final rule = await ruleRow('rule-mon');
    expect(rule.localStartMinute, 23 * 60 + 30);
    expect(rule.durationMinutes, 60, reason: '跨午夜只差 60 分钟，不是 24 小时加减出来的数');
    final anchor = await anchorRow('evt-mon');
    expect(
      DateTime.fromMicrosecondsSinceEpoch(anchor.endAtUtc, isUtc: true)
          .difference(
            DateTime.fromMicrosecondsSinceEpoch(anchor.startAtUtc, isUtc: true),
          )
          .inMinutes,
      60,
    );
  });

  test('TZ2：America/New_York 夏令时切换周里，单双周的周偏移按**本地日**算', () {
    // 2026-03-08 是美东夏令时切换日（当地 02:00→03:00）。
    // 规则：从本地 2026-03-02（周一）起每两周的周一。
    final rule = RecurrenceRule(
      id: 'rule-dst',
      weekdays: const {DateTime.monday},
      localStartMinute: 9 * 60,
      durationMinutes: 60,
      intervalWeeks: 2,
      validFromLocalDate: DateTime(2026, 3, 2),
      validUntilLocalDate: DateTime(2026, 4, 30),
      timeZoneId: 'America/New_York',
    );

    expect(recurrenceIncludesLocalDate(rule, DateTime(2026, 3, 2)), isTrue);
    expect(
      recurrenceIncludesLocalDate(rule, DateTime(2026, 3, 9)),
      isFalse,
      reason: '这是间隔周；用本地零点相减在切换周会得到 6 天 23 小时 ⇒ 周偏移算错一周',
    );
    expect(
      recurrenceIncludesLocalDate(rule, DateTime(2026, 3, 16)),
      isTrue,
      reason: '切换之后的第二周仍然必须被算作"隔了一周"',
    );

    // 展开器与成员判定必须给出同一个答案（§2.4 的唯一实现）。
    final expander = RecurrenceExpander(TimeZoneDatabase());
    final occurrences = expander.expand(
      rule,
      TimeRange(
        startUtc: DateTime.utc(2026, 3, 1),
        endUtc: DateTime.utc(2026, 4, 1),
      ),
      const [],
    );
    for (final occurrence in occurrences) {
      expect(
        recurrenceIncludesLocalDate(rule, occurrence.localDate),
        isTrue,
        reason: '展开器产出的每一次都必须被成员判定认可（本地日 ${occurrence.localDate}）',
      );
    }
    expect(
      occurrences.map((o) => o.localDate.day).toList(),
      contains(16),
      reason: '切换周后的那一次不能被漏掉',
    );
  });

  test('TZ2：Asia/Shanghai 周日 00:15 的课程锚点落在周六 UTC 日期上，'
      '但本地星期是周日', () async {
    await seedSegment(
      eventId: 'evt-sun',
      ruleId: 'rule-sun',
      weekdays: const {DateTime.sunday},
      startMinute: 15,
      validFrom: DateTime(2026, 9, 6),
    );

    final anchor = await anchorRow('evt-sun');
    final startUtc = DateTime.fromMicrosecondsSinceEpoch(
      anchor.startAtUtc,
      isUtc: true,
    );
    expect(startUtc.weekday, DateTime.saturday, reason: 'UTC 日期是 09-05（周六）');
    expect(zones.toLocal(startUtc, zoneId).weekday, DateTime.sunday);
    expect((await ruleRow('rule-sun')).localStartMinute, 15);
  });
}

/// 让上面的展开器调用不必 import `TimeRange` 的实现细节。
final class _Clock implements Clock {
  const _Clock(this._now);
  final DateTime _now;
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _next = 0;
  @override
  String next() => 'id-${_next++}';
}
