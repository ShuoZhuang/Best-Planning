import 'package:flutter/material.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/features/focus/focus_recovery_dialog.dart';

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

  @override
  void initState() {
    super.initState();
    _offerRecovery();
  }

  /// FR-FOCUS-02：程序异常退出时进行中的计时会留在存储里。进入专注页时应提示用户确认
  /// 实际结束时间（或选择不计入），而不是让它无声地停在"待确认"。
  ///
  /// 此前 `FocusRecoveryDialog` 全库无人引用、`recoverOpenEntry()` 也没有调用方，因此
  /// 异常退出的记录永远不会被处理（见 §13.0 的 W10）。这里不需要任何额外装配：本页
  /// 已经持有 `FocusService`。
  Future<void> _offerRecovery() async {
    final request = await widget.service.recoverOpenEntry();
    if (request == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => FocusRecoveryDialog(
        request: request,
        onConfirm: (value) async {
          // 两个回调都返回更新后的会话，必须写回 `_session`：否则用户已经回答了，
          // 界面还停在"待确认"。
          final session = await widget.service.confirmRecovery(
            endedAtUtc: value.endedAtUtc,
            actualMinutes: value.actualMinutes,
            note: value.note,
          );
          if (mounted) setState(() => _session = session);
        },
        onDiscard: () async {
          final session = await widget.service.discardRecovery();
          if (mounted) setState(() => _session = session);
        },
      ),
    );
  }

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
