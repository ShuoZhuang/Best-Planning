import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';

abstract interface class TaskRepository {
  Stream<List<PlannerTask>> watchOpenTasks();
  Future<PlannerTask?> getById(EntityId id);
  Future<void> save(PlannerTask task);
}
