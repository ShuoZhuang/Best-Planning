// 统计复盘页的共享展示件（路线图 §5 的组件边界表、§11 Task 4）。
//
// 这些件原先都挤在 analytics_page.dart 里（那个文件一度超过一千四百行）。拆出来的判据是
// **谁和谁一起变**：页签卡片的外壳与标题头被四个页签共用，因此单独一个文件；只有一处用的
// 东西留在那个页签自己的文件里。
import 'package:flutter/material.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/area_period_matrix.dart';
import 'package:personal_planner/domain/models/chart_kind.dart';
import 'package:personal_planner/features/analytics/analytics_axis_policy.dart';
import 'package:personal_planner/features/analytics/chart_view.dart';

/// 统一的"标题 + 图型选择 + 图 + 脚注"卡片，避免每张各写一遍同样的骨架。
///
/// [onKind] 为 `null` 时**不渲染图型选择器**：§3.1 明确要求"去掉主路径上的任意切换图表类型"，
/// 因此页面默认传空。空着时只少一个下拉，卡片其余部分与从前完全一致。
final class AnalyticsSectionCard extends StatelessWidget {
  const AnalyticsSectionCard({
    super.key,
    required this.cardKey,
    required this.slot,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.chart,
    required this.footnote,
    this.onKind,
  });

  final Key cardKey;
  final AnalyticsChartSlot slot;
  final ChartKind kind;
  final ValueChanged<ChartKind>? onKind;
  final String title;
  final String subtitle;
  final Widget chart;
  final String footnote;

  @override
  Widget build(BuildContext context) => Card(
    key: cardKey,
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnalyticsSectionHeader(
            title: title,
            subtitle: subtitle,
            slot: slot,
            kind: kind,
            onKind: onKind,
          ),
          const SizedBox(height: 12),
          chart,
          if (footnote.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(footnote, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    ),
  );
}

/// 卡片抬头：标题、一行口径说明、右侧的图型选择器（给了 [onKind] 才有）。
final class AnalyticsSectionHeader extends StatelessWidget {
  const AnalyticsSectionHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.slot,
    required this.kind,
    this.onKind,
  });

  final String title;
  final String subtitle;
  final AnalyticsChartSlot slot;
  final ChartKind kind;
  final ValueChanged<ChartKind>? onKind;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      if (onKind case final onKind?) ...[
        const SizedBox(width: 12),
        ChartKindSelector(slot: slot, current: kind, onChanged: onKind),
      ],
    ],
  );
}

/// 分钟数 → "X 小时 Y 分钟"。
///
/// **转发到 `formatAnalyticsMinutes`**，不再自己再写一份：模块里同时存在两个一模一样的格式化器
/// 时，早晚会有一处被改（比如加上"1 天 3 小时"）而另一处没跟上，于是同一个数字在两个页签里
/// 长得不一样。§7.1 第 3 条要的是**一处实现**。
String analyticsMinutes(int value) => formatAnalyticsMinutes(value);

/// 本地分钟数 → `HH:mm`（1440 记作 `24:00`）。
String analyticsClockText(int? minute) {
  if (minute == null) return '—';
  final hour = minute ~/ 60;
  final rest = minute % 60;
  return '${hour.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
}

String analyticsRatioText(String label, RatioMetric metric) =>
    metric.isAvailable
    ? '$label ${metric.numerator} / ${metric.denominator}'
    : '$label 暂无数据';

final class AnalyticsMetricCard extends StatelessWidget {
  const AnalyticsMetricCard({
    required this.icon,
    required this.title,
    required this.detail,
    super.key,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 310,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 矩阵表：行是领域（按合计降序），列是周期，格子是"时长 + 该周期内的占比"。
///
/// **时长一律走 `analyticsMinutes`**（§7.1 第 3 条：不显示裸分钟）。这张表此前写的是
/// `'${minutes} 分钟'`，于是"学业 660 分钟"这样的四位数会出现在表里——用户没法心算那是多久。
/// 占比仍然保留，因为表的价值就在"这个领域在这段周期里占了多大一块"。
final class AnalyticsMatrixTable extends StatelessWidget {
  const AnalyticsMatrixTable({super.key, required this.matrix});
  final AreaPeriodMatrix matrix;

  @override
  Widget build(BuildContext context) {
    final headerStyle = Theme.of(context).textTheme.labelLarge;
    final bodyStyle = Theme.of(context).textTheme.bodyMedium;
    final mutedStyle = Theme.of(context).textTheme.bodySmall;
    return Table(
      key: const Key('analytics-area-period-table'),
      columnWidths: {
        0: const FlexColumnWidth(1.6),
        for (var column = 0; column < matrix.periods.length; column++)
          column + 1: const FlexColumnWidth(),
        matrix.periods.length + 1: const FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            _cell('领域', headerStyle),
            for (final period in matrix.periods) _cell(period, headerStyle),
            _cell('合计', headerStyle),
          ],
        ),
        for (var index = 0; index < matrix.rows.length; index++)
          TableRow(
            children: [
              _cell(
                matrix.rows[index].label,
                bodyStyle,
                key: Key('area-period-row-${matrix.rows[index].label}'),
              ),
              for (var column = 0; column < matrix.periods.length; column++)
                _cell(
                  matrix.rows[index].minutes[column] == 0
                      ? '—'
                      : '${analyticsMinutes(matrix.rows[index].minutes[column])}'
                            '（${matrix.sharePercent(matrix.rows[index].minutes[column], column)}%）',
                  matrix.rows[index].minutes[column] == 0
                      ? mutedStyle
                      : bodyStyle,
                ),
              _cell(
                analyticsMinutes(matrix.rows[index].totalMinutes),
                bodyStyle,
              ),
            ],
          ),
        TableRow(
          children: [
            _cell('合计', headerStyle),
            for (var column = 0; column < matrix.periods.length; column++)
              _cell(analyticsMinutes(matrix.periodTotal(column)), headerStyle),
            _cell(analyticsMinutes(matrix.totalMinutes), headerStyle),
          ],
        ),
      ],
    );
  }

  Widget _cell(String text, TextStyle? style, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
    child: Text(text, style: style),
  );
}
