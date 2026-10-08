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

  /// **全部**任务，不排除任何状态（含 `completed`／`skipped`／`cancelled`）。
  ///
  /// 与 [watchOpen] 并存而不是把它加宽：`watchOpen` 的语义被今日页、周视图与排程输入
  /// 使用，"未结束"是那里的口径；任务清单要回答的却是"我有哪些任务、各自什么状态"，
  /// 其中包括已完成的与已取消的。把两者混成一个方法会让一边的语义随另一边变化。
  ///
  /// 排序按 `created_at`（录入顺序）并带 `id` 兜底：清单的"默认顺序"就是录入顺序，
  /// 而"两条任务 created_at 相同时的相对次序"必须稳定，否则同一份数据每次发出的列表
  /// 可能不同，界面会莫名其妙地跳。
  Stream<List<Task>> watchAll() =>
      (select(tasks)..orderBy([
            (row) => OrderingTerm.asc(row.createdAtUtc),
            (row) => OrderingTerm.asc(row.id),
          ]))
          .watch();

  Future<void> save(TasksCompanion task) =>
      into(tasks).insertOnConflictUpdate(task);
}
