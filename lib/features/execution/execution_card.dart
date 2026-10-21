import 'package:flutter/material.dart';
import 'package:personal_planner/features/execution/execution_controller.dart';

/// 今日页的非模态执行卡（规范 §7.1、§16）。
///
/// 主操作是「开始」与「先做5分钟」；「10分钟后提醒」只在存在执行实例时出现——
/// 没有实例就没有可提醒的对象，渲染一个点了没反应的按钮比不渲染更糟。
final class ExecutionCard extends StatelessWidget {
  const ExecutionCard({
    required this.controller,
    required this.taskId,
    required this.title,
    required this.planStartUtc,
    required this.planEndUtc,
    this.formatTime,
    this.nowUtc,
    this.onAdjust,
    this.onRecord,
    this.onRecoverRemaining,
    this.onHoldToday,
    super.key,
  });

  final ExecutionController controller;
  final String taskId;
  final String title;
  final DateTime planStartUtc;
  final DateTime planEndUtc;
  final String Function(DateTime instantUtc)? formatTime;

  /// 判定"是否已到开始时间"的基准；为空取系统时间。测试注入固定时钟。
  final DateTime Function()? nowUtc;
  final VoidCallback? onAdjust;
  final VoidCallback? onRecord;

  /// 生成"安排剩余"预览；为空时不显示该入口。
  final VoidCallback? onRecoverRemaining;

  /// 安排剩余且今天不再安排该任务。
  final VoidCallback? onHoldToday;

  @override
  Widget build(BuildContext context) {
    final occurrence = controller.occurrenceForTask(taskId);
    final now = (nowUtc?.call() ?? DateTime.now()).toUtc();
    final started = !now.isBefore(planStartUtc);
    final statusLabel = started ? '尚未记录开始' : '待开始';
    final time = formatTime ?? (value) => value.toLocal().toString();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '原计划 ${time(planStartUtc)}–${time(planEndUtc)} · $statusLabel',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (started) ...[
              const SizedBox(height: 6),
              Text(
                '可以先做5分钟，之后再决定是否继续。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: controller.busy
                      ? null
                      : () => controller.startTask(
                          taskId,
                          occurrenceId: occurrence?.id,
                        ),
                  child: const Text('开始'),
                ),
                OutlinedButton(
                  onPressed: controller.busy
                      ? null
                      : () => controller.startTask(
                          taskId,
                          occurrenceId: occurrence?.id,
                          targetDurationMicros: 5 * 60 * 1000000,
                        ),
                  child: const Text('先做5分钟'),
                ),
                TextButton(
                  onPressed: occurrence == null || controller.busy
                      ? null
                      : () => controller.snooze(occurrence),
                  child: const Text('10分钟后提醒'),
                ),
                if (onAdjust != null)
                  TextButton(onPressed: onAdjust, child: const Text('调整安排')),
                if (onRecord != null)
                  TextButton(onPressed: onRecord, child: const Text('补记已做')),
                if (onRecoverRemaining != null && occurrence != null)
                  TextButton(
                    onPressed: controller.busy ? null : onRecoverRemaining,
                    child: const Text('安排剩余'),
                  ),
                if (onHoldToday != null && occurrence != null)
                  TextButton(
                    onPressed: controller.busy ? null : onHoldToday,
                    child: const Text('今天不再安排'),
                  ),
              ],
            ),
            if (controller.shortStartOffer case final offer?
                when offer.taskId == taskId)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        offer.availableMinutes <= 0
                            ? '现在只剩不到一分钟，不能开始常规会话。'
                            : '现在最多还能做 ${offer.availableMinutes} 分钟；'
                                  '仍要开始一段短会话吗？',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (offer.availableMinutes > 0)
                      TextButton(
                        onPressed: controller.busy
                            ? null
                            : () => controller.startShortSession(),
                        child: const Text('做这几分钟'),
                      ),
                    TextButton(
                      onPressed: controller.busy
                          ? null
                          : controller.clearShortStartOffer,
                      child: const Text('换个时间'),
                    ),
                  ],
                ),
              ),
            if (controller.message case final message? when message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
