// 1.8.0（设计规范 §10.1／§10.3，计划 Task 9 Step 1）：课程聚合查询。
//
// **用真实 drift 数据库**：这条链路的价值在于"按 `logicalCourseId` 把多个系列片段聚成
// 一门课"，而那是 SQL 的联接与分组行为，替身证明不了。
//
// 四条判据（规范 §10.3 与 Task 9 Step 1）：
// 1. 同一 `logicalCourseId` 的单双周／分段规则聚合成**一门**课程；
// 2. **同名不同 id 分开**；
// 3. 按 `termId` 过滤；
// 4. **普通手工固定日程不出现**。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent, RecurrenceRule;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_course_series_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';

void main() {
  late AppDatabase database;
  late DriftCalendarRepository calendar;
  late DriftCourseSeriesRepository courses;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    calendar = DriftCalendarRepository(database);
    courses = DriftCourseSeriesRepository(
      database,
      clock: _FixedClock(DateTime.utc(2026, 10, 12, 4)),
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
              'committed', 3, 1, 1)
    ''');
  });

  tearDown(() => database.close());

  /// 造一条课表导入的重复日程（＝一个系列片段）。
  Future<void> addSeries({
    required String eventId,
    required String ruleId,
    required String title,
    required String logicalCourseId,
    String batchId = 'batch-autumn',
    int weekday = DateTime.monday,
    int startMinute = 8 * 60,
    int durationMinutes = 45,
    int intervalWeeks = 1,
    DateTime? validFrom,
    DateTime? validUntil,
  }) async {
    await calendar.saveRecurring(
      CalendarEvent(
        id: eventId,
        title: title,
        startAtUtc: DateTime.utc(2026, 10, 5, 0),
        endAtUtc: DateTime.utc(2026, 10, 5, 0, 45),
        timeZoneId: 'Asia/Shanghai',
        recurrenceRuleId: ruleId,
        sourceKind: CalendarEventSourceKind.timetableImport,
        importBatchId: batchId,
        logicalCourseId: logicalCourseId,
        location: 'D206',
        notes: '赵敏',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: ruleId,
        weekdays: {weekday},
        localStartMinute: startMinute,
        durationMinutes: durationMinutes,
        intervalWeeks: intervalWeeks,
        validFromLocalDate: validFrom ?? DateTime(2026, 9, 7),
        validUntilLocalDate: validUntil ?? DateTime(2026, 12, 20),
        timeZoneId: 'Asia/Shanghai',
      ),
    );
  }

  test('同一 logicalCourseId 的单双周两条规则聚成一门课', () async {
    // 单双周在库里就是**两条规则**（单周一条、双周一条），用户眼里却是一门课。
    await addSeries(
      eventId: 'evt-calc-odd',
      ruleId: 'rule-calc-odd',
      title: '高等数学(上)',
      logicalCourseId: 'course-calc-a',
      intervalWeeks: 2,
    );
    await addSeries(
      eventId: 'evt-calc-even',
      ruleId: 'rule-calc-even',
      title: '高等数学(上)',
      logicalCourseId: 'course-calc-a',
      intervalWeeks: 2,
      weekday: DateTime.thursday,
    );

    final list = await courses.listCourses(termId: 'term-autumn');

    expect(list, hasLength(1), reason: '两条规则是同一门课的两个片段');
    expect(list.single.logicalCourseId, 'course-calc-a');
    expect(
      list.single.anchorEventIds,
      containsAll(['evt-calc-odd', 'evt-calc-even']),
      reason: '"整个课程"要按这些锚点逐个改写，漏一个就只改了一半',
    );
    expect(list.single.location, 'D206');
    expect(list.single.teacher, '赵敏');
    expect(list.single.importBatchId, 'batch-autumn');
    expect(list.single.termId, 'term-autumn', reason: '学期由导入批次反查得到');
  });

  test('同名但不同 logicalCourseId 的课程分开列出', () async {
    await addSeries(
      eventId: 'evt-a',
      ruleId: 'rule-a',
      title: '高等数学(上)',
      logicalCourseId: 'course-calc-a',
    );
    await addSeries(
      eventId: 'evt-b',
      ruleId: 'rule-b',
      title: '高等数学(上)',
      logicalCourseId: 'course-calc-b',
      weekday: DateTime.tuesday,
    );

    final list = await courses.listCourses(termId: 'term-autumn');

    expect(list, hasLength(2), reason: '两个班的同名课是两门课');
    expect(list.map((course) => course.logicalCourseId).toSet(), {
      'course-calc-a',
      'course-calc-b',
    });
  });

  test('普通手工固定日程不出现（它没有 logicalCourseId）', () async {
    await addSeries(
      eventId: 'evt-course',
      ruleId: 'rule-course',
      title: '大学物理',
      logicalCourseId: 'course-physics',
    );
    // 手工建的重复日程：没有 logicalCourseId、没有批次。
    await calendar.saveRecurring(
      CalendarEvent(
        id: 'evt-manual',
        title: '每周例会',
        startAtUtc: DateTime.utc(2026, 10, 5, 2),
        endAtUtc: DateTime.utc(2026, 10, 5, 3),
        timeZoneId: 'Asia/Shanghai',
        recurrenceRuleId: 'rule-manual',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: 'rule-manual',
        weekdays: const {DateTime.monday},
        localStartMinute: 10 * 60,
        durationMinutes: 60,
        validFromLocalDate: DateTime(2026, 9, 7),
        timeZoneId: 'Asia/Shanghai',
      ),
    );

    final list = await courses.listCourses();

    expect(list.map((course) => course.title), [
      '大学物理',
    ], reason: '手工固定日程属于日历而不是"课程管理"');
  });

  test('按 termId 过滤，且 termId 为空时列出全部', () async {
    await database.customInsert('''
      INSERT INTO academic_terms
        (id, name, first_week_monday_local_date, total_weeks, time_zone_id,
         created_at_utc, updated_at_utc)
      VALUES ('term-spring', '2027 春季学期', '2027-02-22', 16,
              'Asia/Shanghai', 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO timetable_import_batches
        (id, term_id, source_image_hash, source_file_name, status,
         created_event_count, created_at_utc, updated_at_utc)
      VALUES ('batch-spring', 'term-spring', 'sha256:y', 'spring.png',
              'committed', 1, 1, 1)
    ''');
    await addSeries(
      eventId: 'evt-autumn',
      ruleId: 'rule-autumn',
      title: '秋季课',
      logicalCourseId: 'course-autumn',
    );
    await addSeries(
      eventId: 'evt-spring',
      ruleId: 'rule-spring',
      title: '春季课',
      logicalCourseId: 'course-spring',
      batchId: 'batch-spring',
    );

    expect(
      (await courses.listCourses(termId: 'term-autumn')).map((c) => c.title),
      ['秋季课'],
    );
    expect(
      (await courses.listCourses(termId: 'term-spring')).map((c) => c.title),
      ['春季课'],
    );
    expect(await courses.listCourses(), hasLength(2));
  });

  test('详情的片段清单按开始分钟排序且顺序确定', () async {
    await addSeries(
      eventId: 'evt-late',
      ruleId: 'rule-late',
      title: '高数',
      logicalCourseId: 'course-calc',
      startMinute: 14 * 60,
    );
    await addSeries(
      eventId: 'evt-early',
      ruleId: 'rule-early',
      title: '高数',
      logicalCourseId: 'course-calc',
      startMinute: 8 * 60,
    );

    final detail = await courses.findCourse('course-calc');

    expect(detail, isNotNull);
    expect(detail!.segments.map((segment) => segment.eventId), [
      'evt-early',
      'evt-late',
    ], reason: '顺序必须确定，否则同一次点击可能打开不同的片段');
    expect(detail.summary.startMinute, 8 * 60, reason: '代表片段取排序后的第一条');
    // 再查一次，顺序必须逐值相同。
    expect(
      (await courses.findCourse('course-calc'))!.segments.map((s) => s.eventId),
      ['evt-early', 'evt-late'],
    );
  });

  test('找不到的课程返回 null，而不是抛异常', () async {
    expect(await courses.findCourse('nope'), isNull);
  });

  test('currentTermId 落在学期内时返回该学期', () async {
    expect(await courses.currentTermId(), 'term-autumn');
  });

  test('currentTermId 落在学期之间时返回最近一个已开始的学期', () async {
    final later = DriftCourseSeriesRepository(
      database,
      // 2026-09-07 起 16 周 ⇒ 到 2026-12-27；取 2027-01-10，落在两学期之间。
      clock: _FixedClock(DateTime.utc(2027, 1, 10, 4)),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
    );

    expect(
      await later.currentTermId(),
      'term-autumn',
      reason: '假期里打开管理页应当看到刚过去那一学期的课，而不是空页面',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 3（课程与保护时间管理修复计划）：**读模型必须返回真实周次、全部星期与修订 token**
  //
  // 修复前 `_weekSpanOf` 把 `startWeek` 写死为 1、`endWeek` 写成"规则自己跨了几周"。
  // 规则"第 5 周到第 12 周"因此读成"第 1 周到第 8 周"——用户看到的周次是错的，
  // 而更糟的是编辑页会按这个错误范围**保存回去**，保存一次课就被挪到开学那几周。
  // ─────────────────────────────────────────────────────────────────────────────

  test('**真实周次**：第 5 周开始、第 12 周结束 ⇒ startWeek=5、endWeek=12', () async {
    // 学期第一周周一 = 2026-09-07。第 5 周周一 = 10-05，第 12 周周日 = 11-29。
    await addSeries(
      eventId: 'evt-late-start',
      ruleId: 'rule-late-start',
      title: '高等数学(上)',
      logicalCourseId: 'course-calc',
      validFrom: DateTime(2026, 10, 5),
      validUntil: DateTime(2026, 11, 29),
    );

    final detail = await courses.findCourse('course-calc');
    final segment = detail!.segments.single;

    expect(
      segment.weekSpan.startWeek,
      5,
      reason:
          '10-05 是学期第 5 周的周一。修复前这里恒为 1 —— '
          '而编辑页会把这个 1 保存回数据库，等于把课挪到开学那几周',
    );
    expect(segment.weekSpan.endWeek, 12);
    expect(segment.outsideTerm, isFalse);
  });

  test('**多星期全部保留**：周一的规则不会把周四丢掉', () async {
    await calendar.saveRecurring(
      CalendarEvent(
        id: 'evt-two-days',
        title: '数据结构',
        startAtUtc: DateTime.utc(2026, 10, 5, 0),
        endAtUtc: DateTime.utc(2026, 10, 5, 0, 45),
        timeZoneId: 'Asia/Shanghai',
        recurrenceRuleId: 'rule-two-days',
        sourceKind: CalendarEventSourceKind.timetableImport,
        importBatchId: 'batch-autumn',
        logicalCourseId: 'course-ds',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: 'rule-two-days',
        weekdays: const {DateTime.monday, DateTime.thursday},
        localStartMinute: 8 * 60,
        durationMinutes: 45,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
        timeZoneId: 'Asia/Shanghai',
      ),
    );

    final segment = (await courses.findCourse('course-ds'))!.segments.single;

    expect(
      segment.weekdays,
      {DateTime.monday, DateTime.thursday},
      reason:
          '`weekdays_mask` 本来就能表达多个位。只取一个代表值会让编辑页'
          '把另一天**静默丢掉**——用户改一次时间，周四那节课就没了',
    );
    expect(
      segment.weekday,
      DateTime.monday,
      reason: '代表星期保留给"显示成周X"与排序，但它不是数据的全部',
    );
  });

  test('单双周：起点在第 5 周（奇）⇒ odd；在第 6 周（偶）⇒ even', () async {
    // 第 5 周周一 = 10-05（奇），第 6 周周一 = 10-12（偶）。
    await addSeries(
      eventId: 'evt-odd',
      ruleId: 'rule-odd',
      title: '单周课',
      logicalCourseId: 'course-odd',
      intervalWeeks: 2,
      validFrom: DateTime(2026, 10, 5),
      validUntil: DateTime(2026, 12, 20),
    );
    await addSeries(
      eventId: 'evt-even',
      ruleId: 'rule-even',
      title: '双周课',
      logicalCourseId: 'course-even',
      intervalWeeks: 2,
      validFrom: DateTime(2026, 10, 12),
      validUntil: DateTime(2026, 12, 20),
    );

    expect(
      (await courses.findCourse('course-odd'))!.segments.single.weekSpan.parity,
      WeekParity.odd,
    );
    expect(
      (await courses.findCourse('course-even'))!
          .segments
          .single
          .weekSpan
          .parity,
      WeekParity.even,
    );
  });

  test('**超出学期总周数时保留原日期并标记 outsideTerm**（读取时不夹紧）', () async {
    // 学期 16 周 ⇒ 到 2026-12-27。这里排到 2027-01-31（第 22 周）。
    await addSeries(
      eventId: 'evt-over',
      ruleId: 'rule-over',
      title: '排到学期外',
      logicalCourseId: 'course-over',
      validFrom: DateTime(2026, 9, 7),
      validUntil: DateTime(2027, 1, 31),
    );

    final segment = (await courses.findCourse('course-over'))!.segments.single;

    expect(
      segment.validUntilLocalDate,
      DateTime(2027, 1, 31),
      reason:
          '**读取时不夹紧**：夹紧会让"这门课其实排到了学期外"在编辑页上完全看不见，'
          '用户一保存就把它永久改成学期内',
    );
    expect(segment.outsideTerm, isTrue, reason: '保留原日期 + 置标志，由编辑页提示用户修正');
    expect(segment.weekSpan.endWeek, greaterThan(16));
  });

  test('**修订 token 覆盖每个锚点，且用数据库的 updated_at_utc**', () async {
    await addSeries(
      eventId: 'evt-a',
      ruleId: 'rule-a',
      title: '高数',
      logicalCourseId: 'course-calc',
    );
    await addSeries(
      eventId: 'evt-b',
      ruleId: 'rule-b',
      title: '高数',
      logicalCourseId: 'course-calc',
      weekday: DateTime.thursday,
    );

    final detail = await courses.findCourse('course-calc');
    final revisions = detail!.sourceRevisions;

    expect(revisions.keys.toSet(), {'evt-a', 'evt-b'});
    for (final value in revisions.values) {
      expect(value.isUtc, isTrue, reason: '修订时刻统一用 UTC，比较才有意义');
      expect(value, DateTime.utc(2026, 10, 1));
    }
    // 保存时按 anchor id 逐条比对，因此键必须就是锚点 id。
    expect(
      detail.segments.map((s) => s.eventId).toSet(),
      revisions.keys.toSet(),
    );
  });

  test('**排序确定**：最早星期 → 开始分钟 → 间隔周数 → 事件 id', () async {
    // 三条规则：周四 14:00、周一 14:00、周一 8:00。期望：周一8:00 → 周一14:00 → 周四14:00。
    await addSeries(
      eventId: 'evt-thu',
      ruleId: 'rule-thu',
      title: '高数',
      logicalCourseId: 'course-calc',
      weekday: DateTime.thursday,
      startMinute: 14 * 60,
    );
    await addSeries(
      eventId: 'evt-mon-late',
      ruleId: 'rule-mon-late',
      title: '高数',
      logicalCourseId: 'course-calc',
      weekday: DateTime.monday,
      startMinute: 14 * 60,
    );
    await addSeries(
      eventId: 'evt-mon-early',
      ruleId: 'rule-mon-early',
      title: '高数',
      logicalCourseId: 'course-calc',
      weekday: DateTime.monday,
      startMinute: 8 * 60,
    );

    final ids = (await courses.findCourse('course-calc'))!.segments
        .map((s) => s.eventId)
        .toList();

    expect(ids, [
      'evt-mon-early',
      'evt-mon-late',
      'evt-thu',
    ], reason: '顺序必须确定且与输入排列无关，否则同一次点击可能打开不同的片段');
  });

  test('未知学期（不在任何批次里）不伪造"第 1 周开始"', () async {
    // 直接写一条没有批次的事件：`termId` 为 null。
    await calendar.saveRecurring(
      CalendarEvent(
        id: 'evt-no-term',
        title: '无学期课',
        startAtUtc: DateTime.utc(2026, 10, 5, 0),
        endAtUtc: DateTime.utc(2026, 10, 5, 0, 45),
        timeZoneId: 'Asia/Shanghai',
        recurrenceRuleId: 'rule-no-term',
        sourceKind: CalendarEventSourceKind.timetableImport,
        logicalCourseId: 'course-no-term',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: 'rule-no-term',
        weekdays: const {DateTime.monday},
        localStartMinute: 8 * 60,
        durationMinutes: 45,
        intervalWeeks: 2,
        validFromLocalDate: DateTime(2026, 10, 5),
        validUntilLocalDate: DateTime(2026, 12, 20),
        timeZoneId: 'Asia/Shanghai',
      ),
    );

    final summary = (await courses.listCourses()).single;

    expect(summary.termId, isNull, reason: '没有批次就没有学期归属，这是事实而不是缺失');
    final segment = (await courses.findCourse('course-no-term'))!
        .segments
        .single;
    expect(
      segment.weekSpan.parity,
      WeekParity.every,
      reason:
          '没有学期基准就算不出单双周。**保守报"每周"**：误报成单双周会让用户'
          '以为这周没课（计划 Task 3 Step 2）',
    );
  });
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}
