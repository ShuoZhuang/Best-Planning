import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/database/tables/planner_tables.dart';

part 'task_dao.g.dart';

@DriftAccessor(tables: [Tasks])
class TaskDao extends DatabaseAccessor<AppDatabase> with _$TaskDaoMixin {
  TaskDao(super.attachedDatabase);

  Future<Task?> findById(String id) =>
      (select(tasks)..where((row) => row.id.equals(id))).getSingleOrNull();

  Stream<List<Task>> watchOpen() => (select(
    tasks,
  )..where((row) => row.status.isNotIn(['completed', 'cancelled']))).watch();

  Future<void> save(TasksCompanion task) =>
      into(tasks).insertOnConflictUpdate(task);
}
