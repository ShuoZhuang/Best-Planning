// 页签③「休息与作息」（路线图 §3.1、§11 Task 4）。
//
// 三项**全部只看计划侧数据**：用户明确要求把「实际投入」从统计里拿掉，而「有没有好好休息」
// 改看自己的规划——把任务排进睡眠、天天在不同时刻开工，就是规划层面的「没给自己留休息」。
//
// **只有明确的保护时间才计入休息**：空白时间叫「可用空闲」或「未安排」，不叫「休息」（§3.1）。
import 'package:flutter/material.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/chart_kind.dart';
import 'package:personal_planner/features/analytics/analytics_shared_cards.dart';
import 'package:personal_planner/features/analytics/chart_view.dart';

/// **③ 我有没有好好休息**：休息时长（A）、工作与休息比例（D）、作息规律性（C）。
///
/// 三项**全部只看计划侧数据**：用户明确要求把"实际投入"从统计里拿掉，而"有没有好好休息"改看
/// 自己的规划——把任务排进睡眠、天天在不同时刻开工，就是规划层面的"没给自己留休息"。
///
/// 「图型选择」三个回调**可以是空**：§3.1 要求"去掉主路径上的任意切换图表类型"，
/// 因此页面默认**不渲染**选择器（三个 `on*Kind` 传空），空的那一个就不再出现在卡片标题右侧。
/// 注入方仍可传入以恢复选择器——那是给"设置里的高级选项"留的口子，不是主路径。
final class RestTab extends StatelessWidget {
  const RestTab({
    super.key,
    required this.report,
    this.restKind = ChartKind.pie,
    this.onRestKind,
    this.workRestKind = ChartKind.pie,
    this.onWorkRestKind,
    this.routineKind = ChartKind.bar,
    this.onRoutineKind,
  });

  final AnalyticsReport report;
  final ChartKind restKind;
  final ValueChanged<ChartKind>? onRestKind;
  final ChartKind workRestKind;
  final ValueChanged<ChartKind>? onWorkRestKind;
  final ChartKind routineKind;
  final ValueChanged<ChartKind>? onRoutineKind;

  @override
  Widget build(BuildContext context) {
    final rest = report.restSummary;
    final workRest = report.workRest;
    final routine = report.routine;
    if (rest == null && workRest == null && routine.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const Key('analytics-rest'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('休息', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (rest != null) ...[
          AnalyticsRestDurationCard(
            rest: rest,
            kind: restKind,
            onKind: onRestKind,
          ),
          const SizedBox(height: 16),
        ],
        if (workRest != null) ...[
          AnalyticsWorkRestCard(
            metric: workRest,
            kind: workRestKind,
            onKind: onWorkRestKind,
          ),
          const SizedBox(height: 16),
        ],
        if (!routine.isEmpty)
          AnalyticsRoutineCard(
            routine: routine,
            kind: routineKind,
            onKind: onRoutineKind,
          ),
      ],
    );
  }
}

/// A：各类休息的容量与被侵占量。
final class AnalyticsRestDurationCard extends StatelessWidget {
  const AnalyticsRestDurationCard({
    super.key,
    required this.rest,
    required this.kind,
    this.onKind,
  });

  final RestSummaryMetric rest;
  final ChartKind kind;
  final ValueChanged<ChartKind>? onKind;

  @override
  Widget build(BuildContext context) {
    final percent = (rest.achievedRatio * 100).round();
    return AnalyticsSectionCard(
      cardKey: const Key('analytics-rest-duration'),
      slot: AnalyticsChartSlot.restDuration,
      kind: kind,
      onKind: onKind,
      title: '休息时长',
      subtitle:
          '保护时间共 ${analyticsMinutes(rest.totalMinutes)}，'
          '平均每天 ${analyticsMinutes(rest.averageDailyMinutes)}；'
          '其中 ${analyticsMinutes(rest.invadedMinutes)} 被安排占用（达成 $percent%）',
      chart: AnalyticsChart(
        kind: kind,
        emptyLabel: '还没有设置任何保护时间。',
        data: [
          for (var index = 0; index < rest.windows.length; index++)
            ChartDatum(
              label: rest.windows[index].label,
              value: rest.windows[index].minutes,
              color: chartColorAt(index),
            ),
        ],
      ),
      footnote: rest.windows
          .map(
            (window) =>
                '${window.label} ${analyticsMinutes(window.minutes)}'
                '${window.invadedMinutes == 0 ? '（完整保留）' : '，被占用 ${analyticsMinutes(window.invadedMinutes)}'}',
          )
          .join('\n'),
    );
  }
}

/// D：工作 / 生活 / 休息 / 未安排 的四段比例。
final class AnalyticsWorkRestCard extends StatelessWidget {
  const AnalyticsWorkRestCard({
    super.key,
    required this.metric,
    required this.kind,
    this.onKind,
  });

