import 'dart:async';

import 'package:flutter/material.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/features/execution/execution_controller.dart';

/// 轻量执行条（规范 §7.1）：不抢焦点、不强制打开独立窗口。
///
/// 计时持续运行，只有用户明确暂停或结束才停止；界面每秒只是重绘已有时长，不写库。
final class ExecutionBar extends StatefulWidget {
  const ExecutionBar({
    required this.controller,
    required this.title,
    this.nowUtc,
    this.conflictTitle,
    super.key,
  });

  final ExecutionController controller;

  /// 任务标题由今日页从已加载的条目解析后传入；缺失时显示通用文案。
  final String title;
  final DateTime Function()? nowUtc;

  /// 运行中另一项可移动任务已到开始时间；只提示冲突，不静默替换当前会话。
  final String? conflictTitle;

  @override
  State<ExecutionBar> createState() => _ExecutionBarState();
}

final class _ExecutionBarState extends State<ExecutionBar> {
  Timer? _timer;
  String? _notifiedSessionId;
  bool _fiveMinuteNotified = false;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _ticks++;
      // 每 15 秒检查一次硬边界；暂停/结束仍由用户操作即时截断（规范 §7.4、§20.1）。
      if (_ticks % 15 == 0) {
        unawaited(widget.controller.maybePauseAtHardBoundary());
      }
      final session = widget.controller.activeSession;
      if (session != null && session.state == ExecutionSessionState.running) {
        if (_notifiedSessionId != session.sessionId) {
          _notifiedSessionId = session.sessionId;
          _fiveMinuteNotified = false;
        }
        if (!_fiveMinuteNotified &&
            _activeMicros(session) >= 5 * 60 * 1000000) {
          _fiveMinuteNotified = true;
          // 只提示一次，不每秒向屏幕阅读器播报；会话继续运行（规范 §7.3）。
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text('已做5分钟，可以继续或休息'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
      setState(() {});
    });
  }

  int _activeMicros(ExecutionSessionSnapshot session) {
    var activeMicros = session.activeMicros;
    if (session.state == ExecutionSessionState.running) {
      final now = (widget.nowUtc?.call() ?? DateTime.now()).toUtc();
      final delta = now.difference(session.lastReliableAtUtc).inMicroseconds;
      if (delta > 0) activeMicros += delta;
    }
    return activeMicros;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.controller.activeSession;
    if (session == null) return const SizedBox.shrink();
    final activeMicros = _activeMicros(session);
    final stateLabel = switch (session.state) {
      ExecutionSessionState.running => '执行中',
      ExecutionSessionState.paused => '已暂停',
      ExecutionSessionState.recoveryPending => '上次计时未确认',
      ExecutionSessionState.finished => '本次已结束',
    };
    final duration = Duration(microseconds: activeMicros);
    return Semantics(
      label: '执行条：${widget.title}，$stateLabel，已记录 ${_label(duration)}',
      container: true,
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$stateLabel · 有效投入 ${_label(duration)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (widget.conflictTitle case final conflict?)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '「$conflict」已到开始时间；本次会话不会被替换，可结束后调整。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
              if (session.state == ExecutionSessionState.running)
                TextButton(
                  onPressed: widget.controller.busy
                      ? null
                      : () => widget.controller.pause(),
                  child: const Text('暂停'),
                )
              else if (session.state != ExecutionSessionState.finished)
                TextButton(
                  onPressed: widget.controller.busy
                      ? null
                      : () => widget.controller.resume(),
                  child: Text(
                    session.state == ExecutionSessionState.recoveryPending
                        ? '继续（不补未知时间）'
                        : '继续',
                  ),
                ),
              FilledButton.tonal(
                onPressed: widget.controller.busy
                    ? null
                    : () => widget.controller.finish(),
                child: const Text('结束本次'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _label(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
