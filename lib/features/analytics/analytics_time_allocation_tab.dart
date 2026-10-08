// 页签①「时间分配」（路线图 §3.1、§11 Task 4）。
//
// 默认页签。横向看「时间分给了哪些领域」（含固定日程），纵向看上周／本周／本月的总占用。
// 纵向那一段的周期是**固定的三个**，不随顶部范围漂移——用户要的是横向纵向可对比的基准。
import 'package:flutter/material.dart';
import 'package:personal_planner/core/area_palette.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/area_period_matrix.dart';
import 'package:personal_planner/domain/models/chart_kind.dart';
import 'package:personal_planner/features/analytics/analytics_shared_cards.dart';
import 'package:personal_planner/features/analytics/chart_view.dart';

/// **① 横向：领域占比**——所选范围里各领域的时间占比。
///
/// 口径是"总占用"（计划块 + 固定日程）。用户 2026-10-06 的原话："领域时间分配为什么不把固定日程
/// 统计进去，有的固定日程不是也有领域的吗"——课表本来就有领域，此前数据集里根本没有日历事件，
/// 于是占比只统计任务计划块，把每周占大头的那部分漏掉了。
/// [onKind] 为 `null` 时**不渲染图型选择器**（§3.1 的"去掉主路径上的任意切换图表类型"）。
final class AnalyticsAreaShareSection extends StatelessWidget {
  const AnalyticsAreaShareSection({
    super.key,
    required this.report,
    required this.kind,
    this.onKind,
  });

  final AnalyticsReport report;
  final ChartKind kind;
  final ValueChanged<ChartKind>? onKind;

  @override
  Widget build(BuildContext context) {
    final distribution = [
      for (final item in report.domainDistribution)
        if (item.totalMinutes > 0) item,
    ];
    return AnalyticsSectionCard(
      cardKey: const Key('analytics-area-share'),
      slot: AnalyticsChartSlot.areaShare,
      kind: kind,
      onKind: onKind,
      title: '领域占比',
      subtitle: '横向对比：所选范围里时间分给了哪些领域（含固定日程）',
      chart: AnalyticsChart(
        kind: kind,
        emptyLabel: '所选范围里还没有已确认的计划块或固定日程。',
        data: [
          // M7（§11 退出条件："同一领域在今日、日历、统计三个页面显示同一个 ARGB 值"）。
          //
          // **这里曾经用的是 `chartColorAt(index)`**——按下标从一套自带的 `chartPalette`
          // 里取色，于是同一个领域在统计页是"第 3 个颜色"、在今日页和日历页是它自己的领域色，
          // 两处对不上。§11 明确写着"图表不得重新分配颜色"。
          //
          // 现在用 `resolveAreaColorArgb`——与今日页、日历页、领域管理页**同一个解析器**：
          // 用户选过颜色就用它，没选过就按 `sortOrder` 从调色板取默认色。因此"统计页的颜色"
          // 与别处的颜色在**定义上**就是同一个函数，不可能漂移。
          for (final item in distribution)
            ChartDatum(
              label: item.label,
              value: item.totalMinutes,
              color: Color(
                resolveAreaColorArgb(item.storedColorArgb, item.sortOrder),
              ),
            ),
        ],
      ),
      footnote: distribution
          .map(
            (item) =>
                '${item.label} ${analyticsMinutes(item.totalMinutes)}'
                '（计划 ${analyticsMinutes(item.plannedMinutes)} + '
                '固定日程 ${analyticsMinutes(item.fixedMinutes)}）',
          )
          .join('\n'),
    );
  }
}

/// **② 纵向：时间总计**——上周／本周／本月各自的总占用，下面是逐领域的矩阵表。
///
/// 图表类型可选柱状/条形/折线；**矩阵表不参与选择**（表就是表），它给出每个格子精确的分钟数与
/// 该周期内的占比，"横向占比 + 纵向总计"两件事因此在一张表里对齐。
final class AnalyticsPeriodTotalSection extends StatelessWidget {
  const AnalyticsPeriodTotalSection({
    super.key,
    required this.matrix,
    required this.kind,
    this.onKind,
  });

  final AreaPeriodMatrix matrix;
  final ChartKind kind;
  final ValueChanged<ChartKind>? onKind;

  @override
  Widget build(BuildContext context) {
    final totals = [
      for (var column = 0; column < matrix.periods.length; column++)
        ChartDatum(
          label: matrix.periods[column],
          value: matrix.periodTotal(column),
          color: chartColorAt(column),
        ),
    ];
    return Card(
      key: const Key('analytics-period-total'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnalyticsSectionHeader(
              title: '时间总计',
              subtitle: '纵向对比：上周 / 本周 / 本月的总占用（含固定日程）',
              slot: AnalyticsChartSlot.periodTotal,
              kind: kind,
              onKind: onKind,
            ),
            const SizedBox(height: 12),
            AnalyticsChart(
              kind: kind,
              height: 180,
              emptyLabel: '上周、本周与本月都还没有已确认的计划块或固定日程。',
              data: totals,
            ),
            // 判据与图表的空状态一致：**合计为 0** 时不画表。领域仍会出现在报告的分布里（只是
            // 分钟数为 0），所以 `matrix.isEmpty` 是 false——用它会画出一张全是"—"的表。
            if (matrix.totalMinutes > 0) ...[
              const SizedBox(height: 14),
              AnalyticsMatrixTable(matrix: matrix),
            ],
          ],
        ),
      ),
    );
  }
}
