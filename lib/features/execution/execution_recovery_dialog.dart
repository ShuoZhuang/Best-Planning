import 'package:flutter/material.dart';
import 'package:personal_planner/features/execution/execution_recovery_controller.dart';

/// 恢复预览对话框（规范 §9.1、§16）。
///
/// 预览**逐块列出**受影响安排与未安排分钟；没有明确确认时不使用 `allowPartial`。
/// 取消只释放本次草案，不写计划、不写 dayHold。
Future<bool?> showExecutionRecoveryDialog(
  BuildContext context, {
  required ExecutionRecoveryController controller,
  required String title,
  required String Function(DateTime instantUtc) formatTime,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ExecutionRecoveryDialog(
      controller: controller,
      title: title,
      formatTime: formatTime,
    ),
  );
}

final class _ExecutionRecoveryDialog extends StatelessWidget {
  const _ExecutionRecoveryDialog({
    required this.controller,
    required this.title,
    required this.formatTime,
  });

  final ExecutionRecoveryController controller;
  final String title;
  final String Function(DateTime instantUtc) formatTime;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final draft = controller.draft;
        final preview = draft?.preview;
        final unassigned = draft?.unassignedMinutes ?? 0;
        return AlertDialog(
          title: Text('安排剩余 · $title'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '应用后会写入一份新计划；确认前不会改变原计划。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (draft != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '从 ${formatTime(draft.notBeforeUtc)} 起寻找可用时段',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (draft.holdToday)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '本次确认后今天不再安排该任务；明天和截止时间不变。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (preview == null || preview.blocks.isEmpty)
                      const Text('没有可安排的时间块。')
                    else
                      for (final block in preview.blocks)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              Icon(
                                block.isOccurrenceTask
                                    ? Icons.play_circle_outline
                                    : Icons.swap_horiz,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '${formatTime(block.startUtc)}–${formatTime(block.endUtc)}'
                                  '${block.isOccurrenceTask ? ' · 本次安排' : ' · 受影响安排'}',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                    if (unassigned > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          '仍有 $unassigned 分钟无法安排；需要你明确选择后才能只应用可安排部分。',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (controller.message case final message?
                        when message.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          message,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ] else if (controller.message case final message?
                      when message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(message),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: controller.busy
                  ? null
                  : () async {
                      await controller.cancel();
                      if (context.mounted) Navigator.of(context).pop(false);
                    },
              child: const Text('取消预览'),
            ),
            FilledButton(
              onPressed: draft == null || controller.busy
                  ? null
                  : () async {
                      final applied = await controller.apply(
                        allowPartial: unassigned > 0
                            ? await _confirmPartial(context, unassigned)
                            : false,
                      );
                      if (applied && context.mounted) {
                        Navigator.of(context).pop(true);
                      }
                    },
              child: const Text('应用'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _confirmPartial(BuildContext context, int minutes) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('只应用可安排的部分'),
        content: Text('仍有 $minutes 分钟无法安排。应用后这些分钟仍保留为未完成工作。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('仍要应用'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}
