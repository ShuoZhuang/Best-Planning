import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';

abstract interface class TaskRepository {
  Stream<List<PlannerTask>> watchOpenTasks();

  /// **全部**任务，不做任何状态过滤。
  ///
  /// 任务清单需要它：只读开放任务会让"已完成"永远是空的，而用户看不到自己做过什么、
  /// 也无法把误完成的任务改回来。`watchOpenTasks` 的语义**刻意保持不变**——今日页、
  /// 周视图与排程输入都以"未结束"为口径，加宽它会同时改掉那几处的行为。
  Stream<List<PlannerTask>> watchAllTasks();

  Future<PlannerTask?> getById(EntityId id);
  Future<void> save(PlannerTask task);
}
