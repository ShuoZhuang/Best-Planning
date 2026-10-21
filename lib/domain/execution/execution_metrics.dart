import 'dart:collection';

import 'package:personal_planner/domain/execution/execution_models.dart';

/// 三项指标（规范 §14、§22.1）。
///
/// 统计对象是**执行实例**，不是任务条数、会话数或恢复后的片段数。固定日程、课程、
/// 保护时间、未确认预览、提前撤回和升级前无法建立基准的历史记录由调用方在装配事实时
/// 排除；本文件只负责可复算的算术。
const Duration executionStartTolerance = Duration(minutes: 5);
const Duration executionRecoveryWindow = Duration(hours: 24);

/// 一个统计输入。`firstStartUtc` 为空表示"没有可信的首次有效启动"。
final class ExecutionMetricOccurrence {
  const ExecutionMetricOccurrence({
    required this.occurrenceId,
    required this.baselineStartUtc,
    required this.firstStartUtc,
    required this.firstStartSource,
    this.withdrawnBeforeStart = false,
    this.clockAnomaly = false,
    this.lifecycleState = ExecutionLifecycleState.planned,
  });

  final String occurrenceId;
  final DateTime baselineStartUtc;

  /// 有效首次启动的时刻。零投入会话不构成启动证据；无记录时为 `null`。
  final DateTime? firstStartUtc;
  final ExecutionActivitySource? firstStartSource;

  /// 提前改期/取消：进入"提前调整"单列，不进入启动率分母（规范 §14.1）。
  final bool withdrawnBeforeStart;

  /// 系统时钟回拨/跳跃导致启动延迟不可确定。单列，不进入精确均值。
  final bool clockAnomaly;

  final ExecutionLifecycleState lifecycleState;

  bool get isEligible =>
      !withdrawnBeforeStart &&
      lifecycleState != ExecutionLifecycleState.withdrawn;
}

/// 单个指标的分母与分子。分母为 0 时 [rate] 必须为 `null`，界面显示"暂无数据"，
/// 不能伪造 0% 或 100%（规范 §14.2、EXE-37）。
final class ExecutionRateMetric {
  const ExecutionRateMetric({
    required this.numerator,
    required this.denominator,
    required this.missing,
  });

  final int numerator;
  final int denominator;
  final int missing;

  double? get rate => denominator == 0 ? null : numerator / denominator;

  bool get isEmpty => denominator == 0;
}

/// 平均启动延迟。没有可信开始时刻的实例不填 0，也不取当前时刻冒充。
final class ExecutionDelayMetric {
  const ExecutionDelayMetric({
    required this.count,
    required this.missing,
    required this.clockAnomalyCount,
    required this.totalDelayMicros,
  });

  final int count;
  final int missing;
  final int clockAnomalyCount;
  final int totalDelayMicros;

  double? get averageMinutes => count == 0
      ? null
      : totalDelayMicros / Duration.microsecondsPerMinute / count;

  bool get isEmpty => count == 0;
}

/// 延迟恢复率：观察终点固定为 `S + 24 小时`，按经过时长，不按本地一天。
final class ExecutionRecoveryMetric {
  const ExecutionRecoveryMetric({
    required this.numerator,
    required this.denominator,
    required this.pending,
    required this.laterStart,
    required this.missingStart,
  });

  final int numerator;
  final int denominator;

  /// 观察窗尚未结束的实例数量（未进入分母）。
  final int pending;

  /// 超过 24 小时才启动：记录真实投入，但不计入本次观察窗恢复。
  final int laterStart;

  /// 分母中没有可信启动记录的实例数量。
  final int missingStart;

  double? get rate => denominator == 0 ? null : numerator / denominator;

  bool get isEmpty => denominator == 0;
}

/// 一次查询的全部指标。所有字段共享同一个 `asOfUtc` 与来源过滤。
final class ExecutionMetrics {
  ExecutionMetrics({
    required this.asOfUtc,
    required this.onTime,
    required this.delay,
    required this.recovery,
    required this.totalOccurrences,
    required this.excludedWithdrawn,
    required Set<ExecutionActivitySource>? sourceFilter,
  }) : sourceFilter = sourceFilter == null
           ? null
           : Set.unmodifiable(sourceFilter);

  final DateTime asOfUtc;
  final ExecutionRateMetric onTime;
  final ExecutionDelayMetric delay;
  final ExecutionRecoveryMetric recovery;

  /// 参与本次统计的实例总数（含未记录启动）。
  final int totalOccurrences;

  /// 提前撤回数量。报告必须单列，不能悄悄删除（规范 §5.2）。
  final int excludedWithdrawn;

  /// `null` 表示视图使用全部有效来源；非空表示只使用这些来源的启动证据。
  final Set<ExecutionActivitySource>? sourceFilter;

  bool get hasAnyData =>
      onTime.denominator > 0 || recovery.denominator > 0 || delay.count > 0;
}

