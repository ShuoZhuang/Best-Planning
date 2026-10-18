// 左下角的非模态状态卡片（规格 §11.2 / §11.3）。
//
// **它不是对话框**：没有 ModalBarrier、不抢焦点、不遮挡主界面，用户不点它就不会出现。
// 正常流程里也不存在"发现更新""下载完成"这类需要用户确认的弹窗。
import 'package:flutter/material.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/domain/update/update_state.dart';

final class UpdateStatusCard extends StatelessWidget {
  const UpdateStatusCard({
    super.key,
    required this.snapshot,
    required this.onInstall,
    required this.onRetry,
    required this.onDownload,
    required this.onCheck,
    required this.onOpenDetails,
    required this.onClose,
  });

  final UpdateSnapshot snapshot;
  final VoidCallback onInstall;
  final VoidCallback onRetry;
  final VoidCallback onDownload;
  final VoidCallback onCheck;
  final VoidCallback onOpenDetails;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final state = snapshot.state;
    final theme = Theme.of(context);
    final failure = state.lastFailure;
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
                      _title(state),
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
              if (_versionLine(snapshot) case final line?)
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
              if (_message(snapshot) case final message?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (failure != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    failure.code.code,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (snapshot.isReady && snapshot.safety.canInstall)
                    FilledButton(
                      key: const Key('update-indicator-card-install'),
                      onPressed: onInstall,
                      child: const Text('立即更新'),
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
                  if (state.phase == UpdatePhase.temporarilyBlocked)
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

  static String _title(UpdateState state) => switch (state.phase) {
    UpdatePhase.updateAvailable => '发现新版本',
    UpdatePhase.downloading => '正在下载更新',
    UpdatePhase.downloadPaused => '更新下载已暂停',
    UpdatePhase.verifying => '正在验证更新包',
    UpdatePhase.ready => '更新已就绪',
    UpdatePhase.temporarilyBlocked => '暂时无法确认更新',
    UpdatePhase.failed => '更新失败',
    _ => state.phase.label,
  };

  static String? _versionLine(UpdateSnapshot snapshot) {
    final installed = snapshot.installedVersion;
    final latest = snapshot.latestVersion;
    if (installed == null && latest == null) return null;
    final parts = <String>[];
    if (installed != null) parts.add('当前 $installed');
    if (latest != null && latest != installed) parts.add('最新 $latest');
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  static String? _message(UpdateSnapshot snapshot) {
    if (!snapshot.safety.canInstall) return snapshot.safety.message;
    if (snapshot.state.phase == UpdatePhase.failed) {
      return snapshot.state.lastFailure?.userMessage;
    }
    if (snapshot.state.phase == UpdatePhase.temporarilyBlocked) {
      return snapshot.state.lastFailure?.userMessage ??
          '更新信息暂时无法确认，稍后会自动重试。';
    }
    return null;
  }
}
