// Verification for the database schema migrations (R1, R5, R10, R13, FR-TASK-05).
//
// Every version pair is validated against the generated snapshots, and the v1 to v3
// path additionally carries data through so the backfill is actually exercised.
//
// The data half of this file matters more than the schema comparison: v2 adds
// FR-DATA-08 creation and modification timestamps to tables whose existing rows
// never recorded a creation time, and the agreed policy is to fill those
// historical rows with the migration instant. SQLite cannot add a NOT NULL
// column without a default, so the columns are declared with the sentinel
// default and this migration backfills them. If the backfill were dropped, the
// assertions below would still pass for a fresh database but the historical rows
// would keep the sentinel, which is what the timestamp assertions catch.
//
// After changing the schema, refresh the snapshot and the helpers under
// `generated/` with:
//
//   dart run build_runner build
//   dart run drift_dev make-migrations
//   dart run drift_dev schema generate drift_schemas/app_database/ \
//       test/drift/app_database/generated/ --data-classes --companions
//
// The per-database directory matters: pointing the last command at
// `drift_schemas/` itself writes an empty helper that fails to compile.
// drift exports its own `isNull` expression helper, which would shadow the
// matcher of the same name used by the assertions below.
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';

import 'generated/schema.dart';
import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v3.dart' as v3;
import 'generated/schema_v4.dart' as v4;
import 'generated/schema_v5.dart' as v5;
import 'generated/schema_v6.dart' as v6;
import 'generated/schema_v9.dart' as v9;

