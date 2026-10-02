import 'package:flutter/material.dart';
import 'package:personal_planner/application/focus_service.dart';

final class FocusPage extends StatefulWidget {
  const FocusPage({
    required this.service,
    required this.taskId,
    required this.taskTitle,
    super.key,
  });

  final FocusService service;
  final String taskId;
  final String taskTitle;

  @override
  State<FocusPage> createState() => _FocusPageState();
}

final class _FocusPageState extends State<FocusPage> {
  FocusSession? _session;
  String? _error;

  Future<void> _run(Future<FocusSession> Function() action) async {
    try {
      final session = await action();
      if (mounted) setState(() => _session = session);
    } on FocusTransitionException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.taskTitle,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text('当前状态：${_session?.phase.name ?? '未开始'}'),
        Text('已专注：${_session?.activeMinutes ?? 0} 分钟'),
        if (_error != null) Text(_error!),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: () => _run(() => widget.service.start(widget.taskId)),
              child: const Text('开始'),
            ),
            OutlinedButton(
              onPressed: () => _run(widget.service.pause),
              child: const Text('暂停'),
            ),
            OutlinedButton(
              onPressed: () => _run(widget.service.resume),
              child: const Text('继续'),
            ),
            FilledButton.tonal(
              onPressed: () => _run(widget.service.finish),
              child: const Text('完成'),
            ),
          ],
        ),
      ],
    ),
  );
}
