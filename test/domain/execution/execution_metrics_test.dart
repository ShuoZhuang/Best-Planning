import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/execution/execution_metrics.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';

ExecutionMetricOccurrence occurrence({
  required String id,
  required DateTime baselineStartUtc,
  DateTime? firstStartUtc,
  ExecutionActivitySource? source = ExecutionActivitySource.realtime,
  bool withdrawn = false,
}) => ExecutionMetricOccurrence(
  occurrenceId: id,
  baselineStartUtc: baselineStartUtc,
  firstStartUtc: firstStartUtc,
  firstStartSource: firstStartUtc == null ? null : source,
  withdrawnBeforeStart: withdrawn,
);

void main() {
  final baseline = DateTime.utc(2026, 10, 19, 5);
  final asOf = baseline.add(const Duration(hours: 25));

  group('规范 §22.1 的固定算例', () {
    late ExecutionMetrics metrics;

    setUp(() {
      metrics = computeExecutionMetrics(
        asOfUtc: asOf,
        occurrences: [
          occurrence(
            id: 'A',
            baselineStartUtc: baseline,
            firstStartUtc: baseline.subtract(const Duration(minutes: 2)),
          ),
          occurrence(
            id: 'B',
            baselineStartUtc: baseline,
            firstStartUtc: baseline.add(const Duration(minutes: 5)),
          ),
          occurrence(
            id: 'C',
            baselineStartUtc: baseline,
            firstStartUtc: baseline.add(const Duration(minutes: 20)),
          ),
          occurrence(id: 'D', baselineStartUtc: baseline),
          occurrence(
            id: 'E',
            baselineStartUtc: baseline,
            firstStartUtc: baseline.add(const Duration(hours: 25)),
          ),
        ],
      );
    });

    test('准时率 2/5 = 40%', () {
      expect(metrics.onTime.denominator, 5);
      expect(metrics.onTime.numerator, 2);
      expect(metrics.onTime.rate, 0.4);
      expect(metrics.onTime.missing, 1);
    });

    test('平均延迟按4个有记录实例计算 = 381.25 分钟', () {
      expect(metrics.delay.count, 4);
      expect(metrics.delay.missing, 1);
      expect(metrics.delay.averageMinutes, 381.25);
    });

    test('成熟观察窗恢复率 1/3，更晚启动单列', () {
      expect(metrics.recovery.denominator, 3);
      expect(metrics.recovery.numerator, 1);
      expect(metrics.recovery.rate, closeTo(1 / 3, 1e-9));
      expect(metrics.recovery.laterStart, 1);
      expect(metrics.recovery.missingStart, 1);
      expect(metrics.recovery.pending, 0);
    });

    test('提前撤回单列，不进入分母', () {
      final withWithdrawn = computeExecutionMetrics(
        asOfUtc: asOf,
        occurrences: [
          occurrence(id: 'W', baselineStartUtc: baseline, withdrawn: true),
        ],
      );
      expect(withWithdrawn.excludedWithdrawn, 1);
      expect(withWithdrawn.onTime.denominator, 0);
    });
  });

  group('边界与空数据（规范 §14、EXE-35/36/37）', () {
    test('asOf 恰好 S+5分钟：仍在容差内，不进入准时率分母', () {
      final metrics = computeExecutionMetrics(
        asOfUtc: baseline.add(const Duration(minutes: 5)),
        occurrences: [occurrence(id: 'A', baselineStartUtc: baseline)],
      );
      expect(metrics.onTime.denominator, 0);
      expect(metrics.onTime.rate, isNull);
    });

    test('启动恰好 S+5分钟计准时；晚1微秒按迟到', () {
      final exact = computeExecutionMetrics(
        asOfUtc: asOf,
        occurrences: [
          occurrence(
            id: 'A',
            baselineStartUtc: baseline,
            firstStartUtc: baseline.add(const Duration(minutes: 5)),
          ),
        ],
      );
      expect(exact.onTime.numerator, 1);
      final late = computeExecutionMetrics(
        asOfUtc: asOf,
        occurrences: [
          occurrence(
            id: 'A',
            baselineStartUtc: baseline,
            firstStartUtc: baseline.add(
              const Duration(minutes: 5, microseconds: 1),
            ),
          ),
        ],
      );
      expect(late.onTime.numerator, 0);
    });

    test('恢复恰好 S+24小时仍在窗内；晚1微秒为更晚启动', () {
      final inWindow = computeExecutionMetrics(
        asOfUtc: baseline.add(const Duration(hours: 25)),
        occurrences: [
          occurrence(
            id: 'A',
            baselineStartUtc: baseline,
            firstStartUtc: baseline.add(const Duration(hours: 24)),
          ),
        ],
      );
      expect(inWindow.recovery.numerator, 1);
      final later = computeExecutionMetrics(
        asOfUtc: baseline.add(const Duration(hours: 26)),
        occurrences: [
          occurrence(
            id: 'A',
            baselineStartUtc: baseline,
            firstStartUtc: baseline.add(
              const Duration(hours: 24, microseconds: 1),
            ),
          ),
        ],
      );
      expect(later.recovery.numerator, 0);
      expect(later.recovery.laterStart, 1);
    });

    test('观察窗未结束时显示待观察，不进入恢复率分母', () {
      final metrics = computeExecutionMetrics(
        asOfUtc: baseline.add(const Duration(hours: 2)),
        occurrences: [
          occurrence(
            id: 'A',
            baselineStartUtc: baseline,
            firstStartUtc: baseline.add(const Duration(minutes: 20)),
          ),
        ],
      );
      expect(metrics.recovery.denominator, 0);
      expect(metrics.recovery.rate, isNull);
      expect(metrics.recovery.pending, 1);
    });

    test('零样本返回无数据而不是 0% 或 100%', () {
      final metrics = computeExecutionMetrics(
        asOfUtc: asOf,
        occurrences: const [],
      );
      expect(metrics.onTime.rate, isNull);
      expect(metrics.delay.averageMinutes, isNull);
      expect(metrics.recovery.rate, isNull);
      expect(metrics.onTime.denominator, 0);
    });
  });

  group('来源筛选（规范 §14.1、§22.1 末段）', () {
    test('仅实时视图不把补记算成按时，但实例仍在分母里', () {
      final metrics = computeExecutionMetrics(
        asOfUtc: asOf,
        sourceFilter: {ExecutionActivitySource.realtime},
        occurrences: [
          occurrence(
            id: 'manual',
            baselineStartUtc: baseline,
            firstStartUtc: baseline,
            source: ExecutionActivitySource.manual,
          ),
          occurrence(
            id: 'real',
            baselineStartUtc: baseline,
            firstStartUtc: baseline,
            source: ExecutionActivitySource.realtime,
          ),
        ],
      );
      expect(metrics.onTime.denominator, 2);
      expect(metrics.onTime.numerator, 1);
      expect(metrics.onTime.missing, 1);
      expect(metrics.delay.missing, 1);
    });

    test('时钟异常不进入精确均值，单列数量', () {
      final metrics = computeExecutionMetrics(
        asOfUtc: asOf,
        occurrences: [
          ExecutionMetricOccurrence(
            occurrenceId: 'anomaly',
            baselineStartUtc: baseline,
            firstStartUtc: baseline.add(const Duration(minutes: 30)),
            firstStartSource: ExecutionActivitySource.realtime,
            clockAnomaly: true,
          ),
        ],
      );
      expect(metrics.delay.count, 0);
      expect(metrics.delay.clockAnomalyCount, 1);
      expect(metrics.delay.averageMinutes, isNull);
    });
  });
}
