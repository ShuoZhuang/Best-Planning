import 'package:flutter/material.dart';
import 'package:personal_planner/application/adjustment_preview_port.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';

/// 启动恢复提示（计划 Task 9 Step 6、DFR-009/018）。
///
/// 进程被强制结束时，一次"尚未确认"的延后**不能被静默丢掉**，也不能被偷偷
/// 取消：用户必须能选择"继续查看"或"放弃"。这里只做展示与转发，业务状态仍然
/// 只由仓储与服务维护。
Future<void> showAdjustmentRecoveryPrompt(
  BuildContext context, {
  required AdjustmentPreviewPort port,
  required List<PlanAdjustment> items,
  required void Function(String adjustmentId) onOpen,
}) async {
  if (items.isEmpty) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('有一次延后还没完成'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < items.length; index++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(items[index].targetTitleSnapshot),
                subtitle: Text(_statusHint(items[index].status)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: Key('adjustment-recovery-discard-$index'),
                      onPressed: () async {
                        await port.cancel(items[index].adjustmentId);
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                      },
                      child: const Text('放弃'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: Key('adjustment-recovery-open-$index'),
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        onOpen(items[index].adjustmentId);
                      },
                      child: const Text('继续查看'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

String _statusHint(PlanAdjustmentStatus status) => switch (status) {
  PlanAdjustmentStatus.active => '尚未生成预览',
  PlanAdjustmentStatus.generating => '上次生成中断，可继续',
  PlanAdjustmentStatus.previewReady => '预览已就绪，尚未确认',
  PlanAdjustmentStatus.applying => '上次应用中断，请检查',
  PlanAdjustmentStatus.applied => '已应用',
  PlanAdjustmentStatus.cancelled => '已取消',
  PlanAdjustmentStatus.failed => '上次生成失败',
  PlanAdjustmentStatus.stale => '预览已过期',
  PlanAdjustmentStatus.expired => '已过期',
};
