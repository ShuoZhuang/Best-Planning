import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test('创建全部十六张核心表并启用外键', () async {
    final tableNames = database.allTables
        .map((table) => table.actualTableName)
        .toSet();

    expect(tableNames, {
      'areas',
      'projects',
      'tasks',
      'tags',
      'task_tags',
      'calendar_events',
      'recurrence_rules',
      'energy_windows',
      'settings',
      'plan_versions',
      'schedule_blocks',
      'time_entries',
      'task_corrections',
      'preference_evidence',
      'preference_rules',
      'change_log',
    });
    final foreignKeys = await database
        .customSelect('PRAGMA foreign_keys')
        .getSingle();
    expect(foreignKeys.read<int>('foreign_keys'), 1);
  });

  test('有任务引用时拒绝删除项目且外键检查保持干净', () async {
    await database.customInsert(
      "INSERT INTO areas (id, name, color, sort_order) VALUES ('area-1', '学业', 0, 0)",
    );
    await database.customInsert(
      "INSERT INTO projects (id, area_id, name) VALUES ('project-1', 'area-1', '课程')",
    );
    await database.customInsert("""
      INSERT INTO tasks (
        id, project_id, title, notes, priority, estimated_minutes,
        remaining_minutes, energy_level, split_mode, min_chunk_minutes,
        max_chunk_minutes, status, created_at_utc, updated_at_utc
      ) VALUES (
        'task-1', 'project-1', '作业', '', 'medium', 30,
        30, 'medium', 'splittable', 25, 90, 'open', 1, 1
      )
      """);

    expect(
      () => database.customStatement(
        "DELETE FROM projects WHERE id = 'project-1'",
      ),
      throwsA(anything),
    );
    final violations = await database
        .customSelect('PRAGMA foreign_key_check')
        .get();
    expect(violations, isEmpty);
  });
}
