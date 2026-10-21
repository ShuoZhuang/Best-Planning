import 'package:personal_planner/domain/models/pending_plan_preview.dart';

/// 持久预览的通用仓储端口（计划 Task 3 Step 5）。
///
/// **为什么从 `DriftRecurringExecutionRepository` 拆出来**：周期预排只是"预览"的一种
/// 使用者。延后调整需要同一套 TTL、令牌比对、按操作 supersede 和清理语义；若继续把
/// 这些方法挂在周期仓储上，第二个使用者要么复制一套表，要么绕过令牌直接写块。
abstract interface class PendingPlanPreviewRepository {
  Future<PendingPlanPreview?> byId(String previewId);

  Future<List<PendingPlanPreviewBlock>> blocks(String previewId);

  /// 某操作的当前 active 预览；[operationId] 为空时取该种类最新一条。
  Future<PendingPreviewBundle?> active(
    PendingPreviewKind kind, {
    String? operationId,
  });

  /// 原子写入一条 active 预览：同 `(kind, operationId)` 的旧 active 变 superseded。
  ///
  /// 必须在同一事务里改旧头和写新头 + 新块，否则崩溃会留下"两套头、一套块"。
  Future<void> saveActive(PendingPreviewBundle bundle);

  Future<void> updateStatus(String previewId, PendingPreviewStatus status);

  /// 把 `expiresAtUtc <= nowUtc` 的 active 预览标为 `stale`（确认前必须重读）。
  Future<void> expireBefore(DateTime nowUtc);

  /// 清理终态预览：保留最近 [retainDays] 天、每种最多 [maxTerminalPerKind] 条。
  ///
  /// 只清终态（不碰 active/applying 的记录）；块由外键级联删除。
  Future<void> cleanup({
    required DateTime nowUtc,
    int retainDays = 30,
    int maxTerminalPerKind = 100,
  });
}
