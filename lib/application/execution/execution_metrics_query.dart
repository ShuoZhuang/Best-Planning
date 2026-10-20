import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_metrics.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';

/// 三项指标的查询入口（规范 §14、§22.1）。
///
/// 所有指标使用**同一个 `asOfUtc` 与同一过滤条件**；报告按原承诺日归属，重排与更正更新
/// 原日期的统计，不把今天的迟到转移到明天隐藏。
final class ExecutionMetricsQuery {
  ExecutionMetricsQuery({required this.repository, required this.clock});

  final DriftExecutionRepository repository;
  final Clock clock;

  Future<ExecutionMetrics> metricsForWindow({
    required DateTime fromUtc,
    required DateTime toUtc,
    DateTime? asOfUtc,
    Set<ExecutionActivitySource>? sourceFilter,
  }) async {
    if (!fromUtc.isUtc || !toUtc.isUtc) {
      throw ArgumentError('Report window must be UTC.');
    }
    final occurrences = await repository.occurrencesInWindow(
      startUtc: fromUtc,
      endUtc: toUtc,
    );
    final evidence = await repository.startEvidenceFor(
      occurrences.map((occurrence) => occurrence.id),
    );
    final asOf = asOfUtc ?? clock.nowUtc();
    return computeExecutionMetrics(
      asOfUtc: asOf,
      sourceFilter: sourceFilter,
      occurrences: [
        for (final occurrence in occurrences)
          ExecutionMetricOccurrence(
            occurrenceId: occurrence.id,
            baselineStartUtc: occurrence.baselineStartUtc,
            firstStartUtc: evidence[occurrence.id]?.occurredAtUtc,
            firstStartSource: evidence[occurrence.id]?.source,
            withdrawnBeforeStart:
                occurrence.withdrawnAtUtc != null &&
                occurrence.firstStartEvidenceId == null,
            clockAnomaly: evidence[occurrence.id]?.clockAnomaly ?? false,
            lifecycleState: occurrence.lifecycleState,
          ),
      ],
    );
  }

  /// 来源分布：未知、补记与实时分别计数，不能用补记冒充实时成功。
  Future<ExecutionSourceBreakdown> sourceBreakdown({
    required DateTime fromUtc,
    required DateTime toUtc,
  }) async {
    final occurrences = await repository.occurrencesInWindow(
      startUtc: fromUtc,
      endUtc: toUtc,
    );
    final evidence = await repository.startEvidenceFor(
      occurrences.map((occurrence) => occurrence.id),
    );
    final counts = <ExecutionActivitySource, int>{};
    for (final occurrence in occurrences) {
      final source = evidence[occurrence.id]?.source;
      if (source == null) continue;
      counts.update(source, (value) => value + 1, ifAbsent: () => 1);
    }
    return ExecutionSourceBreakdown(counts);
  }
}
