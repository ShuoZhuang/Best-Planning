// Task 11（课程编辑完整性修复计划）：**端到端场景 A–G**。
//
// 这一层用**真实 Drift 库 ＋ 真实服务与仓储**跑完整链路，因此它能发现单元测试
// 各自绿、合起来却不对的那类缺陷（例如"预览说会删 2 条、保存删了 1 条"）。
//
// 运行方式（需要设备绑定，因此是本任务里唯一**不能**用 `flutter test` 无设备跑的一层）：
//
//   flutter test --no-pub integration_test/course_edit_integrity_and_import_recovery_test.dart -d windows
//
// **本文件在提交时尚未在 Windows 上执行过**（见
// `docs/testing/course-edit-integrity-and-import-recovery-acceptance.md` 的 T11 行，
// 状态 NOT RUN）。它在 `flutter analyze` 下通过，但那只能证明它**类型正确**，
// 不能证明场景通过。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_course_series_repository.dart';
import 'package:personal_planner/data/repositories/drift_timetable_import_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  final nowUtc = DateTime.utc(2026, 10, 12, 1, 30);
  late db.AppDatabase database;
  late DriftCalendarRepository repository;
  late DriftCourseSeriesRepository courses;
  late DriftTimetableImportRepository imports;
  late CourseManagementService service;
  late CalendarService calendar;

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftCalendarRepository(database, zones: zones);
    courses = DriftCourseSeriesRepository(
      database,
      clock: _Clock(nowUtc),
      zones: zones,
      timeZoneId: zoneId,
    );
    imports = DriftTimetableImportRepository(database, now: () => nowUtc);
    calendar = CalendarService(
      repository: repository,
      deletion: repository,
      recurringRepository: repository,
      clock: _Clock(nowUtc),
      idGenerator: _Ids(),
      zones: zones,
    );
    service = CourseManagementService(
      courses: courses,
      calendar: calendar,
      deletion: repository,
      gateway: repository,
      zones: zones,
      timeZoneId: zoneId,
      clock: _Clock(nowUtc),
    );

    await database.customInsert('''
      INSERT INTO areas
        (id, name, color, sort_order, is_life, created_at_utc, updated_at_utc)
      VALUES ('area-math', '数学', 1, 1, 0, 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO projects (id, area_id, name, created_at_utc, updated_at_utc)
      VALUES ('project-calc', 'area-math', '微积分', 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO academic_terms
        (id, name, first_week_monday_local_date, total_weeks, time_zone_id,
         created_at_utc, updated_at_utc)
      VALUES ('term-autumn', '2026 秋季学期', '2026-09-07', 16,
              'Asia/Shanghai', 1, 1)
    ''');
  });

  tearDown(() => database.close());

  /// 场景 A 的夹具：一门**字段全部非默认**的导入课程，两个星期片段。
  Future<void> seedImportedCourse() async {
    await database.customInsert('''
      INSERT INTO timetable_import_batches
        (id, term_id, source_image_hash, source_file_name, status,
         created_event_count, created_at_utc, updated_at_utc)
      VALUES ('batch-autumn', 'term-autumn', 'sha256:x', 'schedule.png',
              'committed', 2, $_seedInstantUs, $_seedInstantUs)
    ''');
    for (final (id, ruleId, weekday, minute) in [
      ('evt-mon', 'rule-mon', DateTime.monday, 8 * 60),
      ('evt-thu', 'rule-thu', DateTime.thursday, 10 * 60),
    ]) {
      await repository.saveRecurring(
        CalendarEvent(
          id: id,
          title: '算法与数据结构',
          startAtUtc: zones.localDateTimeToUtc(
            DateTime(2026, 9, 7),
            minute,
            zoneId,
          ),
          endAtUtc: zones.localDateTimeToUtc(
            DateTime(2026, 9, 7),
            minute + 45,
            zoneId,
          ),
          timeZoneId: zoneId,
          recurrenceRuleId: ruleId,
          sourceKind: CalendarEventSourceKind.timetableImport,
          importBatchId: 'batch-autumn',
          logicalCourseId: 'course-algo',
          location: '教一 302',
          notes: '张老师',
          areaId: 'area-math',
          projectId: 'project-calc',
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        ),
        RecurrenceRule(
          id: ruleId,
          weekdays: {weekday},
          localStartMinute: minute,
          durationMinutes: 45,
          intervalWeeks: 1,
          validFromLocalDate: DateTime(2026, 9, 7),
          validUntilLocalDate: DateTime(2026, 12, 20),
          timeZoneId: zoneId,
        ),
      );
    }
  }

  Future<db.CalendarEvent> anchor(String id) async => (database.select(
    database.calendarEvents,
  )..where((row) => row.id.equals(id))).getSingle();

  testWidgets('场景 A：只改钟点时，标题／教师／地点／领域／项目／来源／批次／'
      '逻辑课程 id／类别／规则时区逐值不变', (tester) async {
    await seedImportedCourse();
    final before = await anchor('evt-mon');

    final detail = await courses.findCourse('course-algo');
    final result = await service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-algo',
        expectedRevisions: detail!.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-algo',
          title: '算法与数据结构',
          teacher: '张老师',
          location: '教一 302',
          areaId: 'area-math',
          projectId: 'project-calc',
          schedule: [
            CourseScheduleDraft(
              startMinute: 14 * 60,
              endMinute: 14 * 60 + 45,
              weekdays: const {DateTime.monday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
            ),
            CourseScheduleDraft(
              startMinute: 10 * 60,
              endMinute: 10 * 60 + 45,
              weekdays: const {DateTime.thursday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
            ),
          ],
        ),
      ),
    );
    expect(result.isSuccess, isTrue, reason: result.error ?? '');

    final after = await anchor('evt-mon');
    expect(after.title, before.title);
    expect(after.notes, before.notes);
    expect(after.location, before.location);
    expect(after.areaId, before.areaId);
    expect(after.projectId, before.projectId);
    expect(after.sourceKind, before.sourceKind);
    expect(after.importBatchId, before.importBatchId);
    expect(after.logicalCourseId, before.logicalCourseId);
    expect(after.kind, before.kind);
    expect(after.timeZoneId, before.timeZoneId);
    expect(
      zones
          .toLocal(
            DateTime.fromMicrosecondsSinceEpoch(after.startAtUtc, isUtc: true),
            zoneId,
          )
          .hour,
      14,
    );
  });

  testWidgets('场景 B：日视图三种范围改写都保留未展示的字段', (tester) async {
    await seedImportedCourse();
    final before = await anchor('evt-mon');

    // 仅本次：写一条例外。
    final once = await calendar.updateEvent(
      target: CalendarEditTarget(
        anchorId: 'evt-mon',
        scope: EventEditScope.singleOccurrence,
        occurrenceStartUtc: zones.localDateTimeToUtc(
          DateTime(2026, 9, 7),
          8 * 60,
          zoneId,
        ),
      ),
      patch: CalendarEventPatch(
        title: '算法与数据结构（临时）',
        notes: '张老师',
        startAtUtc: zones.localDateTimeToUtc(
          DateTime(2026, 9, 7),
          16 * 60,
          zoneId,
        ),
        endAtUtc: zones.localDateTimeToUtc(
          DateTime(2026, 9, 7),
          16 * 60 + 45,
          zoneId,
        ),
      ),
    );
    expect(once.status, CalendarMutationStatus.saved);

    final exceptionRows = await database
        .customSelect(
          "SELECT location, area_id, project_id, source_kind, import_batch_id, "
          "logical_course_id, time_zone_id FROM calendar_events "
          "WHERE exception_of_id = 'evt-mon'",
        )
        .get();
    expect(exceptionRows, hasLength(1));
    final row = exceptionRows.single;
    expect(
      row.read<String>('location'),
      '教一 302',
      reason: '日视图不展示地点：它必须以"保持原值"表达，而不是被写成空串',
    );
    expect(row.read<String>('area_id'), before.areaId);
    expect(row.read<String>('project_id'), before.projectId);
    expect(row.read<String>('source_kind'), before.sourceKind);
    expect(row.read<String>('import_batch_id'), before.importBatchId);
    expect(row.read<String>('logical_course_id'), before.logicalCourseId);
    expect(row.read<String>('time_zone_id'), before.timeZoneId);

    // 整个系列：只改标题与备注，隐藏字段仍不变。
    final series = await calendar.updateEvent(
      target: const CalendarEditTarget(
        anchorId: 'evt-mon',
        scope: EventEditScope.entireSeries,
      ),
      patch: CalendarEventPatch(
        title: '算法与数据结构（新）',
        notes: '李老师',
        startAtUtc: zones.localDateTimeToUtc(
          DateTime(2026, 9, 7),
          8 * 60,
          zoneId,
        ),
        endAtUtc: zones.localDateTimeToUtc(
          DateTime(2026, 9, 7),
          8 * 60 + 45,
          zoneId,
        ),
      ),
    );
    expect(series.status, CalendarMutationStatus.saved);
    final afterSeries = await anchor('evt-mon');
    expect(afterSeries.title, '算法与数据结构（新）');
    expect(afterSeries.notes, '李老师');
    expect(afterSeries.location, before.location);
    expect(afterSeries.areaId, before.areaId);
    expect(afterSeries.projectId, before.projectId);
    expect(afterSeries.sourceKind, before.sourceKind);
    expect(afterSeries.importBatchId, before.importBatchId);
    expect(afterSeries.logicalCourseId, before.logicalCourseId);
    expect(afterSeries.kind, before.kind);
    expect(afterSeries.timeZoneId, before.timeZoneId);
  });

  testWidgets('场景 C：旧版损伤只检测不改写；手工修复之后提示消失', (tester) async {
    await database.customInsert('''
      INSERT INTO timetable_import_batches
        (id, term_id, source_image_hash, source_file_name, status,
         created_event_count, created_at_utc, updated_at_utc)
      VALUES ('batch-damaged', 'term-autumn', 'sha256:d', 'damaged.png',
              'committed', 1, 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO recurrence_rules
        (id, weekdays_mask, local_start_minute, duration_minutes,
         interval_weeks, valid_from_local_date, valid_until_local_date,
         time_zone_id, created_at_utc, updated_at_utc)
      VALUES ('rule-damaged', 1, 480, 45, 1, '2026-09-07', '2026-12-20',
              'Asia/Shanghai', 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO calendar_events
        (id, title, start_at_utc, end_at_utc, time_zone_id, recurrence_rule_id,
         locked, location, notes, kind, source_kind, import_batch_id,
         logical_course_id, created_at_utc, updated_at_utc)
      VALUES ('evt-damaged', '未命名事项',
              ${DateTime.utc(2026, 9, 7).microsecondsSinceEpoch},
              ${DateTime.utc(2026, 9, 7, 0, 45).microsecondsSinceEpoch},
              'UTC', 'rule-damaged', 1, '', '', 'fixed', 'timetableImport',
              'batch-damaged', 'course-damaged', 1, 1)
    ''');

    Future<List<String>> snapshot() async {
      final rows = await database
          .customSelect('SELECT * FROM calendar_events')
          .get();
      return [
        for (final row in rows)
          row.data.entries.map((e) => '${e.key}=${e.value}').join(','),
      ]..sort();
    }

    final before = await snapshot();
    final detail = await courses.findCourse('course-damaged');
    expect(detail!.hasLegacyPlaceholderTitle, isTrue);
    expect(
      detail.integrityIssues.map((issue) => issue.kind),
      contains(CourseIntegrityIssueKind.eventRuleTimeZoneMismatch),
    );
    expect(await snapshot(), before, reason: '打开课程、跑检测都不得改写任何一行（§3.0）');

    // 手工修复：改名 + 把事件时区对齐到规则时区，一次事务保存。
    final result = await service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-damaged',
        expectedRevisions: detail.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-damaged',
          title: '高等数学(上)',
          schedule: [
            CourseScheduleDraft(
              startMinute: 8 * 60,
              endMinute: 8 * 60 + 45,
              weekdays: const {DateTime.monday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
            ),
          ],
        ),
      ),
    );
    expect(result.isSuccess, isTrue, reason: result.error ?? '');

    final repaired = await courses.findCourse('course-damaged');
    expect(repaired!.hasIntegrityIssues, isFalse);
    expect(repaired.summary.title, '高等数学(上)');
  });

  testWidgets('场景 D：编辑新增片段后，原学期仍只显示一门课且按批次撤销会连它一起删掉', (
    tester,
  ) async {
    await seedImportedCourse();

    final detail = await courses.findCourse('course-algo');
    final save = await service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-algo',
        expectedRevisions: detail!.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-algo',
          title: '算法与数据结构',
          teacher: '张老师',
          location: '教一 302',
          schedule: [
            CourseScheduleDraft(
              startMinute: 8 * 60,
              endMinute: 8 * 60 + 45,
              weekdays: const {DateTime.monday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
            ),
            CourseScheduleDraft(
              startMinute: 10 * 60,
              endMinute: 10 * 60 + 45,
              weekdays: const {DateTime.thursday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
            ),
            // **新增的第三段**：周三。它没有既有锚点，因此走"新建锚点"那条路。
            CourseScheduleDraft(
              startMinute: 14 * 60,
              endMinute: 14 * 60 + 45,
              weekdays: const {DateTime.wednesday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
            ),
          ],
        ),
      ),
    );
    expect(save.isSuccess, isTrue, reason: save.error ?? '');

    // ① 当前学期仍然只显示**一门课**，且有两个以上片段。
    final listed = await courses.listCourses(termId: 'term-autumn');
    expect(
      listed.map((course) => course.logicalCourseId).toList(),
      ['course-algo'],
      reason: '新增片段不得造出第二门课，也不得让整门课从原学期消失（C18）',
    );
    final after = await courses.findCourse('course-algo');
    expect(after!.segments, hasLength(3));
    expect(
      {for (final segment in after.segments) segment.importBatchId},
      {'batch-autumn'},
      reason: '新增片段必须继承原批次（C16、C17）',
    );

    // ② 按原批次撤销：**三个片段全部被删掉**，包括新增的那一个。
    //
    // 这里必须先看清一件**设计上正确**的事：用户刚编辑过这门课，三个锚点的
    // `updated_at_utc` 因此都不再等于批次的创建时间 ⇒ `inspectRollback` 把它们全部
    // 判成"导入后被修改过"，`rollback()` 不带 force 会（正确）拒绝。
    // 历史页那一步也就会先弹二次确认（§3.5：用户改过的锚点继续列入 protectedEventIds）。
    // 因此这一段的正确流程是"先看清单，再带 force 确认"，而不是直接调用。
    final preview = await imports.inspectRollback('batch-autumn');
    expect(
      preview.protectedEventIds,
      hasLength(3),
      reason: '编辑过的三门片段都该出现在"需要确认"的清单里，新增的那一段也不例外',
    );
    await expectLater(
      imports.rollback('batch-autumn'),
      throwsA(isA<ProtectedTimetableEventsException>()),
      reason: '未确认 force 时必须零写入',
    );

    final rollback = await imports.rollback(
      'batch-autumn',
      forceEventIds: preview.protectedEventIds,
    );
    expect(rollback.deletedEventCount, 3);
    expect(
      await courses.findCourse('course-algo'),
      isNull,
      reason: '新增片段必须落在原批次的撤销范围里（P4）',
    );
    final leftovers = await database
        .customSelect(
          "SELECT COUNT(*) AS c FROM calendar_events "
          "WHERE logical_course_id = 'course-algo'",
        )
        .get();
    expect(leftovers.single.read<int>('c'), 0);
    final ruleLeftovers = await database
        .customSelect('SELECT COUNT(*) AS c FROM recurrence_rules')
        .get();
    expect(
      ruleLeftovers.single.read<int>('c'),
      0,
      reason: '三条片段各自的规则都要回收，不留下无锚点引用的孤儿规则',
    );
  });

  testWidgets('场景 E：删掉一门课之后仍可用同一张图片恢复', (tester) async {
    await database.customInsert('''
      INSERT INTO timetable_import_batches
        (id, term_id, source_image_hash, source_file_name, status,
         created_event_count, created_at_utc, updated_at_utc)
      VALUES ('batch-1', 'term-autumn', 'sha256:same', 'schedule.png',
              'committed', 2, $_seedInstantUs, $_seedInstantUs)
    ''');
    for (final (id, ruleId, logicalId, title) in [
      ('evt-a', 'rule-a', 'course-a', '课程 A'),
      ('evt-b', 'rule-b', 'course-b', '课程 B'),
    ]) {
      await repository.saveRecurring(
        CalendarEvent(
          id: id,
          title: title,
          startAtUtc: zones.localDateTimeToUtc(
            DateTime(2026, 9, 7),
            8 * 60,
            zoneId,
          ),
          endAtUtc: zones.localDateTimeToUtc(
            DateTime(2026, 9, 7),
            8 * 60 + 45,
            zoneId,
          ),
          timeZoneId: zoneId,
          recurrenceRuleId: ruleId,
          sourceKind: CalendarEventSourceKind.timetableImport,
          importBatchId: 'batch-1',
          logicalCourseId: logicalId,
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        ),
        RecurrenceRule(
          id: ruleId,
          weekdays: const {DateTime.monday},
          localStartMinute: 8 * 60,
          durationMinutes: 45,
          intervalWeeks: 1,
          validFromLocalDate: DateTime(2026, 9, 7),
          validUntilLocalDate: DateTime(2026, 12, 20),
          timeZoneId: zoneId,
        ),
      );
    }

    // 删掉课程 A：批次变成 partiallyDeleted。
    final deleted = await service.deleteCourse('course-a');
    expect(deleted.isSuccess, isTrue, reason: deleted.error ?? '');
    expect((await courses.findCourse('course-a')), isNull);
    final batchRow = await (database.select(
      database.timetableImportBatches,
    )..where((row) => row.id.equals('batch-1'))).getSingle();
    expect(batchRow.status, 'partiallyDeleted');

    // 历史里看得到它，并且"已删除部分课程"。
    final history = await imports.listHistory();
    final entry = history.singleWhere((item) => item.batchId == 'batch-1');
    expect(entry.status, TimetableImportBatchStatus.partiallyDeleted);
    expect(entry.remainingSeriesCount, 1, reason: '课程 B 还在');
    expect(entry.createdSeriesCount, 2);
    expect(entry.canRollback, isTrue);

    // **同图重导入不再被拦截**：这是"删课后可恢复"的全部意义。
    final reimport = await imports.commit(
      TimetableImportCommit(
        batchId: 'batch-2',
        termId: 'term-autumn',
        sourceImageHash: 'sha256:same',
        sourceFileName: 'schedule.png',
        createdAtUtc: DateTime.utc(2026, 10, 20),
        series: [
          TimetableImportSeriesWrite(
            event: CalendarEvent(
              id: 'evt-a-2',
              title: '课程 A',
              startAtUtc: zones.localDateTimeToUtc(
                DateTime(2026, 9, 7),
                8 * 60,
                zoneId,
              ),
              endAtUtc: zones.localDateTimeToUtc(
                DateTime(2026, 9, 7),
                8 * 60 + 45,
                zoneId,
              ),
              timeZoneId: zoneId,
              recurrenceRuleId: 'rule-a-2',
              sourceKind: CalendarEventSourceKind.timetableImport,
              importBatchId: 'batch-2',
              logicalCourseId: 'course-a',
              updatedAtUtc: DateTime.utc(2026, 10, 20),
            ),
            rule: RecurrenceRule(
              id: 'rule-a-2',
              weekdays: const {DateTime.monday},
              localStartMinute: 8 * 60,
              durationMinutes: 45,
              intervalWeeks: 1,
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
              timeZoneId: zoneId,
            ),
          ),
        ],
      ),
    );
    expect(reimport.status, TimetableImportBatchStatus.committed);

    // 课程 A 恢复了一份（**不是两份**），课程 B 没有被复制。
    final restored = await courses.findCourse('course-a');
    expect(restored!.segments, hasLength(1));
    expect(restored.segments.single.importBatchId, 'batch-2');
    final courseB = await courses.findCourse('course-b');
    expect(courseB!.segments, hasLength(1));

    // 旧批次仍可解释：撤销它不会删掉新批次恢复的课程。
    await imports.rollback('batch-1');
    expect(
      await courses.findCourse('course-a'),
      isNotNull,
      reason: '旧批次的撤销不得影响新批次恢复出来的课程',
    );
  });

  testWidgets('场景 F：缩短周次清理失效例外，再扩回去不"复活"', (tester) async {
    await seedImportedCourse();

    Future<void> addException(String id, DateTime localDate) =>
        repository.replaceOccurrence(
          anchorId: 'evt-mon',
          occurrenceStartUtc: zones.localDateTimeToUtc(
            localDate,
            8 * 60,
            zoneId,
          ),
          patch: CalendarEventPatch(
            title: '算法与数据结构',
            startAtUtc: zones.localDateTimeToUtc(localDate, 14 * 60, zoneId),
            endAtUtc: zones.localDateTimeToUtc(localDate, 15 * 60, zoneId),
          ),
          exceptionId: id,
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        );

    // 第 4 周与第 10 周各一条逐次调整。
    await addException('exc-week4', DateTime(2026, 9, 28));
    await addException('exc-week10', DateTime(2026, 11, 9));

    Future<int> exceptionCount() async {
      final rows = await database
          .customSelect(
            "SELECT COUNT(*) AS c FROM calendar_events "
            "WHERE exception_of_id = 'evt-mon'",
          )
          .get();
      return rows.first.read<int>('c');
    }

    expect(await exceptionCount(), 2);

    // 从 1–16 周缩到 1–8 周：第 10 周那条要被清理，第 4 周那条保留。
    final detail = await courses.findCourse('course-algo');
    final preview = await service.previewCourseEdit(
      CourseSaveRequest(
        logicalCourseId: 'course-algo',
        expectedRevisions: detail!.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-algo',
          title: '算法与数据结构',
          schedule: [
            CourseScheduleDraft(
              startMinute: 8 * 60,
              endMinute: 8 * 60 + 45,
              weekdays: const {DateTime.monday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 10, 26),
            ),
            CourseScheduleDraft(
              startMinute: 10 * 60,
              endMinute: 10 * 60 + 45,
              weekdays: const {DateTime.thursday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 10, 26),
            ),
          ],
        ),
      ),
    );
    expect(preview, isNotNull);
    expect(
      preview!.invalidatedRetainedExceptionCount,
      1,
      reason: '预览必须报出"保留锚点上有 1 条例外已超出新周次"',
    );

    final save = await service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-algo',
        expectedRevisions: detail.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-algo',
          title: '算法与数据结构',
          schedule: [
            CourseScheduleDraft(
              startMinute: 8 * 60,
              endMinute: 8 * 60 + 45,
              weekdays: const {DateTime.monday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 10, 26),
            ),
            CourseScheduleDraft(
              startMinute: 10 * 60,
              endMinute: 10 * 60 + 45,
              weekdays: const {DateTime.thursday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 10, 26),
            ),
          ],
        ),
      ),
    );
    expect(save.isSuccess, isTrue, reason: save.error ?? '');
    expect(await exceptionCount(), 1, reason: '预告删 1 条，实际就必须删 1 条（原文与实际同源）');

    // 再扩回 1–16 周：第 10 周那条**不得复活**。
    final afterShrink = await courses.findCourse('course-algo');
    final extend = await service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-algo',
        expectedRevisions: afterShrink!.sourceRevisions,
        expectedFingerprint: afterShrink.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-algo',
          title: '算法与数据结构',
          schedule: [
            CourseScheduleDraft(
              startMinute: 8 * 60,
              endMinute: 8 * 60 + 45,
              weekdays: const {DateTime.monday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
            ),
            CourseScheduleDraft(
              startMinute: 10 * 60,
              endMinute: 10 * 60 + 45,
              weekdays: const {DateTime.thursday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
            ),
          ],
        ),
      ),
    );
    expect(extend.isSuccess, isTrue, reason: extend.error ?? '');
    expect(
      await exceptionCount(),
      1,
      reason: '第 10 周那条已经随缩短删除；扩展规则不该让它复活（C23）',
    );
  });

  testWidgets('场景 G：取消与失败都不改数据', (tester) async {
    await seedImportedCourse();
    final detail = await courses.findCourse('course-algo');
    final before = await (database.select(database.calendarEvents)).get();
    final beforeRules = await (database.select(database.recurrenceRules)).get();

    // 指纹过期 ⇒ stale 且零写入（等价于"用户在确认时已经不该保存"）。
    final stale = await service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-algo',
        expectedRevisions: detail!.sourceRevisions,
        expectedFingerprint: 'stale-fingerprint',
        profile: CourseProfileDraft(
          logicalCourseId: 'course-algo',
          title: '改过的名字',
          schedule: [
            CourseScheduleDraft(
              startMinute: 9 * 60,
              endMinute: 9 * 60 + 45,
              weekdays: const {DateTime.monday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
            ),
          ],
        ),
      ),
    );
    expect(stale.status, CourseSaveStatus.stale);

    // 非法来源（两个不同批次）⇒ integrityConflict 且零写入。
    await database.customInsert('''
      INSERT INTO timetable_import_batches
        (id, term_id, source_image_hash, source_file_name, status,
         created_event_count, created_at_utc, updated_at_utc)
      VALUES ('batch-other', 'term-autumn', 'sha256:y', 'other.png',
              'committed', 1, 1, 1)
    ''');
    await database.customStatement(
      "UPDATE calendar_events SET import_batch_id = 'batch-other' "
      "WHERE id = 'evt-thu'",
    );
    final conflicting = await courses.findCourse('course-algo');
    final conflict = await service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-algo',
        expectedRevisions: conflicting!.sourceRevisions,
        expectedFingerprint: conflicting.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-algo',
          title: '算法与数据结构',
          schedule: [
            CourseScheduleDraft(
              startMinute: 9 * 60,
              endMinute: 9 * 60 + 45,
              weekdays: const {DateTime.monday},
              validFromLocalDate: DateTime(2026, 9, 7),
              validUntilLocalDate: DateTime(2026, 12, 20),
            ),
          ],
        ),
      ),
    );
    expect(conflict.status, CourseSaveStatus.integrityConflict);

    // 逐表比对：除了上面那一条**故意的夹具改动**之外，没有别的变化。
    final afterRules = await (database.select(database.recurrenceRules)).get();
    expect(afterRules, hasLength(beforeRules.length));
    final after = await (database.select(database.calendarEvents)).get();
    expect(after, hasLength(before.length));
    final monTitle = await anchor('evt-mon');
    expect(
      monTitle.title,
      '算法与数据结构',
      reason: 'stale 与 integrityConflict 都必须零写入',
    );
  });
}

/// 夹具里"导入发生的那一刻"。
///
/// **批次的 `created_at_utc` 必须与它导入出来的锚点 `updated_at_utc` 相同**：
/// `inspectRollback` 正是用"锚点的修订号是否还等于批次的创建时间"判断
/// "这条课程在导入之后被改过没有"。夹具里两者不一致会让每一门课都被判成"受保护"，
/// 于是撤销必须先 force——那测的就不是被测行为，而是夹具自己造出来的假象。
final int _seedInstantUs = DateTime.utc(2026, 10, 1).microsecondsSinceEpoch;

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
