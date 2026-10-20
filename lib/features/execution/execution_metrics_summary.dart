import 'package:flutter/material.dart';
import 'package:personal_planner/domain/execution/execution_metrics.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';

/// 统计页的执行启动摘要（规范 §14、§16）。
///
/// **样本与缺失必须与比例一起显示**：没有记录不等于没有执行，补记也不等于实时成功。
/// 分母为 0 时显示"暂无数据"，不伪造 0% 或 100%。
final class ExecutionMetricsSummary extends StatelessWidget {
  const ExecutionMetricsSummary({
    required this.metrics,
    this.breakdown,
    super.key,
  });

  final ExecutionMetrics metrics;
  final ExecutionSourceBreakdown? breakdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onTimeRate = _rate(metrics.onTime.rate);
    final delay = metrics.delay.averageMinutes;
    final recoveryRate = _rate(metrics.recovery.rate);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('执行启动与恢复', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '按已记录的首次有效启动计算；未记录启动不等于未执行。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 28,
              runSpacing: 12,
              children: [
                _MetricTile(
                  label: '准时启动率',
                  value: onTimeRate,
                  detail:
                      '${metrics.onTime.numerator}/${metrics.onTime.denominator}'
                      ' · 未记录 ${metrics.onTime.missing}',
                ),
                _MetricTile(
                  label: '平均启动延迟',
                  value: delay == null
                      ? null
                      : '${delay.toStringAsFixed(1)} 分钟',
                  detail:
                      '${metrics.delay.count} 次有记录'
                      ' · 缺失 ${metrics.delay.missing}',
                ),
                _MetricTile(
                  label: '延迟恢复率',
                  value: recoveryRate,
                  detail:
                      '${metrics.recovery.numerator}/${metrics.recovery.denominator}'
                      ' · 待观察 ${metrics.recovery.pending}'
                      ' · 更晚 ${metrics.recovery.laterStart}',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '样本 ${metrics.totalOccurrences} 个'
              '${metrics.excludedWithdrawn > 0 ? ' · 提前调整 ${metrics.excludedWithdrawn}' : ''}'
              ' · 截止 ${_formatInstant(metrics.asOfUtc)}',
              style: theme.textTheme.bodySmall,
            ),
            if (metrics.delay.clockAnomalyCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '有 ${metrics.delay.clockAnomalyCount} 次启动受时钟异常影响，'
                  '已从延迟均值中排除。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (breakdown case final value?) ...[
              const SizedBox(height: 4),
              Text(
                '启动记录来源：实时 ${value.countOf(ExecutionActivitySource.realtime)}'
                ' · 补记 ${value.countOf(ExecutionActivitySource.manual)}'
                ' · 恢复确认 ${value.countOf(ExecutionActivitySource.recoveryConfirmed)}'
                ' · 旧记录 ${value.countOf(ExecutionActivitySource.legacyUnlinked)}',
                key: const Key('execution-metrics-source-breakdown'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (metrics.recovery.missingStart > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '恢复率分母中有 ${metrics.recovery.missingStart} 个实例没有可信启动记录；'
                  '这是"记录到的恢复比例"，不是确定未执行的结论。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String? _rate(double? value) =>
      value == null ? null : '${(value * 100).toStringAsFixed(0)}%';

  static String _formatInstant(DateTime instantUtc) {
    final local = instantUtc.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day ${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

final class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String? value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            value ?? '暂无数据',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text(detail, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
