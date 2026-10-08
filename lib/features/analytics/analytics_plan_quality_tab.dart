// 页签②「计划质量」（路线图 §3.1、§11 Task 4）。
//
// 「完成率／按期完成／逾期」三个问的都是**计划本身合不合理**，与「计划 vs 实际」无关，
// 因此按用户 2026-10-06 的要求保留；逾期率此前一直算出来却从未显示，是最便宜的一条。
import 'package:flutter/material.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/features/analytics/analytics_shared_cards.dart';

/// **③ 我规划得合理吗**：完成情况 + **领域覆盖缺口**。
///
/// "完成率/按期完成/逾期率"三个问的都是"计划本身合不合理"，与"计划 vs 实际"无关，因此按要求保留。
/// **逾期率此前一直算出来却从未显示**——它是最便宜的一条。
final class PlanQualityTab extends StatelessWidget {
  const PlanQualityTab({super.key, required this.report});
  final AnalyticsReport report;

  @override
  Widget build(BuildContext context) {
    final coverage = report.areaCoverage;
    return Wrap(
      key: const Key('analytics-plan-quality'),
      spacing: 12,
      runSpacing: 12,
      children: [
        AnalyticsMetricCard(
          icon: Icons.task_alt,
          title: analyticsRatioText('完成率', report.completionRate),
          detail: report.completionRate.isAvailable
              ? '范围内到期或完成的任务'
              : '该范围暂无可计算任务',
        ),
        AnalyticsMetricCard(
          icon: Icons.schedule_outlined,
          title: analyticsRatioText('按期完成', report.onTimeCompletionRate),
          detail: '分母是已完成且设有截止时间的任务',
        ),
        AnalyticsMetricCard(
          icon: Icons.warning_amber_outlined,
          title: analyticsRatioText('逾期', report.overdueRate),
          detail: '分母是范围内到期的任务；完成晚于截止即算逾期',
        ),
        if (coverage != null)
          AnalyticsMetricCard(
            key: const Key('analytics-area-coverage'),
            icon: Icons.grid_view_outlined,
            title: coverage.allCovered
                ? '领域覆盖 ${coverage.covered.length} / ${coverage.totalAreas}'
                : '未排计划：${coverage.uncovered.join('、')}',
            detail: coverage.allCovered
                ? '每个领域在这个范围里都有时间'
                : '这 ${coverage.uncovered.length} 个领域在范围内一个计划块、'
                      '一场固定日程都没有',
          ),
      ],
    );
  }
}
