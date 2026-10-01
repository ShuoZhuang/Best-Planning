import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/task_dao.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

final class DriftTaskRepository implements TaskRepository {
  DriftTaskRepository(this._dao);

  final TaskDao _dao;

  @override
  Future<PlannerTask?> getById(String id) async {
    final row = await _dao.findById(id);
    return row == null ? null : _toDomain(row);
  }

  @override
  Future<void> save(PlannerTask task) => _dao.save(
    db.TasksCompanion(
      id: Value(task.id),
      projectId: Value(task.projectId),
      title: Value(task.title),
      notes: Value(task.notes),
      priority: Value(task.priority.name),
      estimatedMinutes: Value(task.estimatedMinutes),
      remainingMinutes: Value(task.remainingMinutes),
      dueAtUtc: Value(task.dueAtUtc?.microsecondsSinceEpoch),
      energyLevel: Value(task.energyLevel.name),
      splitMode: Value(task.splitMode.name),
      minChunkMinutes: Value(task.minChunkMinutes),
      maxChunkMinutes: Value(task.maxChunkMinutes),
      status: Value(task.status.name),
      createdAtUtc: Value(task.createdAtUtc.microsecondsSinceEpoch),
      updatedAtUtc: Value(task.updatedAtUtc.microsecondsSinceEpoch),
    ),
  );

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => _dao.watchOpen().map(
    (rows) => rows.map(_toDomain).toList(growable: false),
  );

  PlannerTask _toDomain(db.Task row) => PlannerTask(
    id: row.id,
    projectId: row.projectId,
    title: row.title,
    notes: row.notes,
    priority: TaskPriority.values.byName(row.priority),
    estimatedMinutes: row.estimatedMinutes,
    remainingMinutes: row.remainingMinutes,
    dueAtUtc: row.dueAtUtc == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(row.dueAtUtc!, isUtc: true),
    energyLevel: TaskEnergyLevel.values.byName(row.energyLevel),
    splitMode: TaskSplitMode.values.byName(row.splitMode),
    minChunkMinutes: row.minChunkMinutes,
    maxChunkMinutes: row.maxChunkMinutes,
    status: TaskStatus.values.byName(row.status),
    createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.createdAtUtc,
      isUtc: true,
    ),
    updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.updatedAtUtc,
      isUtc: true,
    ),
  );
}
