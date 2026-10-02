import 'package:flutter/material.dart';
import 'package:personal_planner/application/focus_service.dart';

final class FocusRecoveryDialog extends StatefulWidget {
  const FocusRecoveryDialog({
    required this.request,
    required this.onConfirm,
    required this.onDiscard,
    super.key,
  });

  final FocusRecoveryRequest request;
  final Future<void> Function(FocusRecoveryConfirmation value) onConfirm;
  final Future<void> Function() onDiscard;

  @override
  State<FocusRecoveryDialog> createState() => _FocusRecoveryDialogState();
}

final class _FocusRecoveryDialogState extends State<FocusRecoveryDialog> {
  late final TextEditingController _endTime;
  late final TextEditingController _minutes;
  final _note = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    final end = widget.request.suggestedEndUtc;
    _endTime = TextEditingController(text: _time(end));
    _minutes = TextEditingController(
      text: widget.request.session.activeMinutes.toString(),
    );
  }

  @override
  void dispose() {
    _endTime.dispose();
    _minutes.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final minuteOfDay = _parseTime(_endTime.text);
    final actualMinutes = int.tryParse(_minutes.text.trim());
    if (minuteOfDay == null || actualMinutes == null || actualMinutes <= 0) {
      setState(() => _error = '请填写有效的结束时间和实际时长');
      return;
    }
    final date = widget.request.suggestedEndUtc;
    await widget.onConfirm(
      FocusRecoveryConfirmation(
        endedAtUtc: DateTime.utc(
          date.year,
          date.month,
          date.day,
          minuteOfDay ~/ 60,
          minuteOfDay % 60,
        ),
        actualMinutes: actualMinutes,
        note: _note.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('需要确认本次专注', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('程序上次退出时计时仍在运行，未确认前不计入统计。'),
          if (widget.request.wallClockDriftDetected)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('系统时间可能发生跳变，请核对真实结束时间。'),
            ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('recovery-end-time'),
            controller: _endTime,
            decoration: const InputDecoration(labelText: '真实结束时间'),
          ),
          TextField(
            key: const Key('recovery-actual-minutes'),
            controller: _minutes,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '实际专注时长（分钟）'),
          ),
          TextField(
            key: const Key('recovery-note'),
            controller: _note,
            decoration: const InputDecoration(labelText: '完成备注（可选）'),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: widget.onDiscard,
                child: const Text('不计入本次'),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _confirm, child: const Text('确认并计入统计')),
            ],
          ),
        ],
      ),
    ),
  );
}

String _time(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

int? _parseTime(String input) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(input.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}
