import 'package:flutter/material.dart';

import 'package:personal_planner/application/timetable_import_service.dart';

/// 一次撤销的实际结论（提示条与导入记录页**共用**）。
enum TimetableImportRollbackOutcome {
  /// 已经撤销，[deletedEventCount] 是删掉的系列数。
  rolledBack,

  /// 用户在看到"会连带删掉被改过的课程"之后取消了。
  cancelled,

  /// 受保护课程在确认期间又变了，或仓储失败。
  failed,
}

final class TimetableImportRollbackResult {
  const TimetableImportRollbackResult(this.outcome, this.deletedEventCount);

  final TimetableImportRollbackOutcome outcome;
  final int deletedEventCount;
}

/// **撤销课表导入的唯一入口**（计划 §2.6 最后一段／Task 10 Step 5）。
///
/// 提示条上的"撤销本次导入"与导入记录页的撤销按钮都调用它。两处**必须**共用同一套
/// 检查、同一句文案与同一个 force 集合——任何一份复制品都会在下次修改时只改一半，
/// 而这里的分支决定的正是"要不要删掉用户改过的课程"。
///
/// 它**不显示结果消息**：调用方各自决定怎么说（提示条在日历页上、历史页在自己的列表里），
/// 但"要不要问、问什么、传什么 force"三件事只有这一份实现。
Future<TimetableImportRollbackResult> confirmAndRollbackTimetableImport(
  BuildContext context,
  TimetableImportService importer,
  String batchId,
) async {
  try {
    final preview = await importer.inspectRollback(batchId);
    if (!context.mounted) {
      return const TimetableImportRollbackResult(
        TimetableImportRollbackOutcome.cancelled,
        0,
      );
    }
    var force = const <String>{};
    if (preview.protectedEventIds.isNotEmpty) {
      // **二次确认，而且说清会失去什么**：这些课程在导入之后被用户改过。
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('import-rollback-confirm'),
          title: const Text('有课程在导入后被修改过'),
          content: Text(
            '共 ${preview.protectedEventIds.length} 组课程有手动修改或新增例外。'
            '继续撤销会一并删除这些修改。',
          ),
          actions: [
            TextButton(
              key: const Key('import-rollback-cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('import-rollback-force'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('仍然撤销'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        // **未确认 ⇒ 零写入**：不传 force，仓储会拒绝，这里干脆不调用。
        return const TimetableImportRollbackResult(
          TimetableImportRollbackOutcome.cancelled,
          0,
        );
      }
      force = preview.protectedEventIds;
    }
    final result = await importer.rollback(batchId, forceEventIds: force);
    return TimetableImportRollbackResult(
      TimetableImportRollbackOutcome.rolledBack,
      result.deletedEventCount,
    );
  } on Object {
    return const TimetableImportRollbackResult(
      TimetableImportRollbackOutcome.failed,
      0,
    );
  }
}