  final WorkRestMetric metric;
  final ChartKind kind;
  final ValueChanged<ChartKind>? onKind;

  @override
  Widget build(BuildContext context) => AnalyticsSectionCard(
    cardKey: const Key('analytics-work-rest'),
    slot: AnalyticsChartSlot.workRest,
    kind: kind,
    onKind: onKind,
    title: '工作与休息的比例',
    subtitle:
        '休息（含生活）占 ${(metric.restRatio * 100).round()}%，'
        '工作占 ${(metric.workRatio * 100).round()}%',
    chart: AnalyticsChart(
      kind: kind,
      emptyLabel: '暂无可比较的时间。',
      data: [
        ChartDatum(
          label: '工作/学习',
          value: metric.workMinutes,
          color: chartColorAt(0),
        ),
        ChartDatum(
          label: '生活',
          value: metric.lifeMinutes,
          color: chartColorAt(1),
        ),
        ChartDatum(
          label: '空着的休息',
          value: metric.restMinutes,
          color: chartColorAt(2),
        ),
        ChartDatum(
          label: '未安排',
          value: metric.idleMinutes,
          color: chartColorAt(3),
        ),
      ],
    ),
    footnote:
        '工作/学习 ${analyticsMinutes(metric.workMinutes)}，'
        '生活 ${analyticsMinutes(metric.lifeMinutes)}，'
        '空着的休息 ${analyticsMinutes(metric.restMinutes)}，'
        '未安排 ${analyticsMinutes(metric.idleMinutes)}',
  );
}

/// C：作息规律性——每天的开工与收工时刻，以及它们的极差。
final class AnalyticsRoutineCard extends StatelessWidget {
  const AnalyticsRoutineCard({
    super.key,
    required this.routine,
    required this.kind,
    this.onKind,
  });

  final RoutineMetric routine;
  final ChartKind kind;
  final ValueChanged<ChartKind>? onKind;

  @override
  Widget build(BuildContext context) {
    final startSpread = routine.startSpreadMinutes ?? 0;
    final endSpread = routine.endSpreadMinutes ?? 0;
    // **一天的范围内不画这张图**：作息规律度量的是"一天与另一天的差别"，范围里只有一天时
    // 两个极差恒等于 0，图上就只剩一根柱子、横轴重复同一个日期。2026-10-07 用户报的
    // "横轴日期都是 10/7"正是这个——默认范围就是「今天」，而那天恰好只有 1 天有安排。
    // 一根柱子既看不出规律，又容易被读成"数据坏了"，因此改为说明原因并给出出路。
    final enoughDays = routine.perDay.length >= 2;
    return AnalyticsSectionCard(
      cardKey: const Key('analytics-routine'),
      slot: AnalyticsChartSlot.routine,
      kind: kind,
      onKind: onKind,
      title: '作息规律性',
      subtitle:
          '开工相差 ${analyticsMinutes(startSpread)}，收工相差 ${analyticsMinutes(endSpread)}；'
          '平均 ${analyticsClockText(routine.averageStartMinute)} 开工、'
          '${analyticsClockText(routine.averageEndMinute)} 收工',
      chart: enoughDays
          ? AnalyticsChart(
              kind: kind,
              emptyLabel: '这个范围里还没有任何安排。',
              data: [
                for (var index = 0; index < routine.perDay.length; index++)
                  ChartDatum(
                    label:
                        '${routine.perDay[index].localDate.month}/'
                        '${routine.perDay[index].localDate.day}',
                    // 用**每天安排的跨度**当数值：它同时反映"多早开工"和"多晚收工"，
                    // 比单独画开工时刻更能看出"这一天被拉得多长"。
                    value:
                        routine.perDay[index].lastMinute -
                        routine.perDay[index].firstMinute,
                    color: chartColorAt(index),
                  ),
              ],
            )
          : _notEnoughDays(),
      footnote: routine.perDay
          .map(
            (day) =>
                '${day.localDate.month}/${day.localDate.day} '
                '${analyticsClockText(day.firstMinute)}–${analyticsClockText(day.lastMinute)}',
          )
          .join('\n'),
    );
  }

  /// 范围里只有一天有安排时的替代内容。
  ///
  /// 高度与 [AnalyticsChart] 的默认高度对齐，避免切换范围时卡片高度跳一下。
  Widget _notEnoughDays() => SizedBox(
    height: 200,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          '这个范围里只有 1 天有安排，看不出作息规律。\n'
          '把时间范围切到「本周」或「本月」，有两天以上才比较得出来。',
          textAlign: TextAlign.center,
          style: const TextStyle(height: 1.5),
        ),
      ),
    ),
  );
}
