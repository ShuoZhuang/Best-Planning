import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:personal_planner/data/database/daos/task_dao.dart';
import 'package:personal_planner/data/database/tables/planner_tables.dart';

part 'app_database.g.dart';

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
  ],
  daos: [TaskDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase.openDefault({
    String? databasePath,
    Future<String?> Function()? tempDirectoryPath,
    DateTime Function()? now,
  }) : now = now ?? _systemNowUtc,
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

  AppDatabase.forTesting(super.e, {DateTime Function()? now})
    : now = now ?? _systemNowUtc;

  /// Opens the database against an existing [QueryExecutor]. Drift's generated
  /// migration tests use this form to point the database at a schema-managed
  /// connection, so it must stay positional and unnamed.
  AppDatabase(QueryExecutor e, {DateTime Function()? now})
    : this.forTesting(e, now: now);

  /// Instant source used to backfill timestamps added by a migration. Injectable
  /// so that migration tests can assert an exact value instead of a range.
  final DateTime Function() now;

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
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
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

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
