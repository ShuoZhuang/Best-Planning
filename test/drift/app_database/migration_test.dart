// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = AppDatabase(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  // The following template shows how to write tests ensuring your migrations
  // preserve existing data.
  // Testing this can be useful for migrations that change existing columns
  // (e.g. by alterating their type or constraints). Migrations that only add
  // tables or columns typically don't need these advanced tests. For more
  // information, see https://drift.simonbinder.eu/migrations/tests/#verifying-data-integrity
  // TODO: This generated template shows how these tests could be written. Adopt
  // it to your own needs when testing migrations with data integrity.
  test('migration from v1 to v2 does not corrupt data', () async {
    // Add data to insert into the old database, and the expected rows after the
    // migration.
    // TODO: Fill these lists
    final oldAreasData = <v1.AreasData>[];
    final expectedNewAreasData = <v2.AreasData>[];

    final oldProjectsData = <v1.ProjectsData>[];
    final expectedNewProjectsData = <v2.ProjectsData>[];

    final oldTasksData = <v1.TasksData>[];
    final expectedNewTasksData = <v2.TasksData>[];

    final oldRecurrenceRulesData = <v1.RecurrenceRulesData>[];
    final expectedNewRecurrenceRulesData = <v2.RecurrenceRulesData>[];

    final oldCalendarEventsData = <v1.CalendarEventsData>[];
    final expectedNewCalendarEventsData = <v2.CalendarEventsData>[];

    final oldEnergyWindowsData = <v1.EnergyWindowsData>[];
    final expectedNewEnergyWindowsData = <v2.EnergyWindowsData>[];

    final oldSettingsData = <v1.SettingsData>[];
    final expectedNewSettingsData = <v2.SettingsData>[];

    final oldPlanVersionsData = <v1.PlanVersionsData>[];
    final expectedNewPlanVersionsData = <v2.PlanVersionsData>[];

    final oldScheduleBlocksData = <v1.ScheduleBlocksData>[];
    final expectedNewScheduleBlocksData = <v2.ScheduleBlocksData>[];

    final oldTimeEntriesData = <v1.TimeEntriesData>[];
    final expectedNewTimeEntriesData = <v2.TimeEntriesData>[];

    final oldPreferenceEvidenceData = <v1.PreferenceEvidenceData>[];
    final expectedNewPreferenceEvidenceData = <v2.PreferenceEvidenceData>[];

    final oldPreferenceRulesData = <v1.PreferenceRulesData>[];
    final expectedNewPreferenceRulesData = <v2.PreferenceRulesData>[];

    final oldChangeLogData = <v1.ChangeLogData>[];
    final expectedNewChangeLogData = <v2.ChangeLogData>[];

    await verifier.testWithDataIntegrity(
      oldVersion: 1,
      newVersion: 2,
      createOld: v1.DatabaseAtV1.new,
      createNew: v2.DatabaseAtV2.new,
      openTestedDatabase: AppDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.areas, oldAreasData);
        batch.insertAll(oldDb.projects, oldProjectsData);
        batch.insertAll(oldDb.tasks, oldTasksData);
        batch.insertAll(oldDb.recurrenceRules, oldRecurrenceRulesData);
        batch.insertAll(oldDb.calendarEvents, oldCalendarEventsData);
        batch.insertAll(oldDb.energyWindows, oldEnergyWindowsData);
        batch.insertAll(oldDb.settings, oldSettingsData);
        batch.insertAll(oldDb.planVersions, oldPlanVersionsData);
        batch.insertAll(oldDb.scheduleBlocks, oldScheduleBlocksData);
        batch.insertAll(oldDb.timeEntries, oldTimeEntriesData);
        batch.insertAll(oldDb.preferenceEvidence, oldPreferenceEvidenceData);
        batch.insertAll(oldDb.preferenceRules, oldPreferenceRulesData);
        batch.insertAll(oldDb.changeLog, oldChangeLogData);
      },
      validateItems: (newDb) async {
        expect(expectedNewAreasData, await newDb.select(newDb.areas).get());
        expect(
          expectedNewProjectsData,
          await newDb.select(newDb.projects).get(),
        );
        expect(expectedNewTasksData, await newDb.select(newDb.tasks).get());
        expect(
          expectedNewRecurrenceRulesData,
          await newDb.select(newDb.recurrenceRules).get(),
        );
        expect(
          expectedNewCalendarEventsData,
          await newDb.select(newDb.calendarEvents).get(),
        );
        expect(
          expectedNewEnergyWindowsData,
          await newDb.select(newDb.energyWindows).get(),
        );
        expect(
          expectedNewSettingsData,
          await newDb.select(newDb.settings).get(),
        );
        expect(
          expectedNewPlanVersionsData,
          await newDb.select(newDb.planVersions).get(),
        );
        expect(
          expectedNewScheduleBlocksData,
          await newDb.select(newDb.scheduleBlocks).get(),
        );
        expect(
          expectedNewTimeEntriesData,
          await newDb.select(newDb.timeEntries).get(),
        );
        expect(
          expectedNewPreferenceEvidenceData,
          await newDb.select(newDb.preferenceEvidence).get(),
        );
        expect(
          expectedNewPreferenceRulesData,
          await newDb.select(newDb.preferenceRules).get(),
        );
        expect(
          expectedNewChangeLogData,
          await newDb.select(newDb.changeLog).get(),
        );
      },
    );
  });

  test('v10 非空模板数据迁移到 v11 后仍可见', () async {
    final schema = await verifier.schemaAt(10);
    schema.rawDatabase.execute(
      'INSERT INTO recurring_task_templates ('
      'id, title, target_minutes, priority, energy_level, split_mode, '
      'min_chunk_minutes, max_chunk_minutes, pace, allowed_weekdays_mask, '
      'carry_over_unfinished, starts_on_local_date, time_zone_id, status, '
      'created_at_utc, updated_at_utc) VALUES ('
      "'template-1', '迁移前目标', 180, 'medium', 'medium', 'splittable', "
      "25, 90, 'even', 127, 0, '2026-10-05', 'Asia/Shanghai', 'active', "
      '1, 1)',
    );
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 11);
    final rows = await db
        .customSelect(
          "SELECT title FROM recurring_task_templates WHERE id = 'template-1'",
        )
        .get();
    expect(rows.single.read<String>('title'), '迁移前目标');
    await db.close();
  });
}
