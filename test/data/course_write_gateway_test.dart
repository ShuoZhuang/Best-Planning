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
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_course_series_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/calendar_event_edit.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  late AppDatabase database;
  late DriftCalendarRepository repository;
  late DriftCourseSeriesRepository courses;

  /// 批次与学期是 `calendar_events.import_batch_id` 的外键目标：来源事实必须有真行。
  Future<void> seedBatch() async {
    await database.customInsert('''
      INSERT INTO academic_terms
        (id, name, first_week_monday_local_date, total_weeks, time_zone_id,
         created_at_utc, updated_at_utc)
      VALUES ('term-autumn', '2026 秋季', '2026-09-07', 16, 'Asia/Shanghai',
              1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO timetable_import_batches
        (id, term_id, source_image_hash, source_file_name, status,
         created_event_count, created_at_utc, updated_at_utc)
      VALUES ('batch-autumn', 'term-autumn', 'sha256:x', 'schedule.png',
              'committed', 1, 1, 1)
    ''');
  }

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftCalendarRepository(database, zones: TimeZoneDatabase());
    courses = DriftCourseSeriesRepository(
      database,
      clock: const _FixedClock(),
      zones: TimeZoneDatabase(),
      timeZoneId: zoneId,
    );
    await seedBatch();
  });

  tearDown(() => database.close());

  /// 页面打开编辑页时读到的指纹——与仓储在写事务里重算的是同一个函数。
  Future<String> fingerprintOf(String logicalCourseId) async =>
      (await courses.findCourse(logicalCourseId))!.revisionFingerprint;

  /// 若干张表的完整快照：逐表逐行逐列比对，而不是"只看锚点还在不在"。
  Future<List<String>> tableSnapshotOf(List<String> tables) async {
    final rows = <String>[];
    for (final table in tables) {
      final result = await database.customSelect('SELECT * FROM $table').get();
      for (final row in result) {
        rows.add(
          '$table:${row.data.entries.map((e) => '${e.key}=${e.value}').join(',')}',
        );
      }
    }
    rows.sort();
    return rows;
  }

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
        importBatchId: 'batch-autumn',
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
      patch: CalendarEventPatch(
        title: '高等数学(上)',
        startAtUtc: utc(9, 7, 2, 0),
        endAtUtc: utc(9, 7, 2, 45),
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
      provenance: CourseSeriesProvenance.imported('batch-autumn'),
      expectedFingerprint: await fingerprintOf('course-calc'),
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
      provenance: CourseSeriesProvenance.imported('batch-autumn'),
      expectedFingerprint: await fingerprintOf('course-calc'),
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
      provenance: CourseSeriesProvenance.imported('batch-autumn'),
      expectedFingerprint: await fingerprintOf('course-calc'),
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
      provenance: CourseSeriesProvenance.imported('batch-autumn'),
      expectedFingerprint: await fingerprintOf('course-calc'),
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
      provenance: CourseSeriesProvenance.imported('batch-autumn'),
      expectedFingerprint: await fingerprintOf('course-calc'),
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
        patch: CalendarEventPatch(
          title: '高等数学(上)',
          startAtUtc: utc(9, day, 2, 0),
          endAtUtc: utc(9, day, 2, 45),
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
        provenance: CourseSeriesProvenance.imported('batch-autumn'),
        expectedFingerprint: await fingerprintOf('course-calc'),
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
        importBatchId: 'batch-autumn',
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
      provenance: CourseSeriesProvenance.imported('batch-autumn'),
      expectedFingerprint: await fingerprintOf('course-calc'),
    );

    expect(
      await segmentIds(),
      ['evt-a', 'evt-other'],
      reason:
          '替换的范围是**这门课**。同名但不同 `logicalCourseId` 的是两门课，'
          '把另一门删掉会让用户改一次 A 班的时间表、B 班的课消失',
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Task 11／E1–E4（计划 §2.5／§3.3）：**课程快照保存也要清理失效例外**
  // ───────────────────────────────────────────────────────────────────────────

  test('E1：课程快照保存缩短周次之后，保留锚点的失效例外被清理', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
    // 两条逐次调整：第 4 周（2026-09-28）与第 10 周（2026-11-09）。
    for (final (id, localDate) in [
      ('exc-week4', DateTime(2026, 9, 28)),
      ('exc-week10', DateTime(2026, 11, 9)),
    ]) {
      await repository.replaceOccurrence(
        anchorId: 'evt-a',
        occurrenceStartUtc: DateTime.utc(
          localDate.year,
          localDate.month,
          localDate.day,
          0,
        ),
        patch: CalendarEventPatch(
          title: '高等数学(上)',
          startAtUtc: DateTime.utc(
            localDate.year,
            localDate.month,
            localDate.day,
            6,
          ),
          endAtUtc: DateTime.utc(
            localDate.year,
            localDate.month,
            localDate.day,
            7,
          ),
        ),
        exceptionId: id,
        updatedAtUtc: utc(10, 1, 0, 0),
      );
    }
    Future<int> exceptionCount() async {
      final rows = await database
          .customSelect(
            "SELECT COUNT(*) AS c FROM calendar_events "
            "WHERE exception_of_id = 'evt-a'",
          )
          .get();
      return rows.first.read<int>('c');
    }

    Future<int> previewCount() => repository.countExceptionsInvalidatedBy(
      anchorEventId: 'evt-a',
      replacement: CourseScheduleDraft(
        startMinute: 8 * 60,
        endMinute: 8 * 60 + 45,
        weekdays: const {DateTime.monday},
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 10, 26),
      ),
      zoneId: zoneId,
    );

    expect(await exceptionCount(), 2);
    expect(await previewCount(), 1, reason: '预览要报出"另有 1 条调整已超出新周次"');

    await repository.replaceCourseSeries(
      rows: [
        CourseWriteRow(
          schedule: CourseScheduleDraft(
            startMinute: 8 * 60,
            endMinute: 8 * 60 + 45,
            weekdays: const {DateTime.monday},
            validFromLocalDate: DateTime(2026, 9, 7),
            validUntilLocalDate: DateTime(2026, 10, 26),
          ),
          index: 0,
          reuseAnchorId: 'evt-a',
        ),
      ],
      profile: profile([
        CourseScheduleDraft(
          startMinute: 8 * 60,
          endMinute: 8 * 60 + 45,
          weekdays: const {DateTime.monday},
          validFromLocalDate: DateTime(2026, 9, 7),
          validUntilLocalDate: DateTime(2026, 10, 26),
        ),
      ]),
      zoneId: zoneId,
      updatedAtUtc: utc(10, 12, 1, 0),
      provenance: CourseSeriesProvenance.imported('batch-autumn'),
      expectedFingerprint: await fingerprintOf('course-calc'),
    );

    expect(
      await exceptionCount(),
      1,
      reason:
          '**预告删 1 条，保存就必须删 1 条**（计划 §2.5 最后一句）：'
          '少了这一步，用户照着"将删除 1 条"按下确认，而那条调整会一直留着，'
          '并在下次扩展规则时"复活"（C23）。',
    );
    final remaining = await database
        .customSelect(
          "SELECT id FROM calendar_events WHERE exception_of_id = 'evt-a'",
        )
        .get();
    expect(remaining.single.read<String>('id'), 'exc-week4');
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Task 11／CE3（计划 §3.0）：**整门课程只有一次事务提交**
  // ───────────────────────────────────────────────────────────────────────────

  test('CE3：第二个片段写入失败 ⇒ 第一个片段也回滚，来源与规则全部不变', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
    final before = await tableSnapshotOf([
      'calendar_events',
      'recurrence_rules',
      'timetable_import_batches',
    ]);

    final added = draft(
      weekdays: const {DateTime.wednesday},
      startMinute: 14 * 60,
    );
    // **真实失败注入**：新片段的锚点 id 由仓储按 `<课程>-<序号>` 生成，
    // 因此让"写这个 id"失败，就等于让第二段写入失败。
    await database.customStatement('''
      CREATE TRIGGER block_second_segment BEFORE INSERT ON calendar_events
      WHEN NEW.id = 'course-calc-1'
      BEGIN SELECT RAISE(ABORT, '注入的失败'); END
    ''');

    await expectLater(
      repository.replaceCourseSeries(
        rows: [
          CourseWriteRow(
            schedule: draft(startMinute: 10 * 60),
            index: 0,
            reuseAnchorId: 'evt-a',
          ),
          CourseWriteRow(schedule: added, index: 1),
        ],
        profile: profile([draft(startMinute: 10 * 60), added]),
        zoneId: zoneId,
        updatedAtUtc: utc(10, 12, 1, 0),
        provenance: CourseSeriesProvenance.imported('batch-autumn'),
        expectedFingerprint: await fingerprintOf('course-calc'),
      ),
      throwsA(isA<SqliteException>()),
    );

    expect(
      await tableSnapshotOf([
        'calendar_events',
        'recurrence_rules',
        'timetable_import_batches',
      ]),
      before,
      reason:
          '第一段已经写过锚点与规则了；整门课程必须只有一个事务，'
          '否则用户会得到"3 个片段里改了 2 个"的半完成状态',
    );
    await database.customStatement('DROP TRIGGER block_second_segment');
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Task 7（课程编辑完整性修复计划）：**删除课程是一个事务**（D1–D4、B1–B3）
  // ───────────────────────────────────────────────────────────────────────────

  group('删除课程（计划 §2.3）', () {
    /// 四张表的完整快照——"失败即整体回滚"必须逐表核对，而不是只看锚点还在不在。
    Future<List<String>> tableSnapshot() async {
      final rows = <String>[];
      for (final table in [
        'calendar_events',
        'recurrence_rules',
        'timetable_import_batches',
        'academic_terms',
      ]) {
        final result = await database
            .customSelect('SELECT * FROM $table')
            .get();
        for (final row in result) {
          rows.add(
            '$table:${row.data.entries.map((e) => '${e.key}=${e.value}').join(',')}',
          );
        }
      }
      rows.sort();
      return rows;
    }

    Future<({String status, int updatedAt})> batch(String id) async {
      final row = await database
          .customSelect(
            "SELECT status, updated_at_utc FROM timetable_import_batches "
            "WHERE id = '$id'",
          )
          .getSingle();
      return (
        status: row.read<String>('status'),
        updatedAt: row.read<int>('updated_at_utc'),
      );
    }

    test('D1：锚点、例外与**独占规则**全部删除', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      // 三条例外：两条"替换"、一条"删除标记"（零长度）。
      await repository.replaceOccurrence(
        anchorId: 'evt-a',
        occurrenceStartUtc: utc(9, 7, 0, 0),
        patch: CalendarEventPatch(
          title: '高等数学(上)',
          startAtUtc: utc(9, 7, 2, 0),
          endAtUtc: utc(9, 7, 2, 45),
        ),
        exceptionId: 'exc-1',
        updatedAtUtc: utc(10, 1, 0, 0),
      );
      await repository.replaceOccurrence(
        anchorId: 'evt-a',
        occurrenceStartUtc: utc(9, 14, 0, 0),
        patch: CalendarEventPatch(
          title: '高等数学(上)',
          startAtUtc: utc(9, 14, 2, 0),
          endAtUtc: utc(9, 14, 2, 45),
        ),
        exceptionId: 'exc-2',
        updatedAtUtc: utc(10, 1, 0, 0),
      );

      final result = await repository.deleteSeriesWithExceptions(
        anchorEventIds: {'evt-a'},
        deletedAtUtc: utc(10, 12, 1, 0),
      );

      expect(result.deletedAnchorCount, 1);
      expect(result.deletedExceptionCount, 2);
      expect(
        result.deletedRuleCount,
        1,
        reason: '这条规则只被目标锚点引用：不删它就会留下孤儿规则（C21）',
      );
      expect(await segmentIds(), isEmpty);
      expect(await ruleCount(), 0);
      final leftovers = await database
          .customSelect(
            "SELECT COUNT(*) AS c FROM calendar_events "
            "WHERE exception_of_id = 'evt-a'",
          )
          .get();
      expect(leftovers.first.read<int>('c'), 0);
    });

    test('D2：**共享规则**在仍有引用时保留', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-shared');
      await seedSegment(eventId: 'evt-b', ruleId: 'rule-shared');

      final result = await repository.deleteSeriesWithExceptions(
        anchorEventIds: {'evt-a'},
        deletedAtUtc: utc(10, 12, 1, 0),
      );

      expect(result.deletedRuleCount, 0, reason: '另一条锚点还在引用它；直接删会打断那一段的展开');
      expect(await ruleCount(), 1);
      expect(await segmentIds(), ['evt-b']);

      // 最后一个引用被删掉时才回收。
      final second = await repository.deleteSeriesWithExceptions(
        anchorEventIds: {'evt-b'},
        deletedAtUtc: utc(10, 12, 2, 0),
      );
      expect(second.deletedRuleCount, 1);
      expect(await ruleCount(), 0);
    });

    test('D4：重复删除返回 0 变化，且**不更新批次时间戳**', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      final first = await repository.deleteSeriesWithExceptions(
        anchorEventIds: {'evt-a'},
        deletedAtUtc: utc(10, 12, 1, 0),
      );
      expect(first.deletedAnchorCount, 1);
      final afterFirst = await batch('batch-autumn');

      final second = await repository.deleteSeriesWithExceptions(
        anchorEventIds: {'evt-a'},
        deletedAtUtc: utc(10, 12, 9, 0),
      );

      expect(second.isEmpty, isTrue);
      expect(
        await batch('batch-autumn'),
        afterFirst,
        reason: '一次无操作不该看起来像一次真实变更',
      );
      expect(
        (await repository.deleteSeriesWithExceptions(
          anchorEventIds: const {},
          deletedAtUtc: utc(10, 12, 9, 0),
        )).isEmpty,
        isTrue,
      );
    });

    test('D3：删除规则时失败 ⇒ 四张表全部回滚', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      await repository.replaceOccurrence(
        anchorId: 'evt-a',
        occurrenceStartUtc: utc(9, 7, 0, 0),
        patch: CalendarEventPatch(
          title: '高等数学(上)',
          startAtUtc: utc(9, 7, 2, 0),
          endAtUtc: utc(9, 7, 2, 45),
        ),
        exceptionId: 'exc-1',
        updatedAtUtc: utc(10, 1, 0, 0),
      );
      final before = await tableSnapshot();
      // **真实失败注入**：让"删规则"这一步在事务里失败。
      await database.customStatement('''
        CREATE TRIGGER block_rule_delete BEFORE DELETE ON recurrence_rules
        BEGIN SELECT RAISE(ABORT, '注入的失败'); END
      ''');

      await expectLater(
        repository.deleteSeriesWithExceptions(
          anchorEventIds: {'evt-a'},
          deletedAtUtc: utc(10, 12, 1, 0),
        ),
        throwsA(isA<SqliteException>()),
      );

      expect(await tableSnapshot(), before, reason: '例外与锚点已经删过了，但整体回滚必须把它们带回来');
      await database.customStatement('DROP TRIGGER block_rule_delete');
    });

    test('D3：更新批次状态时失败 ⇒ 四张表全部回滚', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      final before = await tableSnapshot();
      await database.customStatement('''
        CREATE TRIGGER block_batch_update BEFORE UPDATE ON timetable_import_batches
        BEGIN SELECT RAISE(ABORT, '注入的失败'); END
      ''');

      await expectLater(
        repository.deleteSeriesWithExceptions(
          anchorEventIds: {'evt-a'},
          deletedAtUtc: utc(10, 12, 1, 0),
        ),
        throwsA(isA<SqliteException>()),
      );

      expect(await tableSnapshot(), before);
      await database.customStatement('DROP TRIGGER block_batch_update');
    });

    test('B1：删除导入课程 ⇒ committed → partiallyDeleted', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      expect((await batch('batch-autumn')).status, 'committed');

      final result = await repository.deleteSeriesWithExceptions(
        anchorEventIds: {'evt-a'},
        deletedAtUtc: utc(10, 12, 1, 0),
      );

      expect(result.affectedImportBatchCount, 1);
      final after = await batch('batch-autumn');
      expect(after.status, 'partiallyDeleted');
      expect(
        after.updatedAt,
        utc(10, 12, 1, 0).microsecondsSinceEpoch,
        reason: '状态与时间戳必须来自**同一个** deletedAtUtc',
      );
      expect(
        TimetableImportBatchStatus.fromStorage(after.status),
        TimetableImportBatchStatus.partiallyDeleted,
      );
    });

    test('B2：删掉手工课程（没有批次）不改任何批次', () async {
      await repository.saveRecurring(
        CalendarEvent(
          id: 'evt-manual',
          title: '手工课',
          startAtUtc: utc(9, 7, 0, 0),
          endAtUtc: utc(9, 7, 0, 45),
          timeZoneId: zoneId,
          recurrenceRuleId: 'rule-manual',
          sourceKind: CalendarEventSourceKind.manual,
          logicalCourseId: 'course-manual',
          updatedAtUtc: utc(10, 1, 0, 0),
        ),
        RecurrenceRule(
          id: 'rule-manual',
          weekdays: const {DateTime.monday},
          localStartMinute: 8 * 60,
          durationMinutes: 45,
          validFromLocalDate: DateTime(2026, 9, 7),
          validUntilLocalDate: DateTime(2026, 12, 20),
          timeZoneId: zoneId,
        ),
      );
      final before = await batch('batch-autumn');

      final result = await repository.deleteSeriesWithExceptions(
        anchorEventIds: {'evt-manual'},
        deletedAtUtc: utc(10, 12, 1, 0),
      );

      expect(result.affectedImportBatchCount, 0);
      expect(await batch('batch-autumn'), before);
    });

    test('B3：rolledBack／draft 批次的状态不被覆盖', () async {
      await database.customStatement(
        "UPDATE timetable_import_batches SET status = 'rolledBack' "
        "WHERE id = 'batch-autumn'",
      );
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');

      final result = await repository.deleteSeriesWithExceptions(
        anchorEventIds: {'evt-a'},
        deletedAtUtc: utc(10, 12, 1, 0),
      );

      expect(
        result.affectedImportBatchCount,
        0,
        reason: '只有 committed 会转移；已撤销的批次不该被这次删除改写',
      );
      expect((await batch('batch-autumn')).status, 'rolledBack');
    });
  });
}

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 12);
}