/// Fixed so that the backfilled values can be asserted exactly. The codebase
/// stores instants as microseconds since the Unix epoch, so the migration
/// backfills the same unit.
final _migrationInstant = DateTime.utc(2025, 8, 1, 12);
final _migrationInstantUs = _migrationInstant.microsecondsSinceEpoch;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test(
    'generated schema includes the partially deleted batch state version 11',
    () {
      expect(GeneratedHelper.versions.last, 11);
      expect(plannerSchemaVersion, 11);
    },
  );

  // 覆盖全部版本组合：v1→v2、v1→v3、v2→v3。漏掉任何一步都会在这里被判为结构不符。
  const versions = GeneratedHelper.versions;
  for (final (index, fromVersion) in versions.indexed) {
    for (final toVersion in versions.skip(index + 1)) {
      test(
        'an empty v$fromVersion database migrates to the v$toVersion schema',
        () async {
          final schema = await verifier.schemaAt(fromVersion);
          final db = AppDatabase(
            schema.newConnection(),
            now: () => _migrationInstant,
          );

          await verifier.migrateAndValidate(db, toVersion);

          await db.close();
          schema.close();
        },
      );
    }
  }

  test('v1 rows survive and gain the migration instant', () async {
    final schema = await verifier.schemaAt(1);
    final old = v1.DatabaseAtV1(schema.newConnection());

    await old
        .into(old.areas)
        .insert(
          v1.AreasCompanion.insert(
            id: 'area-work',
            name: '工作',
            color: 17,
            sortOrder: 0,
          ),
        );
    await old
        .into(old.areas)
        .insert(
          v1.AreasCompanion.insert(
            id: 'area-life',
            name: '生活',
            color: 34,
            sortOrder: 1,
          ),
        );
    await old
        .into(old.projects)
        .insert(
          v1.ProjectsCompanion.insert(
            id: 'proj-1',
            areaId: 'area-work',
            name: '项目甲',
          ),
        );
    await old
        .into(old.tasks)
        .insert(
          v1.TasksCompanion.insert(
            id: 'task-1',
            projectId: const Value('proj-1'),
            title: '写方案',
            priority: 'high',
            estimatedMinutes: 120,
            remainingMinutes: 90,
            energyLevel: 'high',
            splitMode: 'allow',
            minChunkMinutes: 30,
            maxChunkMinutes: 60,
            status: 'planned',
            createdAtUtc: 1000,
            updatedAtUtc: 2000,
          ),
        );
    await old
        .into(old.planVersions)
        .insert(
          v1.PlanVersionsCompanion.insert(
            id: 'plan-1',
            createdAtUtc: 3000,
            inputHash: 'hash',
            algorithmVersion: '1',
            status: 'confirmed',
            summaryJson: '{}',
          ),
        );
    await old
        .into(old.recurrenceRules)
        .insert(
          v1.RecurrenceRulesCompanion.insert(
            id: 'rule-1',
            weekdaysMask: 62,
            localStartMinute: 540,
            durationMinutes: 60,
            validFromLocalDate: '2025-01-01',
            timeZoneId: 'Asia/Shanghai',
          ),
        );
    await old
        .into(old.calendarEvents)
        .insert(
          v1.CalendarEventsCompanion.insert(
            id: 'event-1',
            title: '周会',
            startAtUtc: 4000,
            endAtUtc: 5000,
            timeZoneId: 'Asia/Shanghai',
            updatedAtUtc: 6000,
          ),
        );
    await old
        .into(old.energyWindows)
        .insert(
          v1.EnergyWindowsCompanion.insert(
            id: 'window-1',
            dayKind: 'workday',
            startMinute: 540,
            endMinute: 660,
            energyLevel: 'high',
            source: 'user',
          ),
        );
    await old
        .into(old.settings)
        .insert(
          v1.SettingsCompanion.insert(
            key: 'theme',
            jsonValue: '"dark"',
            updatedAtUtc: 7000,
          ),
        );
    await old
        .into(old.scheduleBlocks)
        .insert(
          v1.ScheduleBlocksCompanion.insert(
            id: 'block-1',
            planVersionId: 'plan-1',
            taskId: 'task-1',
            startAtUtc: 8000,
            endAtUtc: 9000,
            explanationCode: 'fits_energy_window',
          ),
        );
    await old
        .into(old.timeEntries)
        .insert(
          v1.TimeEntriesCompanion.insert(
            id: 'entry-1',
            taskId: 'task-1',
            startedAtUtc: 10000,
            source: 'timer',
            recoveryState: 'none',
          ),
        );
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => _migrationInstant,
    );
    await verifier.migrateAndValidate(db, 9);

    // Pre-existing values are preserved and every timestamp column added by the
    // migration holds the migration instant rather than the sentinel.
    final areas = await db.select(db.areas).get();
    expect(areas, hasLength(2));
    final work = areas.singleWhere((area) => area.id == 'area-work');
    expect(work.name, '工作');
    expect(work.color, 17);
    expect(work.sortOrder, 0);
    // The life flag is a new column, so it takes its declared default.
    expect(work.isLife, isFalse);
    expect(work.createdAtUtc, _migrationInstantUs);
    expect(work.updatedAtUtc, _migrationInstantUs);

    final task = await db.select(db.tasks).getSingle();
    expect(task.projectId, 'proj-1');
    expect(task.title, '写方案');
    expect(task.remainingMinutes, 90);
    // These columns already existed, so the true values must be untouched.
    expect(task.createdAtUtc, 1000);
    expect(task.updatedAtUtc, 2000);
    // The preferred window is new and optional, so it stays unset.
    expect(task.preferredStartMinute, isNull);
    expect(task.preferredEndMinute, isNull);

    final event = await db.select(db.calendarEvents).getSingle();
    expect(event.updatedAtUtc, 6000);
    expect(event.createdAtUtc, _migrationInstantUs);

    final setting = await db.select(db.settings).getSingle();
    expect(setting.jsonValue, '"dark"');
    expect(setting.updatedAtUtc, 7000);
    expect(setting.createdAtUtc, _migrationInstantUs);

    final block = await db.select(db.scheduleBlocks).getSingle();
    expect(block.startAtUtc, 8000);
    expect(block.createdAtUtc, _migrationInstantUs);
    expect(block.updatedAtUtc, _migrationInstantUs);

    final entry = await db.select(db.timeEntries).getSingle();
    expect(entry.startedAtUtc, 10000);
    expect(entry.createdAtUtc, _migrationInstantUs);
    expect(entry.updatedAtUtc, _migrationInstantUs);

    final rule = await db.select(db.recurrenceRules).getSingle();
    expect(rule.localStartMinute, 540);
    expect(rule.intervalWeeks, 1);
    expect(rule.createdAtUtc, _migrationInstantUs);
    expect(rule.updatedAtUtc, _migrationInstantUs);

    final window = await db.select(db.energyWindows).getSingle();
    expect(window.startMinute, 540);
    expect(window.createdAtUtc, _migrationInstantUs);
    expect(window.updatedAtUtc, _migrationInstantUs);

    final project = await db.select(db.projects).getSingle();
    expect(project.areaId, 'area-work');
    expect(project.createdAtUtc, _migrationInstantUs);
    expect(project.updatedAtUtc, _migrationInstantUs);

    // The tables added in v2 start empty and are usable.
    expect(await db.select(db.tags).get(), isEmpty);
    expect(await db.select(db.taskTags).get(), isEmpty);
    await db
        .into(db.tags)
        .insert(TagsCompanion.insert(id: 'tag-1', name: '深度工作'));
    await db
        .into(db.taskTags)
        .insert(TaskTagsCompanion.insert(taskId: 'task-1', tagId: 'tag-1'));
    expect((await db.select(db.tags).getSingle()).name, '深度工作');

    // v3 的剩余时长修正记录表：迁移后存在、可用，且保留修正前后两个值。
    expect(await db.select(db.taskCorrections).get(), isEmpty);
    await db
        .into(db.taskCorrections)
        .insert(
          TaskCorrectionsCompanion.insert(
            id: 'correction-1',
            taskId: 'task-1',
            previousMinutes: 90,
            correctedMinutes: 120,
            correctedAtUtc: _migrationInstantUs,
          ),
        );
    final correction = await db.select(db.taskCorrections).getSingle();
    expect(correction.taskId, 'task-1');
    expect(correction.previousMinutes, 90);
    expect(correction.correctedMinutes, 120);

    await db.close();
    schema.close();
  });

  test('v3 task with project backfills direct area', () async {
    final schema = await verifier.schemaAt(3);
    final old = v3.DatabaseAtV3(schema.newConnection());

    await old
        .into(old.areas)
        .insert(
          v3.AreasCompanion.insert(
            id: 'area-study',
            name: '学业',
            color: 17,
            sortOrder: 0,
          ),
        );
    await old
        .into(old.projects)
        .insert(
          v3.ProjectsCompanion.insert(
            id: 'project-algorithm',
            areaId: 'area-study',
            name: '算法课',
          ),
        );
    await old
        .into(old.tasks)
        .insert(_v3Task(id: 'task-project', projectId: 'project-algorithm'));
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => _migrationInstant,
    );
    await verifier.migrateAndValidate(db, 9);

    final task = await db.select(db.tasks).getSingle();
    expect(task.areaId, 'area-study');
    expect(task.availableFromUtc, isNull);

    await db.close();
    schema.close();
  });

  test('v3 projectless task stays unclassified', () async {
    final schema = await verifier.schemaAt(3);
    final old = v3.DatabaseAtV3(schema.newConnection());

    await old.into(old.tasks).insert(_v3Task(id: 'task-legacy'));
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => _migrationInstant,
    );
    await verifier.migrateAndValidate(db, 9);

    final task = await db.select(db.tasks).getSingle();
    expect(task.areaId, isNull);
    expect(task.availableFromUtc, isNull);

    await db.close();
    schema.close();
  });

  test(
    'v4 task fields survive migration and academic tables enforce keys',
    () async {
      final schema = await verifier.schemaAt(4);
      final old = v4.DatabaseAtV4(schema.newConnection());

      await old
          .into(old.areas)
          .insert(
            v4.AreasCompanion.insert(
              id: 'area-study',
              name: '学业',
              color: 17,
              sortOrder: 0,
            ),
          );
      await old
          .into(old.tasks)
          .insert(
            v4.TasksCompanion.insert(
              id: 'task-v4',
              areaId: const Value('area-study'),
              title: '迁移任务',
              priority: 'medium',
              estimatedMinutes: 50,
              remainingMinutes: 50,
              availableFromUtc: const Value(123456),
              energyLevel: 'high',
              splitMode: 'continuous',
              minChunkMinutes: 50,
              maxChunkMinutes: 50,
              status: 'open',
              createdAtUtc: 1000,
              updatedAtUtc: 2000,
            ),
          );
      await old
          .into(old.recurrenceRules)
          .insert(
            v4.RecurrenceRulesCompanion.insert(
              id: 'rule-v4',
              weekdaysMask: 2,
              localStartMinute: 480,
              durationMinutes: 100,
              validFromLocalDate: '2026-09-07',
              timeZoneId: 'Asia/Shanghai',
            ),
          );
      await old.close();

      final db = AppDatabase(
        schema.newConnection(),
        now: () => _migrationInstant,
      );
      await verifier.migrateAndValidate(db, 9);

      final task = await db.select(db.tasks).getSingle();
      expect(task.areaId, 'area-study');
      expect(task.availableFromUtc, 123456);
      expect(
        (await db.select(db.recurrenceRules).getSingle()).intervalWeeks,
        1,
      );

      await db
          .into(db.academicTerms)
          .insert(
            AcademicTermsCompanion.insert(
              id: 'term-2026-autumn',
              name: '2026 秋季学期',
              firstWeekMondayLocalDate: '2026-09-07',
              totalWeeks: 16,
              timeZoneId: 'Asia/Shanghai',
              createdAtUtc: 3000,
              updatedAtUtc: 3000,
            ),
          );
      await db
          .into(db.periodTemplates)
          .insert(
            PeriodTemplatesCompanion.insert(
              id: 'template-main',
              name: '主校区',
              createdAtUtc: 4000,
              updatedAtUtc: 4000,
            ),
          );
      await db.batch((batch) {
        batch.insertAll(db.periodTemplateEntries, [
          PeriodTemplateEntriesCompanion.insert(
            templateId: 'template-main',
            periodNumber: 1,
            startMinute: 480,
            endMinute: 525,
          ),
          PeriodTemplateEntriesCompanion.insert(
            templateId: 'template-main',
            periodNumber: 2,
            startMinute: 535,
            endMinute: 580,
          ),
        ]);
      });
      expect(await db.select(db.periodTemplateEntries).get(), hasLength(2));

      await expectLater(
        db
            .into(db.periodTemplateEntries)
            .insert(
              PeriodTemplateEntriesCompanion.insert(
                templateId: 'template-main',
                periodNumber: 1,
                startMinute: 600,
                endMinute: 645,
              ),
            ),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        db
            .into(db.periodTemplateEntries)
            .insert(
              PeriodTemplateEntriesCompanion.insert(
                templateId: 'missing-template',
                periodNumber: 3,
                startMinute: 650,
                endMinute: 695,
              ),
            ),
        throwsA(isA<Exception>()),
      );

      await db.close();
      schema.close();
    },
  );

  test(
    'v5 events gain safe defaults and import batches enforce term keys',
    () async {
      final schema = await verifier.schemaAt(5);
      final old = v5.DatabaseAtV5(schema.newConnection());

      await old
          .into(old.calendarEvents)
          .insert(
            v5.CalendarEventsCompanion.insert(
              id: 'legacy-event',
              title: '旧日程',
              startAtUtc: 1000,
              endAtUtc: 2000,
              timeZoneId: 'Asia/Shanghai',
              updatedAtUtc: 3000,
            ),
          );
      await old.close();

      final db = AppDatabase(
        schema.newConnection(),
        now: () => _migrationInstant,
      );
      await verifier.migrateAndValidate(db, 9);

      final event = await db.select(db.calendarEvents).getSingle();
      expect(event.projectId, isNull);
      expect(event.location, isEmpty);
      expect(event.notes, isEmpty);
      expect(event.sourceKind, 'manual');
      expect(event.importBatchId, isNull);
      expect(event.logicalCourseId, isNull);

      await db
          .into(db.academicTerms)
          .insert(
            AcademicTermsCompanion.insert(
              id: 'term-2026-autumn',
              name: '2026 秋季学期',
              firstWeekMondayLocalDate: '2026-09-07',
              totalWeeks: 16,
              timeZoneId: 'Asia/Shanghai',
              createdAtUtc: 4000,
              updatedAtUtc: 4000,
            ),
          );
      await db
          .into(db.timetableImportBatches)
          .insert(
            TimetableImportBatchesCompanion.insert(
              id: 'batch-1',
              termId: 'term-2026-autumn',
              sourceImageHash: 'sha256:test',
              sourceFileName: 'schedule.png',
              status: 'committed',
              createdEventCount: 1,
              createdAtUtc: 5000,
              updatedAtUtc: 5000,
            ),
          );
      await expectLater(
        db
            .into(db.timetableImportBatches)
            .insert(
              TimetableImportBatchesCompanion.insert(
                id: 'batch-invalid',
                termId: 'missing-term',
                sourceImageHash: 'sha256:missing',
                sourceFileName: 'missing.png',
                status: 'committed',
                createdEventCount: 0,
                createdAtUtc: 6000,
                updatedAtUtc: 6000,
              ),
            ),
        throwsA(isA<Exception>()),
      );

      await db.close();
      schema.close();
    },
  );

  // v6 → v7 的三条路径（路线图 §4.3 最后两条）：空库、v6 带外键数据、以及"只新增"。
  //
  // 第三条是本组用例真正要证明的事：**既有三张表一个字段都不许动**。所以这里不只断言
  // "两张新表在不在"，还把迁移前的任务、日程、设置、计划块逐值抄下来比对，并跑一次
  // `PRAGMA foreign_key_check`——只比表结构的话，"迁移顺手改了一列"这种缺陷看不出来。

  test('空库建到 v7，两张周期目标表可用且索引存在', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final tables = await database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    expect(
      tables.map((row) => row.read<String>('name')).toSet(),
      containsAll(<String>[
        'recurring_task_templates',
        'recurring_task_cycles',
      ]),
    );
    final indexes = await database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
        .get();
    expect(
      indexes.map((row) => row.read<String>('name')),
      containsAll(<String>[
        'idx_recurring_cycles_period_start',
        'idx_time_entries_task_started',
      ]),
    );
    // 外键在全新库里同样生效：指向不存在的模板会被拒。
    await expectLater(
      database.customInsert(
        'INSERT INTO recurring_task_cycles ('
        'template_id, period_start_local_date, task_id, base_target_minutes, '
        'carry_in_minutes, status, created_at_utc, updated_at_utc'
        ") VALUES ('missing', '2026-10-05', 't', 180, 0, 'open', 1, 1)",
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('v6 带数据升级到 v7：既有记录逐值不变，外键干净，新表可用', () async {
    final schema = await verifier.schemaAt(6);
    final old = v6.DatabaseAtV6(schema.newConnection());

    await old
        .into(old.areas)
        .insert(
          v6.AreasCompanion.insert(
            id: 'area-study',
            name: '学业',
            color: 17,
            sortOrder: 0,
          ),
        );
    await old
        .into(old.projects)
        .insert(
          v6.ProjectsCompanion.insert(
            id: 'project-algorithm',
            areaId: 'area-study',
            name: '算法课',
          ),
        );
    await old
        .into(old.tasks)
        .insert(
          v6.TasksCompanion.insert(
            id: 'task-1',
            projectId: const Value('project-algorithm'),
            areaId: const Value('area-study'),
            title: '算法作业',
            priority: 'high',
            estimatedMinutes: 120,
            remainingMinutes: 90,
            energyLevel: 'high',
            splitMode: 'splittable',
            minChunkMinutes: 30,
            maxChunkMinutes: 60,
            preferredStartMinute: const Value(1200),
            preferredEndMinute: const Value(1320),
            status: 'open',
            createdAtUtc: 1000,
            updatedAtUtc: 2000,
          ),
        );
    await old
        .into(old.calendarEvents)
        .insert(
          v6.CalendarEventsCompanion.insert(
            id: 'event-1',
            title: '算法课',
            startAtUtc: 3000,
            endAtUtc: 4000,
            timeZoneId: 'Asia/Shanghai',
            areaId: const Value('area-study'),
            sourceKind: const Value('timetableImport'),
            updatedAtUtc: 5000,
          ),
        );
    await old
        .into(old.settings)
        .insert(
          v6.SettingsCompanion.insert(
            key: 'theme',
            jsonValue: '"dark"',
            updatedAtUtc: 6000,
          ),
        );
    await old
        .into(old.planVersions)
        .insert(
          v6.PlanVersionsCompanion.insert(
            id: 'plan-1',
            createdAtUtc: 7000,
            inputHash: 'hash',
            algorithmVersion: '9',
            status: 'confirmed',
            summaryJson: '{}',
          ),
        );
    await old
        .into(old.scheduleBlocks)
        .insert(
          v6.ScheduleBlocksCompanion.insert(
            id: 'block-1',
            planVersionId: 'plan-1',
            taskId: 'task-1',
            startAtUtc: 8000,
            endAtUtc: 9000,
            explanationCode: 'fits_energy_window',
          ),
        );
    await old
        .into(old.timeEntries)
        .insert(
          v6.TimeEntriesCompanion.insert(
            id: 'entry-1',
            taskId: 'task-1',
            startedAtUtc: 8000,
            endedAtUtc: const Value(9000),
            source: 'user',
            recoveryState: 'confirmed',
          ),
        );
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => _migrationInstant,
    );
    await verifier.migrateAndValidate(db, 9);

    // ① 记录数量逐个核对。
    expect(await db.select(db.areas).get(), hasLength(1));
    expect(await db.select(db.projects).get(), hasLength(1));
    expect(await db.select(db.tasks).get(), hasLength(1));
    expect(await db.select(db.calendarEvents).get(), hasLength(1));
    expect(await db.select(db.settings).get(), hasLength(1));
    expect(await db.select(db.planVersions).get(), hasLength(1));
    expect(await db.select(db.scheduleBlocks).get(), hasLength(1));
    expect(await db.select(db.timeEntries).get(), hasLength(1));

    // ② 逐值不变：包括 v4/v5/v6 加进来的字段，一个都不许被这次迁移碰到。
    final task = await db.select(db.tasks).getSingle();
    expect(task.id, 'task-1');
    expect(task.projectId, 'project-algorithm');
    expect(task.areaId, 'area-study');
    expect(task.title, '算法作业');
    expect(task.estimatedMinutes, 120);
    expect(task.remainingMinutes, 90);
    expect(task.preferredStartMinute, 1200);
    expect(task.preferredEndMinute, 1320);
    expect(task.createdAtUtc, 1000);
    expect(task.updatedAtUtc, 2000);

    final event = await db.select(db.calendarEvents).getSingle();
    expect(event.title, '算法课');
    expect(event.areaId, 'area-study');
    expect(event.sourceKind, 'timetableImport');
    expect(event.startAtUtc, 3000);
    expect(event.updatedAtUtc, 5000);

    final entry = await db.select(db.timeEntries).getSingle();
    expect(entry.startedAtUtc, 8000);
    expect(entry.endedAtUtc, 9000);
    expect(entry.recoveryState, 'confirmed');

    final setting = await db.select(db.settings).getSingle();
    expect(setting.jsonValue, '"dark"');
    expect((await db.select(db.scheduleBlocks).getSingle()).startAtUtc, 8000);

    // ③ 外键检查结果必须干净（带数据的 v6 → v7 是 §12 明确要求的一条）。
    final violations = await db.customSelect('PRAGMA foreign_key_check').get();
    expect(violations, isEmpty);

    // ④ 新表此时存在、可写，而且外键与联合唯一键都真的生效。
    expect(await db.select(db.recurringTaskTemplates).get(), isEmpty);
    expect(await db.select(db.recurringTaskCycles).get(), isEmpty);
    await db
        .into(db.recurringTaskTemplates)
        .insert(
          RecurringTaskTemplatesCompanion.insert(
            id: 'template-1',
            title: '每周英语',
            targetMinutes: 180,
            priority: 'medium',
            energyLevel: 'medium',
            splitMode: 'splittable',
            minChunkMinutes: 25,
            maxChunkMinutes: 90,
            pace: 'even',
            startsOnLocalDate: '2026-10-05',
            timeZoneId: 'Asia/Shanghai',
            createdAtUtc: 10000,
            updatedAtUtc: 10000,
          ),
        );
    await db
        .into(db.recurringTaskCycles)
        .insert(
          RecurringTaskCyclesCompanion.insert(
            templateId: 'template-1',
            periodStartLocalDate: '2026-10-05',
            taskId: 'task-1',
            baseTargetMinutes: 180,
            createdAtUtc: 10000,
            updatedAtUtc: 10000,
          ),
        );
    // 同一个 (模板, 周期) 再来一次必须被联合主键拒绝——"连续启动十次只有一个实例"
    // （§7.2 第一条）就是靠这一条约束落地的。
    await expectLater(
      db
          .into(db.recurringTaskCycles)
          .insert(
            RecurringTaskCyclesCompanion.insert(
              templateId: 'template-1',
              periodStartLocalDate: '2026-10-05',
              taskId: 'task-1',
              baseTargetMinutes: 180,
              createdAtUtc: 11000,
              updatedAtUtc: 11000,
            ),
          ),
      throwsA(isA<Exception>()),
    );
    // 一个任务只能属于一个周期实例。
    await expectLater(
      db
          .into(db.recurringTaskCycles)
          .insert(
            RecurringTaskCyclesCompanion.insert(
              templateId: 'template-1',
              periodStartLocalDate: '2026-10-12',
              taskId: 'task-1',
              baseTargetMinutes: 180,
              createdAtUtc: 12000,
              updatedAtUtc: 12000,
            ),
          ),
      throwsA(isA<Exception>()),
    );

    await db.close();
    schema.close();
  });

  test('v6 迁移到 v9 后旧表只多了 v9 的 calendar_events.kind', () async {
    final schema = await verifier.schemaAt(6);
    final old = v6.DatabaseAtV6(schema.newConnection());
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => _migrationInstant,
    );
    await verifier.migrateAndValidate(db, 9);

    for (final table in ['tasks', 'time_entries']) {
      final columns = await db.customSelect('PRAGMA table_info($table)').get();
      expect(
        columns.map((row) => row.read<String>('name')).toList(),
        _v6ColumnsOf(table),
        reason: '$table 的列集合必须与 v6 一致：v7 只新增表，v8/v9 都不动它',
      );
    }

    // **`calendar_events` 是唯一有结构变化的表**（规范 §14："唯一结构变化是
    // `calendar_events.kind`"）。因此这里的断言从"完全未变"改成"**只**多了这一列"：
    // 先逐项比对 v6 的前缀（一个不少、顺序不变），再要求多出来的部分**恰好**是 `kind`。
    // 任何别的增减都会让这两条之一失败。
    final calendarColumns = await db
        .customSelect('PRAGMA table_info(calendar_events)')
        .get();
    final names = calendarColumns
        .map((row) => row.read<String>('name'))
        .toList();
    final v6Names = _v6ColumnsOf('calendar_events');
    expect(
      names.sublist(0, v6Names.length),
      v6Names,
      reason: 'v6 的列必须一个不少、顺序不变',
    );
    expect(names.sublist(v6Names.length), [
      'kind',
    ], reason: 'v9 只准新增 kind 这一列（规范 §14）');

    await db.close();
    schema.close();
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Task 5（课程编辑完整性修复计划）：v9 → v10 只扩充批次状态的允许值
  // ───────────────────────────────────────────────────────────────────────────

  test('M1：v9 → v10 只扩充批次 status 的 CHECK，业务数据逐值不变', () async {
    final schema = await verifier.schemaAt(9);
    // 直接在 v9 的裸连接上写数据：这几行代表用户库里的真实内容，而
    // `migrateAndValidate` 之后要逐值比对它们**一个都没变**。
    final old = v9.DatabaseAtV9(schema.newConnection());
    await old.customStatement('''
      INSERT INTO academic_terms
        (id, name, first_week_monday_local_date, total_weeks, time_zone_id,
         created_at_utc, updated_at_utc)
      VALUES ('term-autumn', '2026 秋季', '2026-09-07', 16, 'Asia/Shanghai',
              11, 12)
    ''');
    for (final (index, status) in [
      'draft',
      'committed',
      'rolledBack',
    ].indexed) {
      await old.customStatement('''
        INSERT INTO timetable_import_batches
          (id, term_id, source_image_hash, source_file_name, status,
           created_event_count, created_at_utc, updated_at_utc)
        VALUES ('batch-$index', 'term-autumn', 'sha256:$index',
                'schedule$index.png', '$status', ${index + 1},
                ${100 + index}, ${200 + index})
      ''');
    }
    await old.customStatement('''
      INSERT INTO recurrence_rules
        (id, weekdays_mask, local_start_minute, duration_minutes,
         interval_weeks, valid_from_local_date, valid_until_local_date,
         time_zone_id, created_at_utc, updated_at_utc)
      VALUES ('rule-calc', 9, 480, 45, 1, '2026-09-07', '2026-12-20',
              'Asia/Shanghai', 310, 311)
    ''');
    await old.customStatement('''
      INSERT INTO calendar_events
        (id, title, start_at_utc, end_at_utc, time_zone_id, recurrence_rule_id,
         locked, location, notes, kind, source_kind, import_batch_id,
         logical_course_id, created_at_utc, updated_at_utc)
      VALUES ('evt-calc', '高等数学(上)', 1, 2, 'Asia/Shanghai', 'rule-calc',
              1, '教一 302', '赵敏', 'fixed', 'timetableImport', 'batch-1',
              'course-calc', 410, 411)
    ''');
    await old.customStatement('''
      INSERT INTO calendar_events
        (id, title, start_at_utc, end_at_utc, time_zone_id, exception_of_id,
         locked, location, notes, kind, source_kind, import_batch_id,
         logical_course_id, created_at_utc, updated_at_utc)
      VALUES ('exc-calc', '高等数学(上)', 3, 4, 'Asia/Shanghai', 'evt-calc',
              1, '', '', 'fixed', 'timetableImport', 'batch-1',
              'course-calc', 510, 511)
    ''');
    await old.customStatement('''
      INSERT INTO tasks
        (id, title, priority, estimated_minutes, remaining_minutes,
         energy_level, split_mode, min_chunk_minutes, max_chunk_minutes,
         status, created_at_utc, updated_at_utc)
      VALUES ('task-a', '算法作业', 'medium', 50, 50, 'high', 'continuous',
              50, 50, 'open', 610, 611)
    ''');
    await old.close();

    final db = AppDatabase(
      schema.newConnection(),
      now: () => _migrationInstant,
    );
    await verifier.migrateAndValidate(db, 10);

    Future<List<String>> snapshot() async {
      final rows = <String>[];
      for (final table in [
        'academic_terms',
        'timetable_import_batches',
        'recurrence_rules',
        'calendar_events',
        'tasks',
      ]) {
        final result = await db.customSelect('SELECT * FROM $table').get();
        for (final row in result) {
          rows.add(
            '$table:${row.data.entries.map((e) => '${e.key}=${e.value}').join(',')}',
          );
        }
      }
      rows.sort();
      return rows;
    }

    final rows = await snapshot();
    expect(rows, hasLength(8), reason: '一学期 ＋ 三批次 ＋ 一规则 ＋ 一事件与一例外 ＋ 一任务');
    // **逐值原样**：v9 的 draft／committed／rolledBack 一律保留，不做猜测式回填。
    expect(
      rows
          .where((row) => row.startsWith('timetable_import_batches:'))
          .map((row) => RegExp(r'status=(\w+)').firstMatch(row)!.group(1))
          .toList()
        ..sort(),
      ['committed', 'draft', 'rolledBack'],
    );
    expect(
      rows.firstWhere(
        (row) =>
            row.startsWith('calendar_events:') && row.contains('id=evt-calc'),
      ),
      contains('import_batch_id=batch-1'),
      reason: '外键与批次归属不得因重建批次表而改变',
    );
    expect(
      rows.firstWhere((row) => row.startsWith('tasks:')),
      contains('title=算法作业'),
      reason: '迁移只动 timetable_import_batches，其它表逐值不变',
    );

    // **外键必须干净**。
    final fkViolations = await db
        .customSelect('PRAGMA foreign_key_check')
        .get();
    expect(fkViolations, isEmpty);

    // 允许写新状态，并且新状态**确实**是可识别的枚举值。
    await db.customStatement(
      "UPDATE timetable_import_batches SET status = 'partiallyDeleted' "
      "WHERE id = 'batch-1'",
    );
    final updated = await db
        .customSelect(
          "SELECT status FROM timetable_import_batches WHERE id = 'batch-1'",
        )
        .getSingle();
    expect(updated.read<String>('status'), 'partiallyDeleted');
    expect(
      TimetableImportBatchStatus.fromStorage('partiallyDeleted'),
      TimetableImportBatchStatus.partiallyDeleted,
    );

    // **非法状态仍被 CHECK 拒绝**（M2）。
    await expectLater(
      db.customStatement(
        "UPDATE timetable_import_batches SET status = 'nonsense' "
        "WHERE id = 'batch-2'",
      ),
      throwsA(isA<SqliteException>()),
    );

    await db.close();
    schema.close();
  });
}

/// v6 三张核心表的列清单，**按迁移后磁盘上 `PRAGMA table_info` 的真实顺序**。
///
/// 顺序不是随手抄的：v4 用 `ALTER TABLE ADD COLUMN` 追加了 `area_id` 与
/// `available_from_utc`，而 SQLite 把新列一律加在**末尾**，因此这两列在迁移后的库里
/// 紧跟在 `project_id` 与 `due_at_utc` 之后、而不是像 `planner_tables.dart` 里声明的那样
/// 排在末尾。写成字面量（而不是从 v6 的生成类推导）是刻意的：这条用例要回答的正是
/// "**磁盘上的表**与 v6 相比有没有变"，用同一个来源比对等于把被测对象抄一遍。
const Map<String, List<String>> _v6TableColumns = {
  'tasks': [
    'id',
    'project_id',
    'area_id',
    'title',
    'notes',
    'priority',
    'estimated_minutes',
    'remaining_minutes',
    'due_at_utc',
    'available_from_utc',
    'energy_level',
    'split_mode',
    'min_chunk_minutes',
    'max_chunk_minutes',
    'preferred_start_minute',
    'preferred_end_minute',
    'status',
    'created_at_utc',
    'updated_at_utc',
  ],
  'time_entries': [
    'id',
    'task_id',
    'started_at_utc',
    'ended_at_utc',
    'paused_minutes',
    'source',
    'recovery_state',
    'created_at_utc',
    'updated_at_utc',
  ],
  'calendar_events': [
    'id',
    'title',
    'start_at_utc',
    'end_at_utc',
    'time_zone_id',
    'recurrence_rule_id',
    'exception_of_id',
    'locked',
    'area_id',
    'project_id',
    'location',
    'notes',
    'source_kind',
    'import_batch_id',
    'logical_course_id',
    'created_at_utc',
    'updated_at_utc',
  ],
};

List<String> _v6ColumnsOf(String table) => _v6TableColumns[table]!;

v3.TasksCompanion _v3Task({required String id, String? projectId}) =>
    v3.TasksCompanion.insert(
      id: id,
      projectId: Value(projectId),
      title: '算法作业',
      priority: 'medium',
      estimatedMinutes: 50,
      remainingMinutes: 50,
      energyLevel: 'high',
      splitMode: 'continuous',
      minChunkMinutes: 50,
      maxChunkMinutes: 50,
      status: 'open',
      createdAtUtc: 1000,
      updatedAtUtc: 2000,
    );
