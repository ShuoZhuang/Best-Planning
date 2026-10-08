import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:personal_planner/data/database/daos/task_dao.dart';
import 'package:personal_planner/data/database/tables/planner_tables.dart';

part 'app_database.g.dart';

/// 当前 schema 版本。
///
/// **必须是一个能在打开连接之前就读到的常量**：路线图 §4.3 要求升级前快照发生在
/// `AppDatabase.openDefault()` **之前**，而那一刻还没有任何 `AppDatabase` 实例可以问
/// 版本号。此前"版本"只活在 `schemaVersion` 这个实例 getter 里，于是装配层要么抄一个字面量
/// （抄错就等于**跳过备份**，而跳过备份正是这条规则要防的事），要么把这件破坏性动作塞进
/// 已经打开的连接之后。放在这里让两处共用同一个数字。
const int plannerSchemaVersion = 8;

DateTime _systemNowUtc() => DateTime.now().toUtc();

@DriftDatabase(
  tables: [
    Areas,
    Projects,
    Tasks,
    Tags,
    TaskTags,
    CalendarEvents,
    RecurrenceRules,
    AcademicTerms,
    PeriodTemplates,
    PeriodTemplateEntries,
    TimetableImportBatches,
    EnergyWindows,
    Settings,
    PlanVersions,
    ScheduleBlocks,
    TimeEntries,
    TaskCorrections,
    PreferenceEvidence,
    PreferenceRules,
    ChangeLog,
    RecurringTaskTemplates,
    RecurringTaskCycles,
  ],
  daos: [TaskDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase.openDefault({
    String? databasePath,
    Future<String?> Function()? tempDirectoryPath,
    DateTime Function()? now,
  }) : now = now ?? _systemNowUtc,
       // 生产装配**永远**启用外键：它是"项目必须挂在已存在的领域下""周期实例的任务必须
       // 真的存在"这些保证的唯一执行者。
       enforceForeignKeys = true,
       super(
         driftDatabase(
           name: 'personal_planner',
           native: DriftNativeOptions(
             databasePath: databasePath == null
                 ? null
                 : () async => databasePath,
             tempDirectoryPath: tempDirectoryPath,
           ),
         ),
       );

  AppDatabase.forTesting(
    super.e, {
    DateTime Function()? now,
    this.enforceForeignKeys = true,
  }) : now = now ?? _systemNowUtc;

  /// Opens the database against an existing [QueryExecutor]. Drift's generated
  /// migration tests use this form to point the database at a schema-managed
  /// connection, so it must stay positional and unnamed.
  AppDatabase(QueryExecutor e, {DateTime Function()? now})
    : this.forTesting(e, now: now);

  /// Instant source used to backfill timestamps added by a migration. Injectable
  /// so that migration tests can assert an exact value instead of a range.
  final DateTime Function() now;

  /// 是否在连接时启用 `PRAGMA foreign_keys`。**默认启用**，与生产完全一致。
  ///
  /// 只有一种情况需要关掉它：Widget 测试给页面注入的是**假的工作区仓储**（内存里的领域与
  /// 项目），而模板的 `area_id` 是指向 `areas` 表的真外键。此时"界面上选了学业"这条路径
  /// 会被外键拒绝，看起来像"保存坏了"，其实只是测试没有把领域写进真库。
  /// 关掉它让这些用例测量**界面行为**，而外键本身由 `recurring_task_dao_test` 与
  /// `schema_migration_test` 在真库上守着——两边分工明确，不会互相掩盖。
  final bool enforceForeignKeys;

  /// **必须是字面量**：`drift_dev make-migrations` 与 `drift_dev schema generate` 是**读源码**
  /// 的静态工具，它们解析不了 `=> plannerSchemaVersion` 这样的间接引用，会直接报
  /// "Could not read schema version"。上一行的常量因此多了一句"与这里保持一致"的义务，
  /// `test/app/pre_migration_backup_test.dart` 里有一条用例守着两者相等——那条用例存在的
  /// 唯一理由就是这个重复。
  @override
  int get schemaVersion => 8;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await _createRecurringTaskIndexes();
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 2 && to >= 2) {
        await _upgradeToV2(migrator);
      }
      if (from < 3 && to >= 3) {
        await migrator.createTable(taskCorrections);
      }
      if (from < 4 && to >= 4) {
        await _upgradeToV4(migrator);
      }
      if (from < 5 && to >= 5) {
        await _upgradeToV5(migrator);
      }
      if (from < 6 && to >= 6) {
        await _upgradeToV6(migrator);
      }
      if (from < 7 && to >= 7) {
        await _upgradeToV7(migrator);
      }
      if (from < 8 && to >= 8) {
        await _upgradeToV8();
      }
    },
    beforeOpen: (details) async {
      if (enforceForeignKeys) {
        await customStatement('PRAGMA foreign_keys = ON');
      }
      // **索引要在每次打开时都补**：v7 迁移里建过一次，但 `onCreate`（全新库）走的是
      // 另一条分支，两条分支各建一次索引就是两处需要同步维护的 SQL。`IF NOT EXISTS`
      // 让这里成为唯一一份定义——迁移与全新库都靠它。
      await _createRecurringTaskIndexes();
    },
  );

  /// v7 新增两张周期目标表与它们的索引（路线图 §4.3）。
  ///
  /// **刻意只新增**：`tasks`、`time_entries`、`calendar_events` 一个字段都不动。这两张表
  /// 的存在与否不影响任何既有查询，因此 v6 用户升级后他的任务、课表、计划、设置必须**逐值
  /// 不变**——§4.3 第一条与 §12 的"记录数量、外键和数据库文件保持有效"说的就是这件事。
  Future<void> _upgradeToV7(Migrator migrator) async {
    await migrator.createTable(recurringTaskTemplates);
    await migrator.createTable(recurringTaskCycles);
    await _createRecurringTaskIndexes();
  }

  /// v8：修复**存量的非法片段设置**（路线图 Task 12A Step 4）。
  ///
  /// 缺陷来源已由服务层堵住（`TaskService._normalizeChunks` 在保存时夹紧），但那管不到**已经
  /// 存进库里**的行。v7 及以前，`TaskDraft` 收什么存什么，而 `PlannerTask` 只校验
  /// `min > 0` 且 `min <= max`——它不知道任务总时长。于是库里可能存在两类自相矛盾的记录：
  ///
  /// 1. `min_chunk_minutes > max_chunk_minutes`（用户把两个框填反后保存成功）；
  /// 2. 片段上下限**超过任务总时长**（把预计时长从 120 分钟改成 15 分钟后，片段仍是 30–90）。
  ///
  /// 第 2 类会让候选生成一个片段都产不出来，任务于是既出现在"新增"里又出现在"未安排"里。
  ///
  /// **只夹紧片段两列，别的一律不动。** 任务的剩余时长、截止时间、开始时间、优先级、标题与备注
  /// 全部保持原值——这次迁移的正当理由只有一条："片段范围本身自相矛盾"。顺手改写"还剩多少工作"
  /// 或用户文本会让一次数据结构修复变成一次静默的数据变更，那是用户无从察觉的损失。
  /// `schema_migration_test` 里有逐列比对守着这一点。
  ///
  /// 夹紧规则与 `TaskService._normalizeChunks` 一致，并且**先修 min > max 再夹上限**：
  /// 先夹上限会让 `min > max` 的行得到 `min > 夹过的 max`，第二步又得再夹一次 min。
  ///
  /// 对 `recurring_task_templates` 用 `target_minutes` 作上限（那是模板的"总时长"）。
  /// 周期模板的片段范围同样是矛盾的来源，且它比任务更早——模板是生成任务的输入。
  Future<void> _upgradeToV8() async {
    // 1) 上限不得小于下限（把两列填反的行扶正）。
    await customStatement(
      'UPDATE tasks SET max_chunk_minutes = min_chunk_minutes '
      'WHERE max_chunk_minutes < min_chunk_minutes',
    );
    await customStatement(
      'UPDATE recurring_task_templates SET max_chunk_minutes = min_chunk_minutes '
      'WHERE max_chunk_minutes < min_chunk_minutes',
    );
    // 2) 两列都不得超过总时长。`estimated_minutes` / `target_minutes` 恒为正
    //    （建表时就有 CHECK），因此这里不需要处理"总时长为 0"的除零式边界。
    await customStatement(
      'UPDATE tasks SET '
      'min_chunk_minutes = MIN(min_chunk_minutes, estimated_minutes), '
      'max_chunk_minutes = MIN(max_chunk_minutes, estimated_minutes) '
      'WHERE min_chunk_minutes > estimated_minutes '
      '   OR max_chunk_minutes > estimated_minutes',
    );
    await customStatement(
      'UPDATE recurring_task_templates SET '
      'min_chunk_minutes = MIN(min_chunk_minutes, target_minutes), '
      'max_chunk_minutes = MIN(max_chunk_minutes, target_minutes) '
      'WHERE min_chunk_minutes > target_minutes '
      '   OR max_chunk_minutes > target_minutes',
    );
  }

  /// 周期目标表的索引。
  ///
  /// 两条查询各自需要一条：
  /// - `listCyclesInRange` 按 `period_start_local_date` 扫一个日期区间。联合主键是
  ///   `(template_id, period_start_local_date)`，**前导列是模板**，因此按日期查用不上它；
  /// - `recordedMinutesForTask` 按 `task_id` 汇总 `time_entries`。`time_entries` 上只有
  ///   主键索引，而这条查询每周都会为每个周期目标跑一次。
  ///
  /// `task_id` 的 UNIQUE 约束会自带索引，所以这里不重复建。
  ///
  /// **表不存在时安静跳过**。它会在 `beforeOpen` 里被调用，而 `drift_dev` 的迁移测试
  /// （`SchemaVerifier.migrateAndValidate`）会**逐个中间版本**打开同一个类——v1→v2 时
  /// 这两张表当然还不存在，此时索引语句会以 `no such table` 失败。索引是在 v7 才有的东西，
  /// 为它加一个"只在 v7 存在"的分支比在每次打开时判断版本更简单，也照样保证**全新库与
  /// v7 迁移后的库都有索引**（见 `_createRecurringTaskIndexes` 的两个调用点）。
  Future<void> _createRecurringTaskIndexes() async {
    const statements = [
      'CREATE INDEX IF NOT EXISTS idx_recurring_cycles_period_start '
          'ON recurring_task_cycles (period_start_local_date)',
      'CREATE INDEX IF NOT EXISTS idx_time_entries_task_started '
          'ON time_entries (task_id, started_at_utc)',
    ];
    for (final statement in statements) {
      try {
        await customStatement(statement);
      } on Exception {
        // 只有"目标表还不存在"会走到这里；其它失败（磁盘只读等）会在紧随其后的真实
        // 查询上以更准确的形式暴露，不该在这里被猜成索引问题。
      }
    }
  }

  /// v2 adds custom tags, the task preferred-time window, the area life flag,
  /// and the FR-DATA-08 creation and modification timestamps that were missing
  /// from several core tables.
  ///
  /// Existing rows cannot be given their true creation time, which was never
  /// recorded, so every column added here is backfilled with the instantaneous
  /// migration time. The columns are declared `NOT NULL` with the
  /// [unsetTimestamp] sentinel because SQLite cannot add a `NOT NULL` column
  /// without a default; the backfill below replaces the sentinel in every
  /// historical row, so no row survives the migration holding it.
  Future<void> _upgradeToV2(Migrator migrator) async {
    // Tags must exist before the join table that references them.
    await migrator.createTable(tags);
    await migrator.createTable(taskTags);

    await migrator.addColumn(areas, areas.isLife);
    await migrator.addColumn(areas, areas.createdAtUtc);
    await migrator.addColumn(areas, areas.updatedAtUtc);

    await migrator.addColumn(projects, projects.createdAtUtc);
    await migrator.addColumn(projects, projects.updatedAtUtc);

    await migrator.addColumn(tasks, tasks.preferredStartMinute);
    await migrator.addColumn(tasks, tasks.preferredEndMinute);

    await migrator.addColumn(recurrenceRules, recurrenceRules.createdAtUtc);
    await migrator.addColumn(recurrenceRules, recurrenceRules.updatedAtUtc);

    await migrator.addColumn(energyWindows, energyWindows.createdAtUtc);
    await migrator.addColumn(energyWindows, energyWindows.updatedAtUtc);

    await migrator.addColumn(calendarEvents, calendarEvents.createdAtUtc);

    await migrator.addColumn(settings, settings.createdAtUtc);

    await migrator.addColumn(scheduleBlocks, scheduleBlocks.createdAtUtc);
    await migrator.addColumn(scheduleBlocks, scheduleBlocks.updatedAtUtc);

    await migrator.addColumn(timeEntries, timeEntries.createdAtUtc);
    await migrator.addColumn(timeEntries, timeEntries.updatedAtUtc);

    await _backfillTimestamps();
  }

  /// Writes the migration instant into every timestamp column that this
  /// migration introduced, leaving columns that already held a real value
  /// untouched.
  Future<void> _backfillTimestamps() async {
    final instant = now().toUtc().microsecondsSinceEpoch;

    final added = <TableInfo, List<GeneratedColumn<Object>>>{
      areas: [areas.createdAtUtc, areas.updatedAtUtc],
      projects: [projects.createdAtUtc, projects.updatedAtUtc],
      recurrenceRules: [
        recurrenceRules.createdAtUtc,
        recurrenceRules.updatedAtUtc,
      ],
      energyWindows: [energyWindows.createdAtUtc, energyWindows.updatedAtUtc],
      calendarEvents: [calendarEvents.createdAtUtc],
      settings: [settings.createdAtUtc],
      scheduleBlocks: [
        scheduleBlocks.createdAtUtc,
        scheduleBlocks.updatedAtUtc,
      ],
      timeEntries: [timeEntries.createdAtUtc, timeEntries.updatedAtUtc],
    };

    for (final entry in added.entries) {
      final table = entry.key.actualTableName;
      for (final column in entry.value) {
        await customStatement(
          'UPDATE $table SET ${column.name} = ? WHERE ${column.name} = ?',
          [instant, unsetTimestamp],
        );
      }
    }
  }

  /// Adds task-level classification and the hard earliest-start constraint.
  ///
  /// Legacy tasks attached to a project inherit that project's area. Tasks
  /// without a project deliberately remain unclassified until the user edits
  /// them, because guessing a default area would corrupt existing data.
  Future<void> _upgradeToV4(Migrator migrator) async {
    await migrator.addColumn(tasks, tasks.areaId);
    await migrator.addColumn(tasks, tasks.availableFromUtc);
    await customStatement('''
      UPDATE tasks
      SET area_id = (
        SELECT projects.area_id
        FROM projects
        WHERE projects.id = tasks.project_id
      )
      WHERE project_id IS NOT NULL AND area_id IS NULL
    ''');
  }

  /// Adds academic-calendar configuration and interval-week recurrence.
  ///
  /// The new recurrence column has a database default of one, so existing
  /// weekly series keep producing the exact same occurrences after migration.
  Future<void> _upgradeToV5(Migrator migrator) async {
    await migrator.addColumn(recurrenceRules, recurrenceRules.intervalWeeks);
    await migrator.createTable(academicTerms);
    await migrator.createTable(periodTemplates);
    await migrator.createTable(periodTemplateEntries);
  }

  /// Adds the audit batch before event references, then gives legacy events
  /// safe manual-source defaults without guessing course metadata.
  Future<void> _upgradeToV6(Migrator migrator) async {
    await migrator.createTable(timetableImportBatches);
    await migrator.addColumn(calendarEvents, calendarEvents.projectId);
    await migrator.addColumn(calendarEvents, calendarEvents.location);
    await migrator.addColumn(calendarEvents, calendarEvents.notes);
    await migrator.addColumn(calendarEvents, calendarEvents.sourceKind);
    await migrator.addColumn(calendarEvents, calendarEvents.importBatchId);
    await migrator.addColumn(calendarEvents, calendarEvents.logicalCourseId);
  }
}
