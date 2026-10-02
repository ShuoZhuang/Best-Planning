import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/domain/models/analytics.dart';

final class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({
    required this.analytics,
    required this.nowUtc,
    super.key,
  });

  final AnalyticsQuery analytics;
  final DateTime nowUtc;

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

final class _AnalyticsPageState extends State<AnalyticsPage> {
  late AnalyticsFilter _filter;
  AnalyticsReport? _report;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final now = widget.nowUtc;
    final day = DateTime.utc(now.year, now.month, now.day);
    _filter = AnalyticsFilter(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    );
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await widget.analytics.query(_filter);
      if (!mounted) return;
      setState(() => _report = report);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectToday() {
    final now = widget.nowUtc;
    final start = DateTime.utc(now.year, now.month, now.day);
    _setRange(start, start.add(const Duration(days: 1)));
  }

  void _selectWeek() {
    final now = widget.nowUtc;
    final day = DateTime.utc(now.year, now.month, now.day);
    final start = day.subtract(Duration(days: day.weekday - 1));
    _setRange(start, start.add(const Duration(days: 7)));
  }

  void _selectMonth() {
    final now = widget.nowUtc;
    _setRange(
      DateTime.utc(now.year, now.month),
      DateTime.utc(now.year, now.month + 1),
    );
  }

  Future<void> _selectCustom() async {
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(
        start: DateTime(
          _filter.startUtc.year,
          _filter.startUtc.month,
          _filter.startUtc.day,
        ),
        end: DateTime(
          _filter.endUtc.subtract(const Duration(microseconds: 1)).year,
          _filter.endUtc.subtract(const Duration(microseconds: 1)).month,
          _filter.endUtc.subtract(const Duration(microseconds: 1)).day,
        ),
      ),
      helpText: '选择统计范围',
      cancelText: '取消',
      confirmText: '应用',
    );
    if (selected == null) return;
    _setRange(
      DateTime.utc(
        selected.start.year,
        selected.start.month,
        selected.start.day,
      ),
      DateTime.utc(selected.end.year, selected.end.month, selected.end.day + 1),
    );
  }

  void _setRange(DateTime start, DateTime end) {
    setState(() {
      _filter = AnalyticsFilter(startUtc: start, endUtc: end);
    });
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('统计与复盘')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  '看见时间去了哪里',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                const Text('计划、实际投入和推断结论分别展示，休息与娱乐同样是有价值的时间。'),
                const SizedBox(height: 18),
                _RangeControls(
                  filter: _filter,
                  onToday: _selectToday,
                  onWeek: _selectWeek,
                  onMonth: _selectMonth,
                  onCustom: _selectCustom,
                ),
                if (_loading) ...[
                  const SizedBox(height: 18),
                  const LinearProgressIndicator(),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 18),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('统计加载失败：$_error'),
                    ),
                  ),
                ],
                if (_report case final report?) ...[
                  const SizedBox(height: 22),
                  _Overview(report: report),
                  const SizedBox(height: 20),
                  _ChartGrid(report: report),
                  const SizedBox(height: 20),
                  _EvidenceLists(report: report),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

final class _RangeControls extends StatelessWidget {
  const _RangeControls({
    required this.filter,
    required this.onToday,
    required this.onWeek,
    required this.onMonth,
    required this.onCustom,
  });

  final AnalyticsFilter filter;
  final VoidCallback onToday;
  final VoidCallback onWeek;
  final VoidCallback onMonth;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    final format = DateFormat('yyyy-MM-dd');
    final inclusiveEnd = filter.endUtc.subtract(const Duration(days: 1));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(onPressed: onToday, child: const Text('今天')),
            OutlinedButton(onPressed: onWeek, child: const Text('本周')),
            OutlinedButton(onPressed: onMonth, child: const Text('本月')),
            FilledButton.tonal(onPressed: onCustom, child: const Text('自定义范围')),
            Text(
              '${format.format(filter.startUtc)} — '
              '${format.format(inclusiveEnd)}',
            ),
          ],
        ),
      ),
    );
  }
}

