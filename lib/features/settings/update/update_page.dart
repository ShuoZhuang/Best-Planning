// 设置页的更新状态与诊断（规格 §11.6）。
//
// 它不再是"检查版本并打开 GitHub"的页面，而是**只读事实 + 少量动作**：
// 当前版本、最新稳定版本、上次成功检查、下载/校验状态、包验证结论、最近一次失败原因。
//
// 与左下角入口读同一个 [UpdateController] 快照——两处不可能出现不一样的结论。
import 'package:flutter/material.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/domain/update/update_baseline_status.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/features/settings/update/update_diagnostics_panel.dart';

final class UpdatePage extends StatefulWidget {
  const UpdatePage({
    super.key,
    required this.controller,
    this.openUrl,
    this.readLogs,
    this.clearLogs,
  });

  final UpdateController controller;

  /// 打开 Release 说明页。为空时不显示该入口（不给一个点了没反应的链接）。
  final Future<bool> Function(Uri url)? openUrl;

  final Future<List<String>> Function()? readLogs;
  final Future<void> Function()? clearLogs;

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

final class _UpdatePageState extends State<UpdatePage> {
  bool _releaseNotesFailed = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('更新')),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final snapshot = widget.controller.snapshot;
          final state = snapshot.state;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _StatusCard(snapshot: snapshot),
              const SizedBox(height: 12),
              _ActionsCard(
                controller: widget.controller,
                snapshot: snapshot,
                onOpenReleaseNotes: widget.openUrl == null
                    ? null
                    : () => _openReleaseNotes(context),
              ),
              const SizedBox(height: 12),
              _SettingsCard(controller: widget.controller, snapshot: snapshot),
              const SizedBox(height: 12),
              UpdateDiagnosticsPanel(
                snapshot: snapshot,
                readLogs: widget.readLogs,
                clearLogs: widget.clearLogs,
              ),
              if (_releaseNotesFailed)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '无法打开说明页面',
                    key: const Key('update-release-notes-failed'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (state.phase == UpdatePhase.failed ||
                  state.phase == UpdatePhase.temporarilyBlocked)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    state.lastFailure?.userMessage ?? '',
                    key: const Key('update-last-failure-message'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openReleaseNotes(BuildContext context) async {
    final url = widget.controller.snapshot.releaseNotesUrl;
    final open = widget.openUrl;
    if (url == null || open == null) return;
    final opened = await open(Uri.parse(url));
    if (!opened && mounted) {
      setState(() => _releaseNotesFailed = true);
    }
  }
}

final class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.snapshot});

  final UpdateSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = snapshot.state;
    final installed = snapshot.installedVersion;
    final latest = snapshot.latestVersion;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('更新状态', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            _fact(
              context,
              '当前版本',
              installed == null ? '未以安装包方式运行' : installed.value,
              key: const Key('update-current-version'),
            ),
            _fact(
              context,
              '最新稳定版本',
              latest == null ? '尚未确认' : latest.value,
              key: const Key('update-latest-version'),
            ),
            _fact(
              context,
              '上次成功检查',
              snapshot.manifest == null
                  ? '还没有成功确认过'
                  : _formatStamp(snapshot.manifest!.confirmedAtUtc.toLocal()),
              key: const Key('update-last-confirmed'),
            ),
            _fact(
              context,
              '当前阶段',
              state.phase.label,
              key: const Key('update-phase'),
            ),
            if (state.phase == UpdatePhase.downloading ||
                state.phase == UpdatePhase.downloadPaused) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: state.downloadProgress),
              const SizedBox(height: 4),
              Text(
                '已下载 ${_formatBytes(state.receivedBytes)}'
                '${state.totalBytes == null ? '' : ' / ${_formatBytes(state.totalBytes!)}'}',
                key: const Key('update-download-progress'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            _fact(
              context,
              '包验证',
              _verificationLine(state),
              key: const Key('update-package-verification'),
            ),
            if (!snapshot.safety.canInstall)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  snapshot.safety.message ?? '',
                  key: const Key('update-blocker-message'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _verificationLine(UpdateState state) => switch (state.phase) {
    UpdatePhase.ready ||
    UpdatePhase.preparingInstall ||
    UpdatePhase.waitingForExit ||
    UpdatePhase.installing ||
    UpdatePhase.launchingNewVersion ||
    UpdatePhase.waitingForHealth ||
    UpdatePhase.succeeded => '已通过大小、SHA-256 与包身份验证',
    UpdatePhase.verifying => '正在验证',
    // 诊断不能与磁盘事实矛盾：有目标包时不能说"尚无可验证的更新包"（UPD-INC-032）。
    _ when state.target != null =>
      state.baselinePreparation.phase == BaselinePhase.ready
          ? '已下载并验证，等待安装'
          : '已下载，正在准备安全回退包',
    _ => '尚无可验证的更新包',
  };

  static Widget _fact(
    BuildContext context,
    String label,
    String value, {
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 104,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: Text(value, key: key)),
      ],
    ),
  );
}

