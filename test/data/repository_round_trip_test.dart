import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart'
    show AppDatabase;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';

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