final class _Overview extends StatelessWidget {
  const _Overview({required this.report});
  final AnalyticsReport report;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      _MetricCard(
        icon: Icons.event_note_outlined,
        title: '计划 ${report.plannedMinutes} 分钟',
        detail: '来自已确认计划块与所选范围的交集',
      ),
      _MetricCard(
        icon: Icons.timer_outlined,
        title: '实际 ${report.actualMinutes} 分钟',
        detail: '仅统计已确认的实际记录',
      ),
      _MetricCard(
        icon: Icons.task_alt,
        title: _ratioText('完成率', report.completionRate),
        detail: report.completionRate.isAvailable
            ? '范围内到期或完成的任务'
            : '该范围暂无可计算任务',
      ),
      _MetricCard(
        icon: Icons.schedule_outlined,
        title: _ratioText('按期完成', report.onTimeCompletionRate),
        detail: '分母是已完成且设有截止时间的任务',
      ),
      _MetricCard(
        icon: Icons.self_improvement_outlined,
        title:
            '生活配额 ${report.lifeQuota.actualMinutes} / '
            '${report.lifeQuota.targetMinutes} 分钟',
        detail: '计划 ${report.lifeQuota.plannedMinutes} 分钟，实际与计划不互相替代',
      ),
    ],
  );
}

String _ratioText(String label, RatioMetric metric) => metric.isAvailable
    ? '$label ${metric.numerator} / ${metric.denominator}'
    : '$label 暂无数据';

final class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.title,
    required this.detail,
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

final class _ChartGrid extends StatelessWidget {
  const _ChartGrid({required this.report});
  final AnalyticsReport report;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth >= 880
          ? (constraints.maxWidth - 16) / 2
          : constraints.maxWidth;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          SizedBox(
            width: width,
            child: _DomainChart(report: report),
          ),
          SizedBox(
            width: width,
            child: _ComparisonChart(report: report),
          ),
          SizedBox(
            width: constraints.maxWidth,
            child: _TrendChart(report: report),
          ),
        ],
      );
    },
  );
}

final class _DomainChart extends StatelessWidget {
  const _DomainChart({required this.report});
  final AnalyticsReport report;

