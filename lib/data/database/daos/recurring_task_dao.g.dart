// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'recurring_task_dao.dart';

// ignore_for_file: type=lint
mixin _$RecurringTaskDaoMixin on DatabaseAccessor<AppDatabase> {
  $AreasTable get areas => attachedDatabase.areas;
  $ProjectsTable get projects => attachedDatabase.projects;
  $RecurringTaskTemplatesTable get recurringTaskTemplates =>
      attachedDatabase.recurringTaskTemplates;
  $TasksTable get tasks => attachedDatabase.tasks;
  $RecurringTaskCyclesTable get recurringTaskCycles =>
      attachedDatabase.recurringTaskCycles;
  $TimeEntriesTable get timeEntries => attachedDatabase.timeEntries;
  RecurringTaskDaoManager get managers => RecurringTaskDaoManager(this);
}

class RecurringTaskDaoManager {
  final _$RecurringTaskDaoMixin _db;
  RecurringTaskDaoManager(this._db);
  $$AreasTableTableManager get areas =>
      $$AreasTableTableManager(_db.attachedDatabase, _db.areas);
  $$ProjectsTableTableManager get projects =>
      $$ProjectsTableTableManager(_db.attachedDatabase, _db.projects);
  $$RecurringTaskTemplatesTableTableManager get recurringTaskTemplates =>
      $$RecurringTaskTemplatesTableTableManager(
        _db.attachedDatabase,
        _db.recurringTaskTemplates,
      );
  $$TasksTableTableManager get tasks =>
      $$TasksTableTableManager(_db.attachedDatabase, _db.tasks);
  $$RecurringTaskCyclesTableTableManager get recurringTaskCycles =>
      $$RecurringTaskCyclesTableTableManager(
        _db.attachedDatabase,
        _db.recurringTaskCycles,
      );
  $$TimeEntriesTableTableManager get timeEntries =>
      $$TimeEntriesTableTableManager(_db.attachedDatabase, _db.timeEntries);
}
