// 更新诊断面板（规格 §11.6 / §14.4）。
//
// 只展示**结构化、已脱敏**的事实：错误码、阶段、尝试次数、清单摘要、包的 SHA-256 与日志尾部。
// 不展示业务标题、备注、数据库内容或任何令牌。
import 'package:flutter/material.dart';
import 'package:personal_planner/application/update/update_controller.dart';

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
            if (failure?.detail != null)
              _line(theme, '失败详情', failure!.detail!),
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
            if (manifest != null) ...[
              _line(theme, '清单元数据', manifest.manifestUrl ?? '未知'),
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
          child: SelectableText(
            value,
            style: theme.textTheme.bodySmall,
          ),
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
}
