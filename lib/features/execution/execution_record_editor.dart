import 'package:flutter/material.dart';

/// 一次补记的输入。只收集时长与可选备注；开始时刻由"现在减去时长"得到，
/// 与既有专注补录口径一致。
final class ExecutionRecordDraft {
  const ExecutionRecordDraft({required this.duration, required this.note});

  final Duration duration;
  final String note;
}

Future<ExecutionRecordDraft?> showExecutionRecordDialog(
  BuildContext context, {
  String initialNote = '',
}) {
  return showDialog<ExecutionRecordDraft>(
    context: context,
    builder: (context) => _ExecutionRecordDialog(initialNote: initialNote),
  );
}

final class _ExecutionRecordDialog extends StatefulWidget {
  const _ExecutionRecordDialog({required this.initialNote});

  final String initialNote;

  @override
  State<_ExecutionRecordDialog> createState() => _ExecutionRecordDialogState();
}

final class _ExecutionRecordDialogState extends State<_ExecutionRecordDialog> {
  late final TextEditingController _minutes = TextEditingController(text: '15');
  late final TextEditingController _note = TextEditingController(
    text: widget.initialNote,
  );
  String? _error;

  @override
  void dispose() {
    _minutes.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final minutes = int.tryParse(_minutes.text.trim());
    if (minutes == null || minutes <= 0 || minutes > 24 * 60) {
      setState(() => _error = '请输入 1–1440 之间的分钟数');
      return;
    }
    final note = _note.text;
    if (note.runes.length > 500) {
      setState(() => _error = '备注最多 500 个字');
      return;
    }
    Navigator.of(context).pop(
      ExecutionRecordDraft(
        duration: Duration(minutes: minutes),
        note: note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('补记已做'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '结束时间按现在计算；这条记录会标明来源是补记。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _minutes,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '实际投入（分钟）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存记录')),
      ],
    );
  }
}