/// 计算三项指标。纯函数：同一份事实、同一个 `asOfUtc` 与同一过滤条件得到同一结果。
ExecutionMetrics computeExecutionMetrics({
  required Iterable<ExecutionMetricOccurrence> occurrences,
  required DateTime asOfUtc,
  Set<ExecutionActivitySource>? sourceFilter,
}) {
  if (!asOfUtc.isUtc) {
    throw ArgumentError.value(asOfUtc, 'asOfUtc', 'Must be UTC.');
  }
  final list = List<ExecutionMetricOccurrence>.of(occurrences);
  final eligible = [
    for (final occurrence in list)
      if (occurrence.isEligible) occurrence,
  ];
  final withdrawn = list.length - eligible.length;

  var onTimeDenominator = 0;
  var onTimeNumerator = 0;
  var onTimeMissing = 0;

  var delayCount = 0;
  var delayMissing = 0;
  var delayAnomaly = 0;
  var delayTotalMicros = 0;

  var recoveryDenominator = 0;
  var recoveryNumerator = 0;
  var recoveryPending = 0;
  var recoveryLater = 0;
  var recoveryMissing = 0;

  DateTime? trustedStart(ExecutionMetricOccurrence occurrence) {
    if (occurrence.clockAnomaly) return null;
    final start = occurrence.firstStartUtc;
    if (start == null) return null;
    final source = occurrence.firstStartSource;
    if (source == null) return null;
    if (sourceFilter != null && !sourceFilter.contains(source)) return null;
    return start;
  }

  for (final occurrence in eligible) {
    final baseline = occurrence.baselineStartUtc;
    final start = trustedStart(occurrence);

    // ── 准时启动率（规范 §14.2）─────────────────────────────────────────────
    // 分母要求观察容差已过去：任务刚到点尚在容差内时不能先记失败。
    if (asOfUtc.isAfter(baseline.add(executionStartTolerance))) {
      onTimeDenominator++;
      if (start == null) {
        onTimeMissing++;
      } else if (!start.isAfter(baseline.add(executionStartTolerance))) {
        // 提前开始计准时。
        onTimeNumerator++;
      }
    }

    // ── 平均启动延迟（规范 §14.3）──────────────────────────────────────────
    // 与准时率使用同一批已过容差的实例；没有可信开始的不填 0。
    if (asOfUtc.isAfter(baseline.add(executionStartTolerance))) {
      if (occurrence.clockAnomaly) {
        delayAnomaly++;
      } else if (start == null) {
        delayMissing++;
      } else {
        final delay = start.difference(baseline).inMicroseconds;
        delayTotalMicros += delay < 0 ? 0 : delay;
        delayCount++;
      }
    }

    // ── 延迟任务恢复率（规范 §14.4）─────────────────────────────────────────
    final windowEnd = baseline.add(executionRecoveryWindow);
    if (asOfUtc.isBefore(windowEnd)) {
      recoveryPending++;
      continue;
    }
    // 分母：未在 5 分钟容差内记录启动的实例（含"未记录启动"）。
    final startedWithinTolerance =
        start != null && !start.isAfter(baseline.add(executionStartTolerance));
    if (startedWithinTolerance) continue;
    recoveryDenominator++;
    if (start == null) {
      recoveryMissing++;
    } else if (start.isAfter(baseline.add(executionStartTolerance)) &&
        !start.isAfter(windowEnd)) {
      // 恰好在 S+5 分钟之外、S+24 小时整点仍在窗内（EXE-35/36 的边界口径）。
      recoveryNumerator++;
    } else if (start.isAfter(windowEnd)) {
      recoveryLater++;
    }
  }

  return ExecutionMetrics(
    asOfUtc: asOfUtc,
    onTime: ExecutionRateMetric(
      numerator: onTimeNumerator,
      denominator: onTimeDenominator,
      missing: onTimeMissing,
    ),
    delay: ExecutionDelayMetric(
      count: delayCount,
      missing: delayMissing,
      clockAnomalyCount: delayAnomaly,
      totalDelayMicros: delayTotalMicros,
    ),
    recovery: ExecutionRecoveryMetric(
      numerator: recoveryNumerator,
      denominator: recoveryDenominator,
      pending: recoveryPending,
      laterStart: recoveryLater,
      missingStart: recoveryMissing,
    ),
    totalOccurrences: list.length,
    excludedWithdrawn: withdrawn,
    sourceFilter: sourceFilter,
  );
}

/// 指标说明的稳定 id：界面按它取集中文案，不把规则散落在页面里。
enum ExecutionMetricKind { onTime, delay, recovery }

/// 指标样本数说明（规范 §14、§22.1 末段）：三个分母不一定相同，必须分别显示。
final class ExecutionMetricSample {
  const ExecutionMetricSample({
    required this.kind,
    required this.denominator,
    required this.missing,
    required this.pending,
  });

  factory ExecutionMetricSample.of(
    ExecutionMetrics metrics,
    ExecutionMetricKind kind,
  ) {
    switch (kind) {
      case ExecutionMetricKind.onTime:
        return ExecutionMetricSample(
          kind: kind,
          denominator: metrics.onTime.denominator,
          missing: metrics.onTime.missing,
          pending: 0,
        );
      case ExecutionMetricKind.delay:
        return ExecutionMetricSample(
          kind: kind,
          denominator: metrics.delay.count,
          missing: metrics.delay.missing + metrics.delay.clockAnomalyCount,
          pending: 0,
        );
      case ExecutionMetricKind.recovery:
        return ExecutionMetricSample(
          kind: kind,
          denominator: metrics.recovery.denominator,
          missing: metrics.recovery.missingStart,
          pending: metrics.recovery.pending,
        );
    }
  }

  final ExecutionMetricKind kind;
  final int denominator;
  final int missing;
  final int pending;
}

/// 来源分布：复盘必须区分实时、补记与恢复确认，不能用补记冒充实时成功。
final class ExecutionSourceBreakdown {
  ExecutionSourceBreakdown(Map<ExecutionActivitySource, int> counts)
    : counts = UnmodifiableMapView(Map.of(counts));

  final Map<ExecutionActivitySource, int> counts;

  int countOf(ExecutionActivitySource source) => counts[source] ?? 0;
}
