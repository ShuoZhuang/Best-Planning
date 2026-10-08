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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: height,
          child: switch (kind) {
            ChartKind.pie => _pie(context, visible),
            ChartKind.bar => _bar(context, visible),
            ChartKind.horizontalBar => _horizontalBar(context, visible),
            ChartKind.line => _line(context, visible),
          },
        ),
        // M7（§11）：**可读的明细替代**。
        //
        // 饼图与折线图在画布上画不出可读的分类文字（见 `_pie` 的说明），柱状图的横轴标签
        // 还会因为太长被截断。因此统一在图下方给一行"颜色块 + 名称 + 数值"——
        // 名称与数值都是**正常表面上的文字**（4.5:1 可达），而且让"哪一块是什么"不再
        // 只靠颜色区分。横向条形图本身已经逐行写了名称与数值，不再重复。
        if (kind != ChartKind.horizontalBar) _chartLegend(context, visible),
      ],
    );
  }

  /// 图例：每个数据点一行「色块 + 名称 + 数值」。
  Widget _chartLegend(BuildContext context, List<ChartDatum> data) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (var index = 0; index < data.length; index++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                key: ValueKey('chart-legend-swatch-${data[index].label}'),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  // 图形色只用来标识"哪一块"，文字信息在右边。
                  color: _colorOf(data, index),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${data[index].label} ${data[index].value}',
                key: ValueKey('chart-legend-label-${data[index].label}'),
                // 用正文色：它落在正常表面上，与 M2 的正文对比度判据一致。
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
      ],
    ),
  );

  Color _colorOf(List<ChartDatum> data, int index) =>
      data[index].color ?? chartColorAt(index);

  /// 饼图。
  ///
  /// **切片上刻意不写文字**（M7，§11："图表颜色、图例、Tooltip 和表格明细不能只靠颜色区分"）。
  ///
  /// 原来的做法是把**白色标签直接画在切片上**，而按 WCAG 相对亮度实测，同一张饼的八种颜色里
  /// 只有三种能到 4.5:1（`#E39035` 上只有 2.53:1），「领域占比」用的领域调色板更糟
  /// （`#f2b35d` 上只有 **1.85:1**）。**改成深色也不成立**——逐色试过，
  /// `#3567D4` 上深色 4.04、`#8B5CC7` 上 4.45，仍不达标。
  /// 也就是说：**没有一个固定前景色能适配这八种切片色**，这不是调色能修的。
  ///
  /// 因此把名称与数值移到**图例**（见 `_chartLegend`）：文字回到正常表面上，
  /// 4.5:1 可达；同时图例让"哪一块是什么"有了文字依据，不再只靠颜色。
  ///
  /// **一个容易误判的点**：整页的 `textContrastGuideline` 检查**看不见**切片里的字——
  /// fl_chart 把它画在 `CustomPaint` 的画布上，而那条规则遍历的是语义树上的文字控件。
  /// 所以"整页通过对比度检查"并不等于"图里的字看得清"。这也正是这条退出条件要单独做的原因。
  Widget _pie(BuildContext context, List<ChartDatum> data) => PieChart(
    PieChartData(
      centerSpaceRadius: 34,
      sectionsSpace: 2,
      sections: [
        for (var index = 0; index < data.length; index++)
          PieChartSectionData(
            value: data[index].value.toDouble(),
            // **空的标题**：见上面的说明，切片上不写字。
            title: '',
            radius: 58,
            color: _colorOf(data, index),
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
