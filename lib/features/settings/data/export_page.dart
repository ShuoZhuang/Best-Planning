import 'package:flutter/material.dart';
import 'package:personal_planner/application/export_service.dart';

final class ExportPage extends StatefulWidget {
  const ExportPage({required this.service, super.key});

  final ExportService service;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

final class _ExportPageState extends State<ExportPage> {
  bool _exporting = false;
  bool _lastExportWasJson = true;
  String? _summary;
  String? _error;

  Future<void> _export(bool json) async {
    setState(() {
      _lastExportWasJson = json;
      _exporting = true;
      _summary = null;
      _error = null;
    });
    try {
      final result = json
          ? await widget.service.exportJson()
          : await widget.service.exportCsv();
      if (!mounted) return;
      setState(() {
        _summary = result.status == ExportStatus.cancelled
            ? '已取消导出，没有创建文件。'
            : '已导出 ${result.recordCount} 条记录\n${result.files.join('\n')}';
      });
    } catch (error) {
      if (mounted) setState(() => _error = _messageFor(error));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('导出数据')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '保留自己的数据',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'JSON 适合完整备份和后续迁移；CSV 适合在常见表格软件中查看。'
                '两种格式都保留全部本地事实，且明确区分计划时间与实际投入。',
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _exporting ? null : () => _export(true),
                    icon: const Icon(Icons.data_object),
                    label: const Text('导出完整 JSON'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _exporting ? null : () => _export(false),
                    icon: const Icon(Icons.table_view_outlined),
                    label: const Text('导出 CSV'),
                  ),
                ],
              ),
              if (_exporting) ...[
                const SizedBox(height: 24),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('正在安全写入导出文件…'),
              ],
              if (_summary != null) ...[
                const SizedBox(height: 24),
                _MessageCard(
                  icon: Icons.check_circle_outline,
                  text: _summary!,
                  color: Theme.of(context).colorScheme.primaryContainer,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 24),
                _MessageCard(
                  icon: Icons.error_outline,
                  text: _error!,
                  color: Theme.of(context).colorScheme.errorContainer,
                  action: TextButton.icon(
                    onPressed: _exporting
                        ? null
                        : () => _export(_lastExportWasJson),
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('重新选择保存位置'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  static String _messageFor(Object error) {
    if (error is ExportWriteException) {
      return '无法写入所选位置。该文件夹可能受 Windows 保护，'
          '请改选“下载”或其他可写位置。';
    }
    return '导出没有完成。请重新选择保存位置后再试。';
  }
}

final class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.icon,
    required this.text,
    required this.color,
    this.action,
  });

  final IconData icon;
  final String text;
  final Color color;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    color: color,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(text),
                if (action != null) ...[const SizedBox(height: 8), action!],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
