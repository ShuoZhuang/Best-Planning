import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:personal_planner/data/database/daos/task_dao.dart';
import 'package:personal_planner/data/database/tables/planner_tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Areas,
    Projects,
    Tasks,
    CalendarEvents,
    RecurrenceRules,
    EnergyWindows,
    Settings,
    PlanVersions,
    ScheduleBlocks,
    TimeEntries,
    PreferenceEvidence,
    PreferenceRules,
    ChangeLog,
  ],
  daos: [TaskDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase.openDefault() : super(driftDatabase(name: 'personal_planner'));

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
