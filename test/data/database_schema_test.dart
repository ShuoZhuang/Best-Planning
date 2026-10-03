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
    // 断言 **SQLite 自己**的表目录，而不是 `database.allTables`：后者是 drift 依据 schema
    // 声明生成的列表，拿它跟字面量比对等于把声明抄一遍——它发现不了"迁移里漏了一句
    // CREATE TABLE"，而那恰好是本用例标题所声称要检查的事（§13.0 的 T3）。
    const expected = {
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
    };
    final rows = await database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    final actual = rows
        .map((row) => row.read<String>('name'))
        // drift 自己会用 sqlite_ 前缀的内部表记录迁移与版本，不属被测范围。
        .where((name) => !name.startsWith('sqlite_'))
        .toSet();

    expect(actual, expected, reason: '实际建出的表与 schema 声明不一致：说明迁移漏建或多建');
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

    // 原先写的是 `throwsA(anything)`：它连"SQL 打错了"也算通过，而本用例要证明的是
    // **外键**拒绝了这次删除。因此断言异常里确实提到 FOREIGN KEY——SQL 写错会给出
    // "no such column/table" 之类，不会被这条通过。
    await expectLater(
      database.customStatement("DELETE FROM projects WHERE id = 'project-1'"),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('FOREIGN KEY'),
        ),
      ),
    );
    final violations = await database
        .customSelect('PRAGMA foreign_key_check')
        .get();
    expect(violations, isEmpty);
  });
}
