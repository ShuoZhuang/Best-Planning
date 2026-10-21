import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';
import 'package:personal_planner/domain/repositories/plan_adjustment_transaction.dart';

/// 调整预览页需要的一份只读视图：调整本身 + 它当前的持久预览。
///
/// **不含可变草稿**：页面不得自己保存"延后了多少分钟"或"原来几点"，所有事实
/// 都来自仓储（DFR-001/005）。
final class AdjustmentPreviewView {
  const AdjustmentPreviewView({required this.adjustment, this.preview});

  final PlanAdjustment adjustment;
  final PendingPreviewBundle? preview;

  bool get hasPreview => preview != null;

  bool get canConfirm =>
      adjustment.status == PlanAdjustmentStatus.previewReady &&
      preview?.preview.status == PendingPreviewStatus.active;

  bool get canCancel =>
      adjustment.status == PlanAdjustmentStatus.active ||
      adjustment.status == PlanAdjustmentStatus.generating ||
      adjustment.status == PlanAdjustmentStatus.previewReady;

  bool get canUndo => adjustment.status == PlanAdjustmentStatus.applied;
}

/// 预览页与调整服务之间的窄端口（计划 Task 9）。
///
/// 页面只依赖这四个动作，不依赖 `PlanAdjustmentService` 的具体构造：这样 widget 测试
/// 能提供一个记录调用的替身，同时生产装配仍然只有一个实现（服务本身）。
abstract interface class AdjustmentPreviewPort {
  Future<AdjustmentPreviewView?> loadPreview(String adjustmentId);

  Future<bool> cancel(String adjustmentId);

  Future<AdjustmentApplyReceipt> confirmAdjustment({
    required String adjustmentId,
    required String previewId,
  });

  Future<PlanUndoResult> undoAdjustment(String adjustmentId);
}
