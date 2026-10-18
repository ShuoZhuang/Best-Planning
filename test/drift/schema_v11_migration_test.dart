// 算法 20 schema v11（规范 §11 / ALG20-074）。
//
// v11 只新增 `day_exceptions` 表与两条索引。这个文件在 v10 库里写入真实业务行，
// 迁移到 v11 后用生成代码逐值读回：任务、日历、计划、偏好规则的任何字段都不得
// 被这次迁移改写；新表必须存在且为空。
import 'package:drift/drift.dart' hide isNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';

import 'app_database/generated/schema.dart';
import 'app_database/generated/schema_v10.dart' as v10;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('v10 业务行迁移到 v11 后逐值保留，新表为空', () async {
    final schema = await verifier.schemaAt(10);
    final old = v10.DatabaseAtV10(schema.newConnection());

    await old
        .into(old.areas)
        .insert(
          v10.AreasCompanion.insert(
            id: 'area-work',
            name: '工作',
            color: 17,
            sortOrder: 0,
          ),
        );
    await old
        .into(old.tasks)
        .insert(
          v10.TasksCompanion.insert(
            id: 'task-1',
            title: '写论文',
            priority: 'high',
            estimatedMinutes: 120,
            remainingMinutes: 90,
            energyLevel: 'high',
            splitMode: 'splittable',
            minChunkMinutes: 30,
            maxChunkMinutes: 60,
            status: 'open',
            createdAtUtc: 1000,
            updatedAtUtc: 2000,
            areaId: const Value('area-work'),
            notes: const Value('不要动我的笔记'),
          ),
        );
    await old
        .into(old.preferenceRules)
        .insert(
          v10.PreferenceRulesCompanion.insert(
            id: 'rule-1',
            kind: 'preferredTimeWindow',
            subjectKey: 'global',
            valueJson: '{"startMinute":540}',
            confidence: 0.8,
            status: 'confirmed',
            source: 'legacy',
            updatedAtUtc: 3000,
          ),
        );
    await old.close();

    final database = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(database, 11);

    final task = await database.select(database.tasks).getSingle();
    expect(task.title, '写论文');
    expect(task.notes, '不要动我的笔记');
    expect(task.remainingMinutes, 90);
    expect(task.minChunkMinutes, 30);
    expect(task.maxChunkMinutes, 60);

    final rule = await database.select(database.preferenceRules).getSingle();
    expect(rule.valueJson, '{"startMinute":540}');
    expect(rule.status, 'confirmed');

    expect(await database.select(database.dayExceptions).get(), isEmpty);
    expect(database.schemaVersion, 11);
    await database.close();
  });
}
