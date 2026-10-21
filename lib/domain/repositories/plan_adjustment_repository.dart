import 'package:personal_planner/domain/models/plan_adjustment.dart';

/// 持久调整操作的仓储端口（计划 Task 2 Step 4）。
///
/// **为什么是端口而不是直接暴露 Drift DAO**：调整的 CAS、事件序列和事务边界是
/// 业务不变量（Task 10 的原子应用要在同一个 SQLite 事务里改它），应用层不能
/// 用"读-改-写"绕过 CAS 直接覆盖状态。
abstract interface class PlanAdjustmentRepository {
  /// 写入一条新调整（`active`）。同一 id 只能创建一次。
  Future<void> create(PlanAdjustment adjustment);

  Future<PlanAdjustment?> byId(String adjustmentId);

  /// 启动恢复用：过期之前仍可继续的调整，按过期时间升序。
  ///
  /// 包含 `active/generating/previewReady/applying`；`applying` 的恢复由事务证据
  /// 决定（见崩溃恢复决策表），但必须被查出来而不是永远卡死。
  Future<List<PlanAdjustment>> recoverable(DateTime nowUtc);

  /// 条件更新：只有 `expected` 三个字段全部匹配、且当前状态在 [from] 内才更新。
  ///
  /// 返回更新后的对象；零行更新返回 `null`（正常并发，不抛异常）。每次成功的
  /// CAS 都必须追加一条连续序号的 [PlanAdjustmentEvent]。
  Future<PlanAdjustment?> compareAndSet({
    required PlanAdjustmentToken expected,
    required Set<PlanAdjustmentStatus> from,
    required PlanAdjustmentStatus to,
    String? previewId,
    String? appliedPlanVersionId,
    PlanAdjustmentFailureCode? failureCode,
    bool incrementRevision = false,
  });

  /// 把仍在可取消/可过期状态、且已过期的调整标记为 `expired`。
  Future<void> expireBefore(DateTime nowUtc);

  /// 升序返回审计事件（DFR-036：每次状态转换可复算）。
  Future<List<PlanAdjustmentEvent>> events(String adjustmentId);

  /// 同一目标块上尚未终结的调整（DFR-004：两个调整不得互相覆盖）。
  ///
  /// 返回 `active/generating/previewReady/applying` 的记录；调用方据此返回
  /// `operationConflict`，而不是复用或覆盖另一个操作。
  Future<List<PlanAdjustment>> openForTargetBlock(String targetBlockId);

  /// 同一基线计划上的全部调整（撤销与审计用）。
  Future<List<PlanAdjustment>> byBasePlanVersion(String basePlanVersionId);
}
