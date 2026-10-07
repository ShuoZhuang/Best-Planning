import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:personal_planner/domain/models/chart_kind.dart';

/// 图上的一格：分类名 + 数值（+ 可选颜色）。
@immutable
final class ChartDatum {
  const ChartDatum({required this.label, required this.value, this.color});

  final String label;
  final int value;
  final Color? color;
}

/// 统计卡片的配色。与页面既有的图表配色同源，避免同一页出现两套色。
const List<Color> chartPalette = [
  Color(0xFF3567D4),
  Color(0xFF1F9D7A),
  Color(0xFFE39035),
  Color(0xFF8B5CC7),
  Color(0xFFD6576B),
  Color(0xFF4B8A9A),
  Color(0xFF7A8B3C),
  Color(0xFF9A6B4B),
];

Color chartColorAt(int index) => chartPalette[index % chartPalette.length];

/// 按 [kind] 渲染一组分类数值。
///
/// **为什么"条形图"是手绘而不是 fl_chart**：`fl_chart` 没有横向柱状图。要硬凑只能把纵向柱状图
/// 整体 `RotatedBox` 转 90°，那样分类名也得跟着转，读起来要歪着头——而条形图真正的用处恰恰是
/// "分类名很长"的时候。手绘成一列"标签 + 按比例长度的条 + 数值"反而最短也最好读。
final class AnalyticsChart extends StatelessWidget {
  const AnalyticsChart({
    required this.kind,
    required this.data,
    this.emptyLabel = '暂无可显示的数据',
    this.height = 200,
    super.key,
  });

  final ChartKind kind;
  final List<ChartDatum> data;
  final String emptyLabel;
  final double height;

  @override
  Widget build(BuildContext context) {
    final visible = data.where((item) => item.value > 0).toList();
    if (visible.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(child: Text(emptyLabel)),
      );
    }
    return SizedBox(
      height: height,
      child: switch (kind) {
        ChartKind.pie => _pie(context, visible),
        ChartKind.bar => _bar(context, visible),
        ChartKind.horizontalBar => _horizontalBar(context, visible),
        ChartKind.line => _line(context, visible),
      },
    );
  }

  Color _colorOf(List<ChartDatum> data, int index) =>
      data[index].color ?? chartColorAt(index);

  Widget _pie(BuildContext context, List<ChartDatum> data) => PieChart(
    PieChartData(
      centerSpaceRadius: 34,
      sectionsSpace: 2,
      sections: [
        for (var index = 0; index < data.length; index++)
          PieChartSectionData(
            value: data[index].value.toDouble(),
            title: data[index].label,
            radius: 58,
            color: _colorOf(data, index),
            titleStyle: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
      ],
    ),
  );

  /// 柱状图的横轴标签：分类名长了会互相压住，因此只保留前 6 个字。
  Widget _axisLabel(BuildContext context, String label) => Text(
    label.characters.length > 6 ? '${label.characters.take(6)}…' : label,
    style: Theme.of(context).textTheme.bodySmall,
  );

  Widget _bar(BuildContext context, List<ChartDatum> data) {
    final maxValue = data.map((item) => item.value).reduce(math.max);
    return BarChart(
      BarChartData(
        minY: 0,
        maxY: math.max(1, maxValue * 1.15).toDouble(),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final index = value.round();
                if (index < 0 || index >= data.length) {
                  return const SizedBox.shrink();
                }
                return _axisLabel(context, data[index].label);
              },
            ),
          ),
        ),
        barGroups: [
          for (var index = 0; index < data.length; index++)
            BarChartGroupData(
              x: index,
              barRods: [
                BarChartRodData(
                  toY: data[index].value.toDouble(),
                  width: 28,
                  color: _colorOf(data, index),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(6),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _horizontalBar(BuildContext context, List<ChartDatum> data) {
    final maxValue = data.map((item) => item.value).reduce(math.max);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (var index = 0; index < data.length; index++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Text(
                    data[index].label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: maxValue <= 0
                            ? 0
                            : constraints.maxWidth *
                                  (data[index].value / maxValue),
                        height: 16,
                        decoration: BoxDecoration(
                          color: _colorOf(data, index),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 76,
                  child: Text(
                    '${data[index].value}',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _line(BuildContext context, List<ChartDatum> data) => LineChart(
    LineChartData(
      minX: 0,
      maxX: math.max(1, data.length - 1).toDouble(),
      minY: 0,
      maxY: math
          .max(1, data.map((item) => item.value).reduce(math.max) * 1.15)
          .toDouble(),
      gridData: FlGridData(drawVerticalLine: false),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, meta) {
              final index = value.round();
              if (index < 0 || index >= data.length) {
                return const SizedBox.shrink();
              }
              return _axisLabel(context, data[index].label);
            },
          ),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          color: chartColorAt(0),
          barWidth: 3,
          isCurved: true,
          dotData: const FlDotData(show: true),
          spots: [
            for (var index = 0; index < data.length; index++)
              FlSpot(index.toDouble(), data[index].value.toDouble()),
          ],
        ),
      ],
    ),
  );
}

/// 图表类型切换器：只列出该位置**允许**的类型。
///
/// 只允许一种类型时返回空（不显示一个只有一个选项的下拉——那种控件只会让人以为还有别的选择）。
final class ChartKindSelector extends StatelessWidget {
  const ChartKindSelector({
    required this.slot,
    required this.current,
    required this.onChanged,
    super.key,
  });

  final AnalyticsChartSlot slot;
  final ChartKind current;
  final ValueChanged<ChartKind> onChanged;

  @override
  Widget build(BuildContext context) {
    if (slot.allowedKinds.length <= 1) return const SizedBox.shrink();
    return PopupMenuButton<ChartKind>(
      key: Key('chart-kind-${slot.name}'),
      tooltip: '切换图表类型',
      initialValue: current,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final kind in slot.allowedKinds)
          PopupMenuItem<ChartKind>(value: kind, child: Text(kind.label)),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(current.label, style: Theme.of(context).textTheme.bodySmall),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    );
  }
}
