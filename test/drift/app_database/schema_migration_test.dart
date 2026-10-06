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
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v3.dart' as v3;
import 'generated/schema_v4.dart' as v4;
import 'generated/schema_v5.dart' as v5;

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

  test('generated schema includes timetable-import version 6', () {
    expect(GeneratedHelper.versions.last, 6);
  });

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
    await verifier.migrateAndValidate(db, 6);

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
    await verifier.migrateAndValidate(db, 4);

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
    await verifier.migrateAndValidate(db, 4);

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
      await verifier.migrateAndValidate(db, 5);

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
      await verifier.migrateAndValidate(db, 6);

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
}

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
