// Task 12A Step 4（用户 2026-10-08 追加的发布阻断项）：schema v7 → v8 修复历史非法片段设置。
//
// **这个文件测的是数据修复，不是结构变更**：v8 一个列都没加、一个表都没建。它只把 v7 及以前
// 存进库里的两类自相矛盾记录扶正：
//
// 1. `min_chunk_minutes > max_chunk_minutes`（用户把两个框填反后保存成功）；
// 2. 片段上下限**超过任务总时长**（把预计时长从 120 分钟改成 15 分钟后，片段仍是 30–90）。
//
// 第 2 类是本批次真实观察到的那条发布阻断：候选生成一个片段都产不出来，任务既出现在"新增"里
// 又出现在"未安排"里。服务层已在保存时夹紧（`TaskService._normalizeChunks`），但那管不到
// **已经存进库里**的行——这正是必须有一次迁移的原因。
//
// **最要紧的断言是"别的一律不动"**：一次以"修复片段范围"为由的迁移，顺手改写剩余时长或用户文本
// 会让它变成一次静默的数据变更。因此下面逐列比对剩余时长、截止时间、标题、备注、状态。
import 'package:drift/drift.dart' hide isNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v6.dart' as v6;
import 'generated/schema_v7.dart' as v7;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  /// 在 v7 库里插一条任务，返回它的 id。
  ///
  /// 参数刻意只暴露"片段三件套 + 用户数据"，让每条用例的**意图**一眼可见。
  Future<void> insertV7Task(
    v7.DatabaseAtV7 db, {
    required String id,
    required int estimatedMinutes,
    required int minChunk,
    required int maxChunk,
  }) => db
      .into(db.tasks)
      .insert(
        v7.TasksCompanion.insert(
          id: id,
          title: '贫困生材料提交',
          priority: 'high',
          estimatedMinutes: estimatedMinutes,
          remainingMinutes: estimatedMinutes,
          energyLevel: 'medium',
          splitMode: 'splittable',
          minChunkMinutes: minChunk,
          maxChunkMinutes: maxChunk,
          status: 'open',
          notes: const Value('别动我的备注'),
          createdAtUtc: 1000,
          updatedAtUtc: 2000,
        ),
      );

  test('短任务：预计 15 分钟而片段 30–90 ⇒ 两列都夹到不超过 15', () async {
    final schema = await verifier.schemaAt(7);
    addTearDown(schema.close);
    final old = v7.DatabaseAtV7(schema.newConnection());
    await insertV7Task(
      old,
      id: 'short',
      estimatedMinutes: 15,
      minChunk: 30,
      maxChunk: 90,
    );
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => DateTime.utc(2026, 10, 8),
    );
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 8);

    final task = await (db.select(
      db.tasks,
    )..where((row) => row.id.equals('short'))).getSingle();
    expect(
      task.minChunkMinutes,
      lessThanOrEqualTo(15),
      reason: '"每段至少 30 分钟"而总共只有 15 分钟，是一条自相矛盾的记录',
    );
    expect(task.maxChunkMinutes, lessThanOrEqualTo(15));
    expect(
      task.minChunkMinutes,
      lessThanOrEqualTo(task.maxChunkMinutes),
      reason: '夹紧之后仍须满足 min <= max',
    );
  });

  test('min > max ⇒ 上限被扶到下限，不会留下反向区间', () async {
    final schema = await verifier.schemaAt(7);
    addTearDown(schema.close);
    final old = v7.DatabaseAtV7(schema.newConnection());
    await insertV7Task(
      old,
      id: 'reversed',
      estimatedMinutes: 120,
      minChunk: 90,
      maxChunk: 30,
    );
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => DateTime.utc(2026, 10, 8),
    );
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 8);

    final task = await (db.select(
      db.tasks,
    )..where((row) => row.id.equals('reversed'))).getSingle();
    expect(task.minChunkMinutes, lessThanOrEqualTo(task.maxChunkMinutes));
  });

  test('**别的一律不动**：剩余时长、标题、备注、状态逐值保持', () async {
    final schema = await verifier.schemaAt(7);
    addTearDown(schema.close);
    final old = v7.DatabaseAtV7(schema.newConnection());
    await insertV7Task(
      old,
      id: 'keep',
      estimatedMinutes: 15,
      minChunk: 30,
      maxChunk: 90,
    );
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => DateTime.utc(2026, 10, 8),
    );
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 8);

    final task = await (db.select(
      db.tasks,
    )..where((row) => row.id.equals('keep'))).getSingle();
    // 片段被夹紧是这次迁移的**唯一**目的，因此下面这些必须原样：
    expect(task.estimatedMinutes, 15, reason: '预计时长是用户填的，不改');
    expect(task.remainingMinutes, 15, reason: '还剩多少工作不该被一次结构修复改写');
    expect(task.title, '贫困生材料提交');
    expect(task.notes, '别动我的备注', reason: '用户文本绝不能被迁移改写');
    expect(task.status, 'open');
    expect(task.createdAtUtc, 1000);
    expect(task.updatedAtUtc, 2000);
  });

  test('已经合法的行一个字节都不变（迁移不得"顺手规整"）', () async {
    final schema = await verifier.schemaAt(7);
    addTearDown(schema.close);
    final old = v7.DatabaseAtV7(schema.newConnection());
    await insertV7Task(
      old,
      id: 'legal',
      estimatedMinutes: 120,
      minChunk: 30,
      maxChunk: 60,
    );
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => DateTime.utc(2026, 10, 8),
    );
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 8);

    final task = await (db.select(
      db.tasks,
    )..where((row) => row.id.equals('legal'))).getSingle();
    expect(task.minChunkMinutes, 30);
    expect(task.maxChunkMinutes, 60);
  });

  test('多条混合行一次迁移全部扶正', () async {
    final schema = await verifier.schemaAt(7);
    addTearDown(schema.close);
    final old = v7.DatabaseAtV7(schema.newConnection());
    await insertV7Task(
      old,
      id: 'a',
      estimatedMinutes: 15,
      minChunk: 30,
      maxChunk: 90,
    );
    await insertV7Task(
      old,
      id: 'b',
      estimatedMinutes: 120,
      minChunk: 90,
      maxChunk: 30,
    );
    await insertV7Task(
      old,
      id: 'c',
      estimatedMinutes: 60,
      minChunk: 30,
      maxChunk: 60,
    );
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => DateTime.utc(2026, 10, 8),
    );
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 8);

    final rows = await db.select(db.tasks).get();
    expect(rows, hasLength(3));
    for (final task in rows) {
      expect(
        task.minChunkMinutes,
        lessThanOrEqualTo(task.maxChunkMinutes),
        reason: '${task.id} 迁移后仍是反向区间',
      );
      expect(
        task.minChunkMinutes,
        lessThanOrEqualTo(task.estimatedMinutes),
        reason: '${task.id} 的下限超过了总时长',
      );
      expect(
        task.maxChunkMinutes,
        lessThanOrEqualTo(task.estimatedMinutes),
        reason: '${task.id} 的上限超过了总时长',
      );
    }
  });

  test('**重复打开幂等**：迁移跑第二遍不改变任何值', () async {
    // 真实现象是"每次启动都打开数据库"，因此这个断言不是形式主义：如果迁移写成
    // "夹紧到 min(现值, …)" 之类非幂等的形式（例如拿已经被改过的值再去减一个量），
    // 用户的数据会在每次启动时继续漂移，而且没有任何报错。
    final schema = await verifier.schemaAt(7);
    addTearDown(schema.close);
    final old = v7.DatabaseAtV7(schema.newConnection());
    await insertV7Task(
      old,
      id: 'twice',
      estimatedMinutes: 15,
      minChunk: 30,
      maxChunk: 90,
    );
    await old.close();

    final first = AppDatabase(
      schema.newConnection(),
      now: () => DateTime.utc(2026, 10, 8),
    );
    await verifier.migrateAndValidate(first, 8);
    final afterFirst = await (first.select(
      first.tasks,
    )..where((row) => row.id.equals('twice'))).getSingle();
    await first.close();

    // 再开一次同一个库：此时它已经是 v8，`onUpgrade` 不该再跑 v8 那一步。
    final second = AppDatabase(
      schema.newConnection(),
      now: () => DateTime.utc(2026, 10, 8),
    );
    addTearDown(second.close);
    final afterSecond = await (second.select(
      second.tasks,
    )..where((row) => row.id.equals('twice'))).getSingle();

    expect(afterSecond.minChunkMinutes, afterFirst.minChunkMinutes);
    expect(afterSecond.maxChunkMinutes, afterFirst.maxChunkMinutes);
    expect(afterSecond.remainingMinutes, afterFirst.remainingMinutes);
  });

  test('v6 → v8 连续迁移：一次打开同时走完两步，用户数据完好', () async {
    // 真实用户跨的是**两个版本**（1.6.2 是 v6，1.7.0 是 v8），不是 v7 → v8。
    // 中间步漏跑是这类迁移最常见的失败，而 `versions` 组合测试只逐对验证结构、
    // 不带数据，因此这里专门跑一次连续链并逐值比对。
    final schema = await verifier.schemaAt(6);
    addTearDown(schema.close);
    final old = v6.DatabaseAtV6(schema.newConnection());
    await old
        .into(old.tasks)
        .insert(
          v6.TasksCompanion.insert(
            id: 'chain',
            title: '每周英语',
            priority: 'high',
            estimatedMinutes: 15,
            remainingMinutes: 15,
            energyLevel: 'medium',
            splitMode: 'splittable',
            minChunkMinutes: 30,
            maxChunkMinutes: 90,
            status: 'open',
            createdAtUtc: 1000,
            updatedAtUtc: 2000,
          ),
        );
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => DateTime.utc(2026, 10, 8),
    );
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 8);

    final task = await (db.select(
      db.tasks,
    )..where((row) => row.id.equals('chain'))).getSingle();
    expect(task.minChunkMinutes, lessThanOrEqualTo(15));
    expect(task.maxChunkMinutes, lessThanOrEqualTo(15));
    expect(task.remainingMinutes, 15);
    expect(task.title, '每周英语');

    // v7 建的两张周期表在链式迁移后必须存在且可用（否则 v7 那一步被跳过了）。
    await db
        .into(db.recurringTaskTemplates)
        .insert(
          RecurringTaskTemplatesCompanion.insert(
            id: 'template-1',
            title: '每周英语',
            targetMinutes: 180,
            priority: 'high',
            energyLevel: 'medium',
            splitMode: 'splittable',
            minChunkMinutes: 30,
            maxChunkMinutes: 60,
            pace: 'even',
            startsOnLocalDate: '2026-10-05',
            timeZoneId: 'Asia/Shanghai',
            createdAtUtc: 1000,
            updatedAtUtc: 2000,
          ),
        );
    expect(await db.select(db.recurringTaskTemplates).get(), hasLength(1));
  });
}
