// 更新诊断面板（规格 §11.6 / §14.4）。
//
// 只展示**结构化、已脱敏**的事实：错误码、阶段、尝试次数、清单摘要、包的 SHA-256 与日志尾部。
// 不展示业务标题、备注、数据库内容或任何令牌。
import 'package:flutter/material.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/domain/update/update_baseline_status.dart';
import 'package:personal_planner/domain/update/update_failure.dart';

final class UpdateDiagnosticsPanel extends StatefulWidget {
  const UpdateDiagnosticsPanel({
    super.key,
    required this.snapshot,
    this.readLogs,
    this.clearLogs,
  });

  final UpdateSnapshot snapshot;
  final Future<List<String>> Function()? readLogs;
  final Future<void> Function()? clearLogs;

  @override
  State<UpdateDiagnosticsPanel> createState() => _UpdateDiagnosticsPanelState();
}

final class _UpdateDiagnosticsPanelState extends State<UpdateDiagnosticsPanel> {
  List<String>? _logs;
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.snapshot.state;
    final failure = state.lastFailure;
    final target = state.target;
    final manifest = widget.snapshot.manifest;
    return Card(
      key: const Key('update-diagnostics'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('诊断', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _line(theme, '最近失败', failure?.code.code ?? '无'),
            if (failure != null) _line(theme, '失败解释', _explain(failure.code)),
            if (failure != null) _line(theme, '可采取的动作', _advice(failure.code)),
            if (failure?.detail != null) _line(theme, '失败详情', failure!.detail!),
            if (failure?.windowsResultCode != null)
              _line(
                theme,
                'Windows 结果码',
                '0x${failure!.windowsResultCode!.toUnsigned(32).toRadixString(16)}',
              ),
            _line(theme, '重试次数', '${state.retryAttempt}'),
            if (state.nextAttemptUtc != null)
              _line(
                theme,
                '下次自动重试',
                state.nextAttemptUtc!.toLocal().toIso8601String(),
              ),
            _line(theme, '安全回退包', _baselineLine(state.baselinePreparation)),
            if (state.baselinePreparation.nextAttemptUtc != null)
              _line(
                theme,
                '下次准备重试',
                state.baselinePreparation.nextAttemptUtc!
                    .toLocal()
                    .toIso8601String(),
              ),
            if (state.baselinePreparation.lastFailure != null)
              _line(
                theme,
                '基线失败码',
                state.baselinePreparation.lastFailure!.code.code,
              ),
            if (manifest != null) ...[
              _line(theme, '清单来源', manifest.requestKey?.label ?? '未知来源'),
              _line(theme, '解析来源', manifest.resolvedOrigin ?? '未记录'),
              _line(theme, '签名密钥', manifest.manifest.signature.keyId),
              _line(theme, '清单摘要', manifest.canonicalDigest),
            ],
            if (target != null) ...[
              _line(theme, '目标版本', target.msixVersion.value),
              _line(theme, '包 SHA-256', target.sha256),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('update-load-logs'),
                  onPressed: widget.readLogs == null ? null : _loadLogs,
                  icon: const Icon(Icons.description_outlined),
                  label: Text(_loading ? '读取中…' : '查看日志'),
                ),
                if (widget.clearLogs != null)
                  TextButton.icon(
                    key: const Key('update-clear-logs'),
                    onPressed: _clearLogs,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('清除日志'),
                  ),
              ],
            ),
            if (_logs != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _logs!.isEmpty ? '日志为空' : _logs!.join('\n'),
                  key: const Key('update-log-content'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _line(ThemeData theme, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 104,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: SelectableText(value, style: theme.textTheme.bodySmall),
        ),
      ],
    ),
  );

  Future<void> _loadLogs() async {
    setState(() => _loading = true);
    final logs = await widget.readLogs!();
    if (!mounted) return;
    setState(() {
      _logs = logs;
      _loading = false;
    });
  }

  Future<void> _clearLogs() async {
    await widget.clearLogs!();
    if (!mounted) return;
    setState(() => _logs = const []);
  }

  /// 诊断页可以显示稳定错误码，但**必须同时给出中文解释**（UPD-INC-024）。
  static String _explain(UpdateFailureCode code) => switch (code) {
    UpdateFailureCode.manifestStaleLatest =>
      '服务器返回的版本比已下载的目标旧，本次检查不会被当作"已是最新版"。',
    UpdateFailureCode.blockedRollbackNotReady => '安全回退包还没准备好，因此暂时不允许安装。',
    UpdateFailureCode.packageVersionRevoked => '发布方明确撤回了这个版本，不能安装。',
    UpdateFailureCode.stateSchemaUnsupported => '更新状态由更新版本的客户端写入，当前版本不能安全解释它。',
    UpdateFailureCode.manifestNotModifiedWithoutCache =>
      '服务器说"没有变化"，但本地没有可用于比对的缓存。',
    _ => code.message,
  };

  /// 与解释配对的下一步：普通用户不需要理解 ETag 或内部阶段名。
  static String _advice(UpdateFailureCode code) => switch (code) {
    UpdateFailureCode.manifestStaleLatest => '点击"立即重新检查"，稍后会自动重试。',
    UpdateFailureCode.blockedRollbackNotReady => '点击"重试准备安全更新"，或等待自动重试。',
    UpdateFailureCode.packageVersionRevoked => '等待发布新版本后再次检查。',
    UpdateFailureCode.stateSchemaUnsupported => '升级到最新版本客户端后重试。',
    UpdateFailureCode.manifestNotModifiedWithoutCache => '点击"立即重新检查"重新拉取清单。',
    UpdateFailureCode.networkOffline => '检查网络连接；恢复后会自动重试。',
    _ when code.retryable => '点击"重试"；系统也会按退避时间自动重试。',
    _ => '可等待新版本发布，或把诊断日志反馈给维护者。',
  };

  static String _baselineLine(BaselinePreparationState preparation) {
    final phase = switch (preparation.phase) {
      BaselinePhase.absent => '尚未建立',
      BaselinePhase.preparing => '正在下载并校验',
      BaselinePhase.ready => '已就绪',
      BaselinePhase.retryWaiting => '等待重试',
      BaselinePhase.failed => '失败（需要新版本或人工处理）',
    };
    final version = preparation.requiredForInstalledVersion;
    return version == null ? phase : '$phase（针对 $version）';
  }
}
