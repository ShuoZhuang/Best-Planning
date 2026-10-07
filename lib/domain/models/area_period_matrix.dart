import 'package:flutter/foundation.dart';

import 'package:personal_planner/domain/models/analytics.dart';

/// 「领域 × 周期」的计划块时长矩阵。
///
/// **为什么要有它**：原来的统计页把重心放在"计划 vs 实际"的对比上，而用户要的是**领域时间分配的
/// 横向纵向对比**——横向是"同一段时间里各领域各占多少"，纵向是"同一个领域在不同周期里的变化"。
/// 一张矩阵正好同时回答这两个问题：行是领域（横向比较），列是周期（纵向比较）。
///
/// **口径只取计划块时长**（`DomainTimeMetric.plannedMinutes`），不含实际投入：用户明确要求
/// "不需要考虑实际投入"。因此这里刻意不暴露 `actualMinutes`——免得下一个做的人顺手把它混进来。
@immutable
final class AreaPeriodMatrix {
  const AreaPeriodMatrix({required this.periods, required this.rows});

  /// 列标题，顺序与构造时给出的周期顺序一致（如 `['上周', '本周', '本月']`）。
  final List<String> periods;

  /// 每个领域一行，按合计时长**降序**（合计相同则按名称升序，保证顺序可复现）。
  final List<AreaPeriodRow> rows;

  bool get isEmpty => rows.isEmpty;

  int get totalMinutes =>
      rows.fold<int>(0, (sum, row) => sum + row.totalMinutes);

  /// 第 [column] 个周期的合计时长（用于算占比与堆叠柱的高度）。
  int periodTotal(int column) =>
      rows.fold<int>(0, (sum, row) => sum + row.minutes[column]);

  /// [minutes] 在第 [column] 个周期里占的**百分比整数**（四舍五入）。
  ///
  /// 该周期合计为 0 时返回 0，而不是抛异常或返回 NaN——空周期是正常状态（比如还没排过计划）。
  int sharePercent(int minutes, int column) {
    final total = periodTotal(column);
    if (total <= 0) return 0;
    return (minutes * 100 / total).round();
  }
}

/// 矩阵里的一行：一个领域在各周期的计划块分钟数。
@immutable
final class AreaPeriodRow {
  const AreaPeriodRow({required this.label, required this.minutes});

  /// 领域名（`DomainTimeMetric.label`）。
  final String label;

  /// 与 [AreaPeriodMatrix.periods] 逐项对齐的分钟数。
  final List<int> minutes;

  int get totalMinutes => minutes.fold<int>(0, (sum, value) => sum + value);
}

/// 由若干「周期标签 + 该周期的报告」组装矩阵。
///
/// **口径是"总占用时间" = 计划块 + 固定日程**（`DomainTimeMetric.totalMinutes`）。2026-10-06 的
/// 反馈正是"领域时间分配为什么不把固定日程统计进去"——固定日程本来就有领域，而它们此前根本没进
/// 数据集。用户库里固定日程 19 场、计划块只有 6 块，只算后者会让占比严重失真。
///
/// **仍不掺 `actualMinutes`**：用户明确要求"不需要考虑实际投入"。
///
/// 领域取各周期出现过的名字的**并集**：某个领域只在一个周期里出现过（比如上周做了、这周没做）
/// 也必须成行，否则"纵向对比"会缺掉最该看见的那一格。缺失的周期补 0。
///
/// 这个函数是纯函数，不碰数据库也不看时钟——排序、并集、补零这些规则因此可以用普通单测钉住，
/// 不必起 widget 测试。
AreaPeriodMatrix buildAreaPeriodMatrix(
  List<({String label, AnalyticsReport report})> periods,
) {
  final labels = <String>[];
  final byLabel = <String, List<int>>{};

  for (var column = 0; column < periods.length; column++) {
    final distribution = periods[column].report.domainDistribution;
    for (final metric in distribution) {
      final row = byLabel.putIfAbsent(metric.label, () {
        labels.add(metric.label);
        return List<int>.filled(periods.length, 0);
      });
      // 同一领域在同一周期里理论上只有一项；真出现多项就累加，避免静默丢数。
      row[column] += metric.totalMinutes;
    }
  }

  final rows =
      [
        for (final label in labels)
          AreaPeriodRow(label: label, minutes: byLabel[label]!),
      ]..sort((a, b) {
        final byTotal = b.totalMinutes.compareTo(a.totalMinutes);
        return byTotal != 0 ? byTotal : a.label.compareTo(b.label);
      });

  return AreaPeriodMatrix(
    periods: [for (final period in periods) period.label],
    rows: List.unmodifiable(rows),
  );
}
