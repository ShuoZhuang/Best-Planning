// 左下角的非模态状态卡片（规格 §11.2 / §11.3；1.11.1 修复 §9）。
//
// **它不是对话框**：没有 ModalBarrier、不抢焦点、不遮挡主界面，用户不点它就不会出现。
// 正常流程里也不存在"发现更新""下载完成"这类需要用户确认的弹窗。
//
// 卡片只讲用户能采取的动作：**内部错误码只出现在诊断面板**（UPD-INC-024）。
import 'package:flutter/material.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/domain/update/update_baseline_status.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/features/shell/update_indicator_model.dart';

final class UpdateStatusCard extends StatelessWidget {
  const UpdateStatusCard({
    super.key,
    required this.snapshot,
    required this.onInstall,
    required this.onRetry,
    required this.onRetryBaseline,
    required this.onDownload,
    required this.onCheck,
    required this.onOpenDetails,
    required this.onClose,
  });

  final UpdateSnapshot snapshot;
  final VoidCallback onInstall;
  final VoidCallback onRetry;
  final VoidCallback onRetryBaseline;
  final VoidCallback onDownload;
  final VoidCallback onCheck;
  final VoidCallback onOpenDetails;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final state = snapshot.state;
    final theme = Theme.of(context);
    final model = UpdateIndicatorModel.from(snapshot);
    final baseline = state.baselinePreparation;
    return Material(
      key: const Key('update-indicator-status-card'),
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      color: theme.colorScheme.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      model.title,
                      key: const Key('update-indicator-card-title'),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    key: const Key('update-indicator-card-close'),
                    tooltip: '收起',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: onClose,
                  ),
                ],
              ),
              if (UpdateStatusCard._versionLine(snapshot) case final line?)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 6),
                  child: Text(line, style: theme.textTheme.bodySmall),
                ),
              if (state.phase == UpdatePhase.downloading)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(value: state.downloadProgress),
                ),
              if (snapshot.releaseSummary case final summary?
                  when summary.trim().isNotEmpty &&
                      state.phase == UpdatePhase.updateAvailable)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    // 纯文本渲染：不解析 Markdown/HTML，也不把链接变成可点击内容。
                    summary,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              // 用户可见的解释：**不出现内部错误码**（UPD-INC-024）。
              if (_message(snapshot, model) case final message?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    message,
                    key: const Key('update-indicator-card-message'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (state.phase == UpdatePhase.ready &&
                  (!snapshot.baselineRequired || baseline.phase.isReady) &&
                  !snapshot.safety.canInstall)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('完成其他操作后即可更新。'),
                ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (snapshot.isReady &&
                      snapshot.safety.canInstall &&
                      (!snapshot.baselineRequired || baseline.phase.isReady))
                    FilledButton(
                      key: const Key('update-indicator-card-install'),
                      onPressed: onInstall,
                      child: const Text('更新'),
                    ),
                  if (baseline.phase == BaselinePhase.retryWaiting ||
                      baseline.phase == BaselinePhase.failed)
                    OutlinedButton(
                      key: const Key('update-indicator-card-retry-baseline'),
                      onPressed: onRetryBaseline,
                      child: Text(
                        baseline.phase == BaselinePhase.failed
                            ? '重试准备'
                            : '立即重试',
                      ),
                    ),
                  if (state.phase == UpdatePhase.updateAvailable &&
                      !snapshot.autoUpdateEnabled)
                    FilledButton(
                      key: const Key('update-indicator-card-download'),
                      onPressed: onDownload,
                      child: const Text('开始下载'),
                    ),
                  if (_canRetry(snapshot))
                    OutlinedButton(
                      key: const Key('update-indicator-card-retry'),
                      onPressed: onRetry,
                      child: const Text('重试'),
                    ),
                  if (_needsRecheck(snapshot))
                    OutlinedButton(
                      key: const Key('update-indicator-card-recheck'),
                      onPressed: onCheck,
                      child: const Text('重新检查'),
                    ),
                  TextButton(
                    key: const Key('update-indicator-card-details'),
                    onPressed: onOpenDetails,
                    child: const Text('查看详情'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _canRetry(UpdateSnapshot snapshot) {
    final state = snapshot.state;
    if (state.lastFailure?.retryable != true) return false;
    return state.phase == UpdatePhase.failed ||
        state.phase == UpdatePhase.downloadPaused ||
        state.phase == UpdatePhase.temporarilyBlocked;
  }

  static bool _needsRecheck(UpdateSnapshot snapshot) {
    final state = snapshot.state;
    if (state.phase == UpdatePhase.temporarilyBlocked) return true;
    if (state.lastFailure?.code == UpdateFailureCode.packageVersionRevoked) {
      return true;
    }
    return state.lastCheckClassification ==
        UpdateCheckClassification.temporarilyUnconfirmed;
  }

  static String? _versionLine(UpdateSnapshot snapshot) {
    final installed = snapshot.installedVersion;
    final latest = snapshot.latestVersion;
    if (installed == null && latest == null) return null;
    final parts = <String>[];
    if (installed != null) parts.add('当前 $installed');
    if (latest != null && latest != installed) parts.add('最新 $latest');
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  static String? _message(UpdateSnapshot snapshot, UpdateIndicatorModel model) {
    if (!snapshot.safety.canInstall) return snapshot.safety.message;
    return model.message;
  }
}
