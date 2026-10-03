import 'package:personal_planner/domain/models/tag.dart';

/// 标签的读写端口。
///
/// `tags` 与 `task_tags` 两张表以及迁移测试早已存在（schema v2），但**没有任何读取方或
/// 写入方**：`AnalyticsDao` 组装 `AnalyticsTaskFact` 时从不填 `tags`，于是
/// `AnalyticsFilter.tags` 一旦非空，`_matches` 里的 `containsAll` 对所有任务都为假，
/// 标签筛选会静默返回空集而不是命中集合（见 §13.0 的 R1）。这个端口是标签链路的第一环。
///
/// 已知限制：`task_tags.task_id` 的外键没有 `ON DELETE` 动作，而全库目前**没有删除任务的
/// 路径**（`TaskRepository` 只有 getById/save/watchOpenTasks），"永久清除"是直接删除数据库
/// 文件，因此当前不可达。将来若新增删除任务的入口，必须先删关联（或在一次需要 schema
/// 迁移的改动里给外键加级联），否则开启了 `PRAGMA foreign_keys` 的连接会直接报约束错误。
abstract interface class TagRepository {
  /// 按名称排序返回全部标签。
  Future<List<PlannerTag>> listTags();

  /// 新建或整体覆盖一个标签。
  ///
  /// 实现必须保留 `createdAtUtc`（新建时写入，更新时不动），只推进 `updatedAtUtc`，
  /// 与领域／项目同口径（FR-DATA-08）。
  Future<void> saveTag(PlannerTag tag);

  /// 某个任务当前的标签，按名称排序。
  Future<List<PlannerTag>> tagsForTask(String taskId);

  /// 建立"任务—标签"关联。
  ///
  /// 已是关联时不得报错、也不得改写已有创建时间：重复打同一个标签是正常操作。
  Future<void> linkTag(String taskId, String tagId, DateTime linkedAtUtc);

  /// 删除关联；本来就没有这条关联时不报错。
  Future<void> unlinkTag(String taskId, String tagId);
}