  @override
  Widget build(BuildContext context) {
    final data = report.domainDistribution;
    final label =
        '领域分布图：${data.map((item) => '${item.label}实际${item.actualMinutes}分钟').join('，')}';
    final total = data.fold<int>(0, (sum, item) => sum + item.actualMinutes);
    return _ChartCard(
      title: '领域分布',
      summary: data.isEmpty
          ? '所选范围暂无领域时间记录。'
          : data
                .map(
                  (item) =>
                      '${item.label}：实际 ${item.actualMinutes} 分钟，'
                      '计划 ${item.plannedMinutes} 分钟',
                )
                .join('\n'),
      chart: Semantics(
        label: label,
        excludeSemantics: true,
        child: total == 0
            ? const Center(child: Text('暂无实际投入'))
            : PieChart(
                PieChartData(
                  centerSpaceRadius: 34,
                  sectionsSpace: 2,
                  sections: [
                    for (var index = 0; index < data.length; index++)
                      PieChartSectionData(
                        value: data[index].actualMinutes.toDouble(),
                        title: data[index].label,
                        radius: 58,
                        color: _chartColors[index % _chartColors.length],
                        titleStyle: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

final class _ComparisonChart extends StatelessWidget {
  const _ComparisonChart({required this.report});
  final AnalyticsReport report;

  @override
  Widget build(BuildContext context) {
    final maxValue = math.max(report.plannedMinutes, report.actualMinutes);
    return _ChartCard(
      title: '计划 / 实际',
      summary: '计划 ${report.plannedMinutes} 分钟；实际 ${report.actualMinutes} 分钟。',
      chart: Semantics(
        label:
            '计划实际对比图：计划${report.plannedMinutes}分钟，实际${report.actualMinutes}分钟',
        excludeSemantics: true,
        child: BarChart(
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
                  getTitlesWidget: (value, meta) => Text(
                    value == 0 ? '计划' : '实际',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ),
            barGroups: [
              _bar(0, report.plannedMinutes, _chartColors[0]),
              _bar(1, report.actualMinutes, _chartColors[1]),
            ],
          ),
        ),
      ),
    );
  }

  BarChartGroupData _bar(int x, int minutes, Color color) => BarChartGroupData(
    x: x,
    barRods: [
      BarChartRodData(
        toY: minutes.toDouble(),
        width: 34,
        color: color,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
      ),
    ],
  );
}

final class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.report});
  final AnalyticsReport report;

  @override
  Widget build(BuildContext context) {
    final trend = report.trend;
    final maxValue = trend.fold<int>(
      0,
      (current, item) =>
          math.max(current, math.max(item.plannedMinutes, item.actualMinutes)),
    );
    return _ChartCard(
      title: '每日趋势',
      summary:
          '所选范围合计：计划 ${report.plannedMinutes} 分钟，实际 ${report.actualMinutes} 分钟。',
      chart: Semantics(
        label: '每日趋势图：计划${report.plannedMinutes}分钟，实际${report.actualMinutes}分钟',
        excludeSemantics: true,
        child: trend.isEmpty
            ? const Center(child: Text('暂无趋势数据'))
            : LineChart(
                LineChartData(
                  minX: 0,
                  maxX: math.max(1, trend.length - 1).toDouble(),
                  minY: 0,
                  maxY: math.max(1, maxValue * 1.15).toDouble(),
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    horizontalInterval: math.max(1, maxValue / 3).toDouble(),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: const FlTitlesData(
                    topTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  lineBarsData: [
                    _line(
                      trend,
                      (item) => item.plannedMinutes,
                      _chartColors[0],
                    ),
                    _line(trend, (item) => item.actualMinutes, _chartColors[1]),
                  ],
                ),
              ),
      ),
    );
  }

  LineChartBarData _line(
    List<DailyTimeMetric> values,
    int Function(DailyTimeMetric) select,
    Color color,
  ) => LineChartBarData(
    color: color,
    barWidth: 3,
    isCurved: true,
    dotData: const FlDotData(show: false),
    spots: [
      for (var index = 0; index < values.length; index++)
        FlSpot(index.toDouble(), select(values[index]).toDouble()),
    ],
  );
}

final class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.summary,
    required this.chart,
  });

  final String title;
  final String summary;
  final Widget chart;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          SizedBox(height: 210, child: chart),
          const SizedBox(height: 12),
          Text(summary),
        ],
      ),
    ),
  );
}

final class _EvidenceLists extends StatelessWidget {
  const _EvidenceLists({required this.report});
  final AnalyticsReport report;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('中断与调整', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Text(_rankedText('常见中断', report.commonInterruptions)),
          const SizedBox(height: 6),
          Text(_rankedText('重排原因', report.replanReasons)),
          const SizedBox(height: 6),
          Text(
            '建议行为：接受 ${report.suggestionBehavior.accepted}，'
            '修改 ${report.suggestionBehavior.modified}，'
            '拒绝 ${report.suggestionBehavior.rejected}',
          ),
        ],
      ),
    ),
  );
}

String _rankedText(String label, List<RankedMetric> values) => values.isEmpty
    ? '$label：暂无记录'
    : '$label：${values.map((item) => '${item.code} ${item.count} 次').join('，')}';

const _chartColors = [
  Color(0xFF3567D4),
  Color(0xFF1F9D7A),
  Color(0xFFE39035),
  Color(0xFF8B5CC7),
  Color(0xFFD6576B),
  Color(0xFF4B8A9A),
];
