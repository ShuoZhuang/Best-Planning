// 页签④「调整记录」（路线图 §3.1、§11 Task 4）。
//
// 精力时段、常见中断与重排原因：它们是「这套计划是怎么被改出来的」的证据，
// 与前面三个页签回答的问题不同，因此单独一页而不是塞在时间分配下面。
import 'package:flutter/material.dart';
import 'package:personal_planner/domain/models/analytics.dart';

/// FR-STAT-05 的"休息保护情况"那一行在领域模型上（`RestProtectionMetric.summaryLabel`）：
/// 那句话有真实分支（有没有放宽过），而它所在的卡在 `ListView` 里、视口外不会被构建，
/// 放在页面里就只能靠 widget 测试去够它。
final class AdjustmentsTab extends StatelessWidget {
  const AdjustmentsTab({super.key, required this.report});
  final AnalyticsReport report;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('analytics-evidence'),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('中断与调整', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          // **"不同精力时段的完成效果"与"休息保护情况"两行已按用户要求移除**：
          // 前者按**实际投入**分桶，后者按"实际专注有没有落进保护时间"算，两者都属于
          // "实际"这一侧。休息那一侧已由上面的《休息》一节按**计划侧**重做（休息时长/作息
          // 规律性/工作休息比例）。FR-STAT-06 的三项原样保留。
          Text(analyticsRankedText('常见中断', report.commonInterruptions)),
          const SizedBox(height: 6),
          Text(analyticsRankedText('重排原因', report.replanReasons)),
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

String analyticsRankedText(String label, List<RankedMetric> values) =>
    values.isEmpty
    ? '$label：暂无记录'
    : '$label：${values.map((item) => '${item.code} ${item.count} 次').join('，')}';
