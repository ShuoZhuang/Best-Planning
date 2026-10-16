import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart'
    show AppDatabase;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';

void main() {
  late AppDatabase database;
  late DriftTaskRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftTaskRepository(database.taskDao);
  });

  tearDown(() => database.close());

  test('task area and earliest start round trip', () async {
    await database.customInsert('''
      INSERT INTO areas
        (id, name, color, sort_order, is_life, created_at_utc, updated_at_utc)
      VALUES ('area-research', '科研', 17, 0, 0, 1, 1)
    ''');
    final task = PlannerTask(
      id: 'task-1',
      areaId: 'area-research',
      title: '准备科研汇报',
      notes: '整理实验结果',
      priority: TaskPriority.high,
      estimatedMinutes: 47,
      remainingMinutes: 32,
      dueAtUtc: DateTime.utc(2026, 10, 8, 12),
      availableFromUtc: DateTime.utc(2026, 10, 6, 3, 15),
      energyLevel: TaskEnergyLevel.high,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 25,
      maxChunkMinutes: 90,
      status: TaskStatus.inProgress,
      createdAtUtc: DateTime.utc(2026, 10, 1, 8),
      updatedAtUtc: DateTime.utc(2026, 10, 1, 9),
    );

    await repository.save(task);
    final loaded = await repository.getById(task.id);

    expect(loaded, isNotNull);
    expect(loaded!.id, task.id);
    expect(loaded.areaId, task.areaId);
    expect(loaded.title, task.title);
    expect(loaded.notes, task.notes);
    expect(loaded.priority, task.priority);
    expect(loaded.estimatedMinutes, task.estimatedMinutes);
    expect(loaded.remainingMinutes, task.remainingMinutes);
    expect(loaded.dueAtUtc, task.dueAtUtc);
    expect(loaded.availableFromUtc, task.availableFromUtc);
    expect(loaded.energyLevel, task.energyLevel);
    expect(loaded.splitMode, task.splitMode);
    expect(loaded.minChunkMinutes, task.minChunkMinutes);
    expect(loaded.maxChunkMinutes, task.maxChunkMinutes);
    expect(loaded.status, task.status);
    expect(loaded.createdAtUtc, task.createdAtUtc);
    expect(loaded.updatedAtUtc, task.updatedAtUtc);
  });

  test('固定日程保存后可按相交时间范围读取', () async {
    final calendarRepository = DriftCalendarRepository(database);
    final event = CalendarEvent(
      id: 'event-1',
      title: '课程',
      startAtUtc: DateTime.utc(2026, 10, 2, 1),
      endAtUtc: DateTime.utc(2026, 10, 2, 3),
      timeZoneId: 'Asia/Shanghai',
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    await calendarRepository.save(event);
    final occurrences = await calendarRepository.occurrencesBetween(
      DateTime.utc(2026, 10, 2, 2),
      DateTime.utc(2026, 10, 2, 4),
    );

    expect(occurrences, hasLength(1));
    expect(occurrences.single.eventId, event.id);
    expect(occurrences.single.title, event.title);
    expect(occurrences.single.range.startUtc, event.startAtUtc);
    expect(occurrences.single.range.endUtc, event.endAtUtc);
  });

  test('按周重复日程保存后会在查询窗口内展开每次实例', () async {
    final calendarRepository = DriftCalendarRepository(database);
    final rule = RecurrenceRule(
      id: 'rule-1',
      weekdays: const {DateTime.monday},
      localStartMinute: 9 * 60,
      durationMinutes: 90,
      validFromLocalDate: DateTime(2026, 10, 5),
      timeZoneId: 'Asia/Shanghai',
    );
    final event = CalendarEvent(
      id: 'event-weekly',
      title: '每周实验室例会',
      startAtUtc: DateTime.utc(2026, 10, 5, 1),
      endAtUtc: DateTime.utc(2026, 10, 5, 2, 30),
      timeZoneId: 'Asia/Shanghai',
      recurrenceRuleId: rule.id,
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );

    await calendarRepository.saveRecurring(event, rule);
    final occurrences = await calendarRepository.occurrencesBetween(
      DateTime.utc(2026, 10, 4, 16),
      DateTime.utc(2026, 10, 20, 16),
    );

    expect(occurrences, hasLength(3));
    expect(occurrences.map((item) => item.range.startUtc), [
      DateTime.utc(2026, 10, 5, 1),
      DateTime.utc(2026, 10, 12, 1),
      DateTime.utc(2026, 10, 19, 1),
    ]);
  });

  test('课表日程完整往返导入元数据', () async {
    await database.customInsert('''
      INSERT INTO areas
        (id, name, color, sort_order, is_life, created_at_utc, updated_at_utc)
      VALUES ('area-study', '学业', 17, 0, 0, 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO projects
        (id, area_id, name, created_at_utc, updated_at_utc)
      VALUES ('project-algorithm', 'area-study', '算法课', 1, 1)
    ''');
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
      VALUES ('batch-1', 'term-autumn', 'sha256:test', 'schedule.png',
              'committed', 1, 1, 1)
    ''');
    final calendarRepository = DriftCalendarRepository(database);
    final event = CalendarEvent(
      id: 'course-event',
      title: '算法与数据结构',
      startAtUtc: DateTime.utc(2026, 10, 6, 1, 55),
      endAtUtc: DateTime.utc(2026, 10, 6, 3, 35),
      timeZoneId: 'Asia/Shanghai',
      locked: true,
      areaId: 'area-study',
      projectId: 'project-algorithm',
      location: 'D206',
      notes: '赵敏',
      sourceKind: CalendarEventSourceKind.timetableImport,
      importBatchId: 'batch-1',
      logicalCourseId: 'course-algorithm',
      updatedAtUtc: DateTime.utc(2026, 10, 5),
    );

    await calendarRepository.save(event);
    final occurrence = (await calendarRepository.occurrencesBetween(
      DateTime.utc(2026, 10, 6),
      DateTime.utc(2026, 10, 7),
    )).single;

    expect(occurrence.projectId, event.projectId);
    expect(occurrence.location, event.location);
    expect(occurrence.notes, event.notes);
    expect(occurrence.sourceKind, CalendarEventSourceKind.timetableImport);
    expect(occurrence.importBatchId, event.importBatchId);
    expect(occurrence.logicalCourseId, event.logicalCourseId);
  });

  // Task 11（计划 §15 的 M1／备份往返）：**v10 的三种批次状态都能往返**。
  //
  // 这一条守的是"新增的 `partiallyDeleted` 不是只在迁移里认得，而是真的能存能读"：
  // 备份／恢复、导出与仓储读路径都必须原样带出它，否则"删过部分课程"这个事实
  // 会在一次恢复之后消失，而用户再导入同一张图片时会被同哈希拦住。
  test('v10：committed／partiallyDeleted／rolledBack 三种批次状态往返一致', () async {
    await database.customInsert('''
      INSERT INTO academic_terms
        (id, name, first_week_monday_local_date, total_weeks, time_zone_id,
         created_at_utc, updated_at_utc)
      VALUES ('term-autumn', '2026 秋季学期', '2026-09-07', 16,
              'Asia/Shanghai', 1, 1)
    ''');
    const statuses = ['committed', 'partiallyDeleted', 'rolledBack'];
    for (final (index, status) in statuses.indexed) {
      await database.customInsert('''
        INSERT INTO timetable_import_batches
          (id, term_id, source_image_hash, source_file_name, status,
           created_event_count, created_at_utc, updated_at_utc)
        VALUES ('batch-$index', 'term-autumn', 'sha256:$index',
                'schedule$index.png', '$status', ${index + 1},
                ${100 + index}, ${200 + index})
      ''');
    }

    final rows = await database.select(database.timetableImportBatches).get();
    expect(rows, hasLength(3));
    for (final row in rows) {
      final index = int.parse(row.id.split('-').last);
      expect(row.status, statuses[index]);
      expect(
        TimetableImportBatchStatus.fromStorage(row.status).storageValue,
        row.status,
        reason: '解析必须显式认得每一个存储值；未知值要抛受控错误而不是回落',
      );
      expect(row.sourceFileName, 'schedule$index.png');
      expect(row.createdEventCount, index + 1);
      expect(row.createdAtUtc, 100 + index);
      expect(row.updatedAtUtc, 200 + index);
    }
  });

  // 1.8.0（规范 §9.1，计划 Task 7 Step 2）：`kind` 必须保存、读取、展开后都不丢。
  test('固定日程与保护时间的 kind 在往返后不丢失', () async {    final calendarRepository = DriftCalendarRepository(database);
    await calendarRepository.save(
      CalendarEvent(
        id: 'evt-fixed',
        title: '例会',
        startAtUtc: DateTime.utc(2026, 10, 6, 1),
        endAtUtc: DateTime.utc(2026, 10, 6, 2),
        timeZoneId: 'Asia/Shanghai',
        updatedAtUtc: DateTime.utc(2026, 10, 5),
      ),
    );
    await calendarRepository.save(
      CalendarEvent(
        id: 'evt-protected',
        title: '保护时间',
        startAtUtc: DateTime.utc(2026, 10, 6, 4),
        endAtUtc: DateTime.utc(2026, 10, 6, 5),
        timeZoneId: 'Asia/Shanghai',
        kind: CalendarEventKind.protected,
        updatedAtUtc: DateTime.utc(2026, 10, 5),
      ),
    );

    final occurrences = await calendarRepository.occurrencesBetween(
      DateTime.utc(2026, 10, 6),
      DateTime.utc(2026, 10, 7),
    );
    final byId = {for (final item in occurrences) item.eventId: item};

    expect(
      byId['evt-fixed']!.kind,
      CalendarEventKind.fixed,
      reason: '没有显式给 kind 的日程默认就是固定日程（源码兼容，规范 §9.1）',
    );
    expect(
      byId['evt-protected']!.kind,
      CalendarEventKind.protected,
      reason: '保护时间必须原样读回来，否则它会被当成固定日程进入统计',
    );
  });

  test('重复保护时间的**每一次展开**都带 kind，而不只是锚点行', () async {
    // 展开器如果不把 kind 带下来，"重复的保护时间"会被当成固定日程：
    // 规范 §9.1 明确它不计入任何投入，也不该作为 fixed event 进排程输入。
    final calendarRepository = DriftCalendarRepository(database);
    final anchor = CalendarEvent(
      id: 'evt-weekly-protected',
      title: '每周二下午保护',
      startAtUtc: DateTime.utc(2026, 10, 6, 6),
      endAtUtc: DateTime.utc(2026, 10, 6, 7),
      timeZoneId: 'Asia/Shanghai',
      kind: CalendarEventKind.protected,
      updatedAtUtc: DateTime.utc(2026, 10, 5),
    );
    await calendarRepository.saveRecurring(
      anchor.copyWith(recurrenceRuleId: 'rule-protected'),
      RecurrenceRule(
        id: 'rule-protected',
        weekdays: {DateTime.tuesday},
        localStartMinute: 14 * 60,
        durationMinutes: 60,
        validFromLocalDate: DateTime(2026, 10, 6),
        timeZoneId: 'Asia/Shanghai',
      ),
    );

    final occurrences = await calendarRepository.occurrencesBetween(
      DateTime.utc(2026, 10, 5),
      DateTime.utc(2026, 10, 20),
    );
    expect(occurrences, isNotEmpty, reason: '夹具本身必须至少展开出一次');
    for (final occurrence in occurrences) {
      expect(
        occurrence.kind,
        CalendarEventKind.protected,
        reason: '展开出来的每一次都必须是保护时间（锚点：${occurrence.eventId}）',
      );
    }
  });

  test('未知的 kind 存储值回落到 fixed，绝不回落到 protected', () {
    // 保守方向：认不出的值当成固定日程最多是"这段时间被占着"，仍然可见可编辑；
    // 当成保护时间会让一段时段突然变成硬禁区，而用户没有任何线索（规范 §9.1）。
    expect(
      CalendarEventKind.fromStorage('wat-is-this'),
      CalendarEventKind.fixed,
    );
    expect(CalendarEventKind.fromStorage(null), CalendarEventKind.fixed);
    expect(
      CalendarEventKind.fromStorage('protected'),
      CalendarEventKind.protected,
    );
  });

  test('计划 repository 返回最新的已确认版本', () async {
    await database.customInsert("""
      INSERT INTO plan_versions
        (id, created_at_utc, input_hash, algorithm_version, status, summary_json)
      VALUES ('plan-old', 1, 'hash-1', '1', 'superseded', '{}')
      """);
    await database.customInsert("""
      INSERT INTO plan_versions
        (id, created_at_utc, input_hash, algorithm_version, status, summary_json)
      VALUES ('plan-current', 2, 'hash-2', '1', 'confirmed', '{}')
      """);

    final planRepository = DriftPlanRepository(database);

    expect((await planRepository.current())?.id, 'plan-current');
  });
}