final class _ActionsCard extends StatelessWidget {
  const _ActionsCard({
    required this.controller,
    required this.snapshot,
    this.onOpenReleaseNotes,
  });

  final UpdateController controller;
  final UpdateSnapshot snapshot;
  final VoidCallback? onOpenReleaseNotes;

  @override
  Widget build(BuildContext context) {
    final state = snapshot.state;
    final baseline = state.baselinePreparation;
    final canRetry =
        state.lastFailure?.retryable == true &&
        (state.phase == UpdatePhase.failed ||
            state.phase == UpdatePhase.downloadPaused ||
            state.phase == UpdatePhase.temporarilyBlocked);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const Key('update-check-now'),
              onPressed: () => controller.checkNow(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('立即重新检查'),
            ),
            if (state.phase == UpdatePhase.updateAvailable ||
                state.phase == UpdatePhase.downloadPaused ||
                canRetry)
              OutlinedButton.icon(
                key: const Key('update-download-now'),
                onPressed: () => controller.startDownload(),
                icon: const Icon(Icons.download_rounded),
                label: Text(
                  state.phase == UpdatePhase.downloadPaused ? '重新下载' : '开始下载',
                ),
              ),
            if (baseline.phase == BaselinePhase.retryWaiting ||
                baseline.phase == BaselinePhase.failed)
              OutlinedButton.icon(
                key: const Key('update-retry-baseline'),
                onPressed: () => controller.retryBaseline(),
                icon: const Icon(Icons.shield_outlined),
                label: Text(
                  baseline.phase == BaselinePhase.failed
                      ? '重试准备安全更新'
                      : '立即重试准备',
                ),
              ),
            if (canRetry)
              OutlinedButton.icon(
                key: const Key('update-retry'),
                onPressed: () => controller.retry(),
                icon: const Icon(Icons.replay_rounded),
                label: const Text('重试'),
              ),
            if (snapshot.isReady)
              FilledButton.icon(
                key: const Key('update-install'),
                onPressed:
                    snapshot.safety.canInstall &&
                        (!snapshot.baselineRequired ||
                            baseline.phase == BaselinePhase.ready)
                    ? () => controller.install()
                    : null,
                icon: const Icon(Icons.system_update_alt_rounded),
                label: const Text('立即更新'),
              ),
            if (onOpenReleaseNotes != null && snapshot.releaseNotesUrl != null)
              TextButton.icon(
                key: const Key('update-release-notes'),
                onPressed: onOpenReleaseNotes,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('查看更新说明'),
              ),
          ],
        ),
      ),
    );
  }
}

final class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.controller, required this.snapshot});

  final UpdateController controller;
  final UpdateSnapshot snapshot;

  @override
  Widget build(BuildContext context) => Card(
    child: SwitchListTile(
      key: const Key('update-auto-toggle'),
      value: snapshot.autoUpdateEnabled,
      onChanged: controller.setAutoUpdateEnabled,
      title: const Text('自动检查并下载更新'),
      subtitle: const Text(
        '开启后会在启动约 10 秒后检查，并自动在任意网络（含计费网络）下载。'
        '关闭后只有手动检查。',
      ),
    ),
  );
}

String _formatStamp(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
