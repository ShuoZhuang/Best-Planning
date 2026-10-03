import 'package:personal_planner/domain/models/workspace.dart';

/// 领域与项目的读写端口。
///
/// 领域与项目**共同**构成任务的分类体系：项目必须归属于某个领域，因此"改分类"这件事
/// 天然要同时触及两者，放进同一个端口比拆成两个互相引用的端口更简单，也让调用方没法
/// 在只拿到其中一半时写出不合法的层次关系。
///
/// 此前只有这两张表、没有任何写入路径（R2），因此 `task.projectId` 恒为空、领域统计
/// 退化成"未分类"，而 `areas.is_life` 也永远为 false——生活配额与"生活"分类因此都不
/// 生效。这个端口是这两条链路的第一个写入方。
abstract interface class WorkspaceRepository {
  /// 按 `sortOrder` 再按名称排序返回全部领域。
  Future<List<PlannerArea>> listAreas();

  /// 返回全部项目，含已归档的：归档是状态而不是删除，统计与筛选需要区分两者。
  Future<List<PlannerProject>> listProjects();

  /// 新建或整体覆盖一个领域。
  ///
  /// 实现必须保留 `createdAtUtc`（新建时写入，更新时不动），只推进 `updatedAtUtc`，
  /// 否则每次改名都会把创建时间也改掉（FR-DATA-08）。
  Future<void> saveArea(PlannerArea area);

  Future<void> saveProject(PlannerProject project);
}
