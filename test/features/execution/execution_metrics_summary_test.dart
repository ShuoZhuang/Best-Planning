import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/execution/execution_metrics.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/features/execution/execution_metrics_summary.dart';

ExecutionMetricOccurrence occurrence({
  required String id,
  required DateTime baseline,
  DateTime? firstStart,
  ExecutionActivitySource? source = ExecutionActivitySource.realtime,
}) => ExecutionMetricOccurrence(
  occurrenceId: id,
  baselineStartUtc: baseline,
  firstStartUtc: firstStart,
  firstStartSource: firstStart == null ? null : source,
);

void main() {
  final baseline = DateTime.utc(2026, 10, 19, 5);

  Future<void> pump(
    WidgetTester tester,
    ExecutionMetrics metrics, {
    ExecutionSourceBreakdown? breakdown,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExecutionMetricsSummary(metrics: metrics, breakdown: breakdown),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('固定算例显示 40%、381.3 分钟与 1/3 恢复率', (tester) async {
    final metrics = computeExecutionMetrics(
      asOfUtc: baseline.add(const Duration(hours: 25)),
      occurrences: [
        occurrence(
          id: 'A',
          baseline: baseline,
          firstStart: baseline.subtract(const Duration(minutes: 2)),
        ),
        occurrence(
          id: 'B',
          baseline: baseline,
          firstStart: baseline.add(const Duration(minutes: 5)),
        ),
        occurrence(
          id: 'C',
          baseline: baseline,
          firstStart: baseline.add(const Duration(minutes: 20)),
        ),
        occurrence(id: 'D', baseline: baseline),
        occurrence(
          id: 'E',
          baseline: baseline,
          firstStart: baseline.add(const Duration(hours: 25)),
        ),
      ],
    );
    await pump(tester, metrics);

    expect(find.text('40%'), findsOneWidget);
    expect(find.text('381.3 分钟'), findsOneWidget);
    expect(find.text('33%'), findsOneWidget);
    expect(find.textContaining('1/3'), findsOneWidget);
    expect(find.textContaining('待观察'), findsOneWidget);
    expect(find.textContaining('提前调整'), findsNothing);
    expect(find.textContaining('未记录启动不等于未执行'), findsOneWidget);
  });

  testWidgets('零样本显示暂无数据而不是 0%', (tester) async {
    final metrics = computeExecutionMetrics(
      asOfUtc: baseline,
      occurrences: const [],
    );
    await pump(tester, metrics);
    expect(find.text('暂无数据'), findsNWidgets(3));
    expect(find.text('0%'), findsNothing);
  });

  testWidgets('样本、提前调整与缺失启动都可见', (tester) async {
    final metrics = computeExecutionMetrics(
      asOfUtc: baseline.add(const Duration(hours: 25)),
      occurrences: [
        occurrence(id: 'A', baseline: baseline),
        ExecutionMetricOccurrence(
          occurrenceId: 'W',
          baselineStartUtc: baseline,
          firstStartUtc: null,
          firstStartSource: null,
          withdrawnBeforeStart: true,
        ),
      ],
    );
    await pump(tester, metrics);
    expect(find.textContaining('提前调整 1'), findsOneWidget);
    expect(find.textContaining('没有可信启动记录'), findsOneWidget);
  });

  testWidgets('统计摘要显示启动记录来源分布', (tester) async {
    final metrics = computeExecutionMetrics(
      asOfUtc: baseline.add(const Duration(hours: 25)),
      occurrences: [occurrence(id: 'A', baseline: baseline)],
    );
    await pump(
      tester,
      metrics,
      breakdown: ExecutionSourceBreakdown({
        ExecutionActivitySource.realtime: 2,
        ExecutionActivitySource.manual: 1,
        ExecutionActivitySource.recoveryConfirmed: 1,
      }),
    );
    expect(
      find.byKey(const Key('execution-metrics-source-breakdown')),
      findsOneWidget,
    );
    expect(find.textContaining('实时 2'), findsOneWidget);
    expect(find.textContaining('补记 1'), findsOneWidget);
  });
}
