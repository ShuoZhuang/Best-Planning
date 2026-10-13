// Task 4（课程与保护时间管理修复计划）：**整门课程的事务性编辑**（网关与仓储部分）。
//
// 服务层的编排在 `course_edit_save_test.dart` 里验；这里验的是**落库那一半**：
// 一个事务整体替换、保住既有锚点 id 与它名下的例外、删掉不再出现的片段与规则、
// 以及"任何一步失败都整体回滚"。
//
// 用**真实 drift 库**：这条链路的全部价值在于"一个事务里换掉四条表"，而那正是 SQL 的
// 行为，替身证明不了。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent, RecurrenceRule;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/calendar_event_edit.dart';
import 'package:personal_planner/domain/models/course_edit.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  late AppDatabase database;
  late DriftCalendarRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftCalendarRepository(database, zones: TimeZoneDatabase());
  });

  tearDown(() => database.close());

  DateTime utc(int month, int day, int hour, int minute) =>
      DateTime.utc(2026, month, day, hour, minute);

  /// 造一条课表导入的片段（周一 08:00，45 分钟，`course-calc`）。
  Future<void> seedSegment({
    required String eventId,
    required String ruleId,
    Set<int> weekdays = const {DateTime.monday},
    int startMinute = 8 * 60,
    String title = '高等数学(上)',
  }) async {
    await repository.saveRecurring(
      CalendarEvent(
        id: eventId,
        title: title,
        startAtUtc: utc(9, 7, 0, 0),
        endAtUtc: utc(9, 7, 0, 45),
        timeZoneId: zoneId,
        recurrenceRuleId: ruleId,
        sourceKind: CalendarEventSourceKind.timetableImport,
        importBatchId: null,
        logicalCourseId: 'course-calc',
        notes: '赵敏',
        location: 'D206',
        updatedAtUtc: utc(10, 1, 0, 0),
      ),
      RecurrenceRule(
        id: ruleId,
        weekdays: weekdays,
        localStartMinute: startMinute,
        durationMinutes: 45,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
        timeZoneId: zoneId,
      ),
    );
  }

  CourseProfileDraft profile(List<CourseScheduleDraft> schedule) =>
      CourseProfileDraft(
        logicalCourseId: 'course-calc',
        title: '高等数学(上)',
        teacher: '赵敏',
        location: 'D206',
        schedule: schedule,
      );

  /// 一条 45 分钟的安排。
  ///
  /// `endMinute` 默认由 `startMinute` 推出来（**不是写死的 8:45**）：写死会让
  /// "改到 10:00 开始"那种用例造出一个 `end < start` 的草稿，而 `CalendarEvent`
  /// 的构造器当场抛错——那报的是夹具的错，却看起来像实现的错。
  CourseScheduleDraft draft({
    int startMinute = 8 * 60,
    int? endMinute,
    Set<int> weekdays = const {DateTime.monday},
    int intervalWeeks = 1,
  }) => CourseScheduleDraft(
    startMinute: startMinute,
    endMinute: endMinute ?? startMinute + 45,
    weekdays: weekdays,
    intervalWeeks: intervalWeeks,
    validFromLocalDate: DateTime(2026, 9, 7),
    validUntilLocalDate: DateTime(2026, 12, 20),
  );

  Future<List<String>> segmentIds() async {
    final rows = await database
        .customSelect(
          "SELECT id FROM calendar_events WHERE exception_of_id IS NULL "
          "ORDER BY id",
        )
        .get();
    return [for (final row in rows) row.read<String>('id')];
  }

  Future<int> ruleCount() async {
    final rows = await database
        .customSelect('SELECT COUNT(*) AS c FROM recurrence_rules')
        .get();
    return rows.first.read<int>('c');
  }

  test('**保住既有锚点 id 与它名下的例外**（换成新 id 等于删一条加一条）', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
    // 给这条锚点写一条"某一次改过"的例外。
    await repository.replaceOccurrence(
      anchorId: 'evt-a',
      occurrenceStartUtc: utc(9, 7, 0, 0),
      event: CalendarEventEditDraft(
        title: '高等数学(上)',
        startAtUtc: utc(9, 7, 2, 0),
        endAtUtc: utc(9, 7, 2, 45),
        timeZoneId: zoneId,
        kind: CalendarEventKind.fixed,
      ),
      exceptionId: 'exc-a',
      updatedAtUtc: utc(10, 1, 0, 0),
    );

    await repository.replaceCourseSeries(
      rows: [
        CourseWriteRow(
          schedule: draft(startMinute: 10 * 60),
          index: 0,
          reuseAnchorId: 'evt-a',
        ),
      ],
      profile: profile([draft(startMinute: 10 * 60)]),
      zoneId: zoneId,
      updatedAtUtc: utc(10, 12, 1, 0),
    );

    expect(
      await segmentIds(),
      ['evt-a'],
      reason:
          '沿用了既有 id。若改成新建一个 `course-calc-0`，那条锚点名下的例外'
          '（用户逐个改过的内容）会随之全部消失',
    );
    final exceptions = await database
        .customSelect(
          "SELECT COUNT(*) AS c FROM calendar_events WHERE exception_of_id = 'evt-a'",
        )
        .get();
    expect(
      exceptions.first.read<int>('c'),
      1,
      reason: '例外必须还在——它挂在原锚点上，而原锚点没被换掉',
    );
  });

  test('**不再出现的片段连同它的规则一起删掉**', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
    await seedSegment(
      eventId: 'evt-b',
      ruleId: 'rule-b',
      weekdays: const {DateTime.thursday},
      startMinute: 10 * 60,
    );
    expect(await ruleCount(), 2);

    // 最终形态只留周一那一条。
    await repository.replaceCourseSeries(
      rows: [
        CourseWriteRow(schedule: draft(), index: 0, reuseAnchorId: 'evt-a'),
      ],
      profile: profile([draft()]),
      zoneId: zoneId,
      updatedAtUtc: utc(10, 12, 1, 0),
    );

    expect(await segmentIds(), ['evt-a']);
    expect(
      await ruleCount(),
      1,
      reason:
          '规则行必须跟着删。留下的孤儿规则不会再展开（展开要靠锚点），'
          '但它会一直占着主键，而"这条规则还在不在"从此无从回答',
    );
  });

  test('**新增片段**按 `<课程>-<序号>` 建 id 与规则', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');

    final added = draft(
      weekdays: const {DateTime.wednesday},
      startMinute: 14 * 60,
    );
    await repository.replaceCourseSeries(
      rows: [
        CourseWriteRow(schedule: draft(), index: 0, reuseAnchorId: 'evt-a'),
        CourseWriteRow(schedule: added, index: 1),
      ],
      profile: profile([draft(), added]),
      zoneId: zoneId,
      updatedAtUtc: utc(10, 12, 1, 0),
    );

    expect(await segmentIds(), ['course-calc-1', 'evt-a']);
    expect(await ruleCount(), 2);
    final addedRow = await database
        .customSelect(
          "SELECT weekdays_mask, local_start_minute FROM recurrence_rules "
          "WHERE id = 'course-calc-1-rule'",
        )
        .get();
    expect(
      addedRow.single.read<int>('weekdays_mask'),
      // 周三是 bit 2（周一 = bit 0）。
      1 << (DateTime.wednesday - 1),
    );
    expect(addedRow.single.read<int>('local_start_minute'), 14 * 60);
  });

  test('**资料字段逐项写下去**：教师进 notes、地点进 location、类别保持导入', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');

    await repository.replaceCourseSeries(
      rows: [
        CourseWriteRow(
          schedule: draft(startMinute: 10 * 60),
          index: 0,
          reuseAnchorId: 'evt-a',
        ),
      ],
      profile: CourseProfileDraft(
        logicalCourseId: 'course-calc',
        title: '高等数学(下)',
        teacher: '李娜',
        location: 'E101',
        schedule: [draft(startMinute: 10 * 60)],
      ),
      zoneId: zoneId,
      updatedAtUtc: utc(10, 12, 1, 0),
    );

    final row = await database
        .customSelect(
          "SELECT title, notes, location, source_kind, logical_course_id "
          "FROM calendar_events WHERE id = 'evt-a'",
        )
        .get();
    final single = row.single;
    expect(single.read<String>('title'), '高等数学(下)');
    expect(
      single.read<String>('notes'),
      '李娜',
      reason: '教师存在 notes 列里（本批次不引入"课程备注"这个新概念）',
    );
    expect(single.read<String>('location'), 'E101');
    expect(
      single.read<String>('source_kind'),
      CalendarEventSourceKind.timetableImport.storageValue,
      reason:
          '**类别跟着既有行走**：课表导入的课被改成手工事项之后，'
          '"撤销导入"就再也找不到它了',
    );
    expect(single.read<String?>('logical_course_id'), 'course-calc');
  });

  test('**删光全部片段 ⇒ 这门课在库里不再有系列**', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');

    await repository.replaceCourseSeries(
      rows: const [],
      profile: CourseProfileDraft(
        logicalCourseId: 'course-calc',
        title: '高等数学(上)',
        schedule: const [],
      ),
      zoneId: zoneId,
      updatedAtUtc: utc(10, 12, 1, 0),
    );

    expect(await segmentIds(), isEmpty);
    expect(await ruleCount(), 0);
  });

  test('**`countExceptions` 只数挂在那个锚点上的**', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
    await seedSegment(eventId: 'evt-b', ruleId: 'rule-b');
    // **三条例外必须落在三个不同的发生日**：例外是按「哪一天」定位的，
    // 同一天的两次调用会写出同一个例外 id，于是只有一行。
    for (final (anchor, id, day) in const [
      ('evt-a', 'exc-1', 7),
      ('evt-a', 'exc-2', 14),
      ('evt-b', 'exc-3', 7),
    ]) {
      await repository.replaceOccurrence(
        anchorId: anchor,
        occurrenceStartUtc: utc(9, day, 0, 0),
        event: CalendarEventEditDraft(
          title: '高等数学(上)',
          startAtUtc: utc(9, day, 2, 0),
          endAtUtc: utc(9, day, 2, 45),
          timeZoneId: zoneId,
          kind: CalendarEventKind.fixed,
        ),
        exceptionId: id,
        updatedAtUtc: utc(10, 1, 0, 0),
      );
    }

    expect(await repository.countExceptions('evt-a'), 2);
    expect(await repository.countExceptions('evt-b'), 1);
    expect(await repository.countExceptions('nope'), 0);
  });

  test('**整体替换失败时原数据完全不变**（事务回滚）', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
    await seedSegment(
      eventId: 'evt-b',
      ruleId: 'rule-b',
      weekdays: const {DateTime.thursday},
      startMinute: 10 * 60,
    );
    final rowsBefore = await segmentIds();
    final rulesBefore = await ruleCount();

    // 第二行故意造一个**非法时段**（结束早于开始）。`CalendarEvent` 的构造器会抛错，
    // 而那时第一行已经写进去了——因此这一次失败必须把整个事务一起回滚。
    final good = draft(startMinute: 9 * 60);
    final bad = draft(startMinute: 10 * 60, endMinute: 9 * 60);

    await expectLater(
      repository.replaceCourseSeries(
        rows: [
          CourseWriteRow(schedule: good, index: 0, reuseAnchorId: 'evt-a'),
          CourseWriteRow(schedule: bad, index: 1),
        ],
        profile: profile([good, bad]),
        zoneId: zoneId,
        updatedAtUtc: utc(10, 12, 1, 0),
      ),
      throwsA(isA<ArgumentError>()),
    );

    expect(
      await segmentIds(),
      rowsBefore,
      reason:
          '**半成品是最坏的结果**：排程按 drift 的 watch 重算，缺了一段的课表会被'
          '当成真的，于是用户"只是点了一下保存"就看到计划里少了几次课',
    );
    expect(await ruleCount(), rulesBefore);
  });

  test('**锚点不属于这门课时不动它**（防串台）', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
    // 另一门课的片段，标题相同、`logicalCourseId` 不同。
    await repository.saveRecurring(
      CalendarEvent(
        id: 'evt-other',
        title: '高等数学(上)',
        startAtUtc: utc(9, 7, 0, 0),
        endAtUtc: utc(9, 7, 0, 45),
        timeZoneId: zoneId,
        recurrenceRuleId: 'rule-other',
        sourceKind: CalendarEventSourceKind.timetableImport,
        logicalCourseId: 'course-calc-b',
        updatedAtUtc: utc(10, 1, 0, 0),
      ),
      RecurrenceRule(
        id: 'rule-other',
        weekdays: const {DateTime.tuesday},
        localStartMinute: 8 * 60,
        durationMinutes: 45,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
        timeZoneId: zoneId,
      ),
    );

    await repository.replaceCourseSeries(
      rows: [
        CourseWriteRow(schedule: draft(), index: 0, reuseAnchorId: 'evt-a'),
      ],
      profile: profile([draft()]),
      zoneId: zoneId,
      updatedAtUtc: utc(10, 12, 1, 0),
    );

    expect(
      await segmentIds(),
      ['evt-a', 'evt-other'],
      reason:
          '替换的范围是**这门课**。同名但不同 `logicalCourseId` 的是两门课，'
          '把另一门删掉会让用户改一次 A 班的时间表、B 班的课消失',
    );
  });
}
