import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/task_dao.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
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
      areaId: Value(task.areaId),
      title: Value(task.title),
      notes: Value(task.notes),
      priority: Value(task.priority.name),
      estimatedMinutes: Value(task.estimatedMinutes),
      remainingMinutes: Value(task.remainingMinutes),
      dueAtUtc: Value(task.dueAtUtc?.microsecondsSinceEpoch),
      availableFromUtc: Value(task.availableFromUtc?.microsecondsSinceEpoch),
      energyLevel: Value(task.energyLevel.name),
      splitMode: Value(task.splitMode.name),
      minChunkMinutes: Value(task.minChunkMinutes),
      maxChunkMinutes: Value(task.maxChunkMinutes),
      preferredStartMinute: Value(task.preferredWindow?.startMinute),
      preferredEndMinute: Value(task.preferredWindow?.endMinute),
      status: Value(task.status.name),
      createdAtUtc: Value(task.createdAtUtc.microsecondsSinceEpoch),
      updatedAtUtc: Value(task.updatedAtUtc.microsecondsSinceEpoch),
    ),
  );

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => _dao.watchOpen().map(
    (rows) => rows.map(_toDomain).toList(growable: false),
  );

  @override
  Stream<List<PlannerTask>> watchAllTasks() => _dao.watchAll().map(
    (rows) => rows.map(_toDomain).toList(growable: false),
  );

  PlannerTask _toDomain(db.Task row) => PlannerTask(
    id: row.id,
    projectId: row.projectId,
    areaId: row.areaId,
    title: row.title,
    notes: row.notes,
    priority: TaskPriority.values.byName(row.priority),
    estimatedMinutes: row.estimatedMinutes,
    remainingMinutes: row.remainingMinutes,
    dueAtUtc: row.dueAtUtc == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(row.dueAtUtc!, isUtc: true),
    availableFromUtc: row.availableFromUtc == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(
            row.availableFromUtc!,
            isUtc: true,
          ),
    energyLevel: TaskEnergyLevel.values.byName(row.energyLevel),
    splitMode: TaskSplitMode.values.byName(row.splitMode),
    minChunkMinutes: row.minChunkMinutes,
    maxChunkMinutes: row.maxChunkMinutes,
    preferredWindow: _preferredWindowOf(row),
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

  /// 从两列还原期望时段。任一列为空表示用户没有表达偏好。
  ///
  /// 两列都存在但组合非法时（起点不早于终点、或超出一日范围，`LocalTimeRange`
  /// 的构造校验会抛 `ArgumentError`）同样按"无偏好"处理。损坏的偏好数据不应让
  /// 任务加载或整轮排程失败：期望时段只是软约束，忽略它比拒绝加载任务更安全。
  LocalTimeRange? _preferredWindowOf(db.Task row) {
    final start = row.preferredStartMinute;
    final end = row.preferredEndMinute;
    if (start == null || end == null) return null;
    try {
      return LocalTimeRange(startMinute: start, endMinute: end);
    } on ArgumentError {
      return null;
    }
  }
}
