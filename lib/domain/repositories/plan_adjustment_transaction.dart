import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 应用一次调整的完整令牌（计划 Task 10 Step 2）。
///
/// **为什么需要这么多字段**：只带 `adjustmentId` 会让"旧 revision 的迟到请求"
/// 或"针对同一基线的另一份预览"都能写入；只带 `previewId` 又会让同一预览被绑到
/// 另一个基线。完整令牌与回执唯一键一起，才使"同一令牌重放返回同一计划、
/// 不同令牌竞争只有一个成功"成立（DFR-015/029/033）。
final class AdjustmentApplyCommand {
  const AdjustmentApplyCommand({
    required this.adjustmentId,
    required this.adjustmentRevision,
    required this.previewId,
    required this.previewRevision,
    required this.proposalId,
    required this.contentHash,
    required this.basePlanVersionId,
    required this.inputHash,
    required this.algorithmVersion,
  });

  final String adjustmentId;
  final int adjustmentRevision;
  final String previewId;
  final int previewRevision;
  final String proposalId;

  /// canonical 提案的 SHA-256（`ScheduleProposalCodec.sha256OfCanonical`）。
  final String contentHash;

  final String basePlanVersionId;
  final String inputHash;
  final String algorithmVersion;
}

enum AdjustmentApplyStatus {
  applied,
  alreadyApplied,
  stale,
  invalid,
  adjustmentUnfulfilled,
  concurrentModification,
  notFound,
}

final class AdjustmentApplyReceipt {
  const AdjustmentApplyReceipt({
    required this.status,
    this.planVersionId,
    this.undoReceiptId,
    this.reasonCode,
  });

  final AdjustmentApplyStatus status;
  final String? planVersionId;
  final String? undoReceiptId;
  final String? reasonCode;
}

enum PlanUndoStatus {
  undone,
  alreadyUndone,
  notFound,
  supersededByAnotherPlan,
  executionAlreadyStarted,
  concurrentModification,
}

final class PlanUndoResult {
  const PlanUndoResult({
    required this.status,
    this.planVersionId,
    this.reasonCode,
  });

  final PlanUndoStatus status;
  final String? planVersionId;
  final String? reasonCode;
}

/// 计划与调整的原子事务端口（计划 Task 10 Step 3、Task 11）。
///
/// **除本方法外不允许应用层按顺序调用"保存计划→改 preview→改 adjustment"**：
/// 那会产生"界面说失败但数据库已变化"或"计划换了、调整还停在 applying"的半状态。
abstract interface class PlanAdjustmentTransactionApplier {
  Future<AdjustmentApplyReceipt> applyAdjustmentProposal({
    required AdjustmentApplyCommand command,
    required ScheduleProposal proposal,
    required DateTime nowUtc,
  });

  /// 精确撤销一次已应用的调整；恢复通过**新计划版本**完成，不删除历史。
  Future<PlanUndoResult> undoAdjustment({
    required String adjustmentId,
    required DateTime nowUtc,
  });
}
