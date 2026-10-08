// 首页四项摘要（路线图 §3.1、§11 Task 4）。
//
// §3.1 规定首页先给四个数字，而不是让用户自己去图里找：
//
//   ① 计划总时长   ② 任务完成率   ③ 保护时间达成率   ④ 最需处理的问题
//
// **为什么单独成件**：它是"打开这一页第一眼看到什么"的答案，四个数字各有各的口径（总时长是
// 计划块 + 固定日程；完成率有分子分母；达成率来自保护窗口；"最需处理"是一个判断），把它们塞进
// 页面的 build 里会让口径散落在渲染代码中间。这里集中给出，并且**每个数字都带分子与分母或
// 计算依据的说明**——§7.1 第 6 条要求"所有比例显示分子与分母"。
import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/features/analytics/analytics_axis_policy.dart';
import 'package:personal_planner/features/analytics/analytics_drilldown_sheet.dart';

/// 四项摘要。`onOpenSource` 为 `null` 时卡片不可点（端口未装配时不显示死入口）。
final class AnalyticsOverview extends StatelessWidget {
  const AnalyticsOverview({
    required this.report,
    this.onOpenSource,
    this.onGeneratePlan,
    this.onOpenRestRules,
    super.key,
  });

  final AnalyticsReport report;

  /// 点某一项时打开它的来源明细。参数是这一项的稳定标识（见
  /// `analyticsBreakdownFor`），由页面负责翻译成底部面板。
  final ValueChanged<AnalyticsSummarySlot>? onOpenSource;

  /// 空状态里的**下一步操作**（路线图 §11 Task 12 Step 3："为无统计、无确认计划、周期未安排、
  /// 无更新和数据不足提供下一步操作"）。
  ///
  /// **为什么空状态需要动作**：`计划总时长 0 分钟` 配一句"所选范围里还没有已确认的计划块"
  /// 只解释了现状，用户下一步该做什么得自己猜——而他能做的其实只有一件事：去生成计划。
  /// 一句说明加一个按钮，比两句说明有用。
  ///
  /// 为 `null` 时**不渲染按钮**：没装配排程服务就没有"生成计划"可去，给按钮等于给死入口。
  final VoidCallback? onGeneratePlan;

  /// 保护时间没设置时的下一步（去规划规则页设置睡眠与用餐时间）。
  final VoidCallback? onOpenRestRules;

  @override
  Widget build(BuildContext context) {
    final totalPlanned = report.domainDistribution.fold<int>(
      0,
      (sum, item) => sum + item.totalMinutes,
    );
    final rest = report.restSummary;
    final issue = _mostPressingIssue(report);

    return Wrap(
      key: const Key('analytics-overview'),
      spacing: 12,
      runSpacing: 12,
      children: [
        _SummaryCard(
          cardKey: const Key('analytics-summary-planned'),
          icon: Icons.event_available_outlined,
          title: '计划总时长',
          // §7.1 第 3 条：主图数值不显示裸分钟。1195 写成"19 小时 55 分钟"。
          value: formatAnalyticsMinutes(totalPlanned),
          detail: totalPlanned == 0
              ? '所选范围里还没有已确认的计划块或固定日程'
              : _plannedDetail(report),
          onTap: onOpenSource == null
              ? null
              : () => onOpenSource!(AnalyticsSummarySlot.plannedMinutes),
          // 没有任何计划时给出下一步：唯一能改变这个数字的动作就是去生成计划。
          // 端口为空时不给按钮（没装配排程服务就没有"生成计划"可去）。
          actionLabel: totalPlanned == 0 ? '去生成计划' : null,
          onAction: totalPlanned == 0 ? onGeneratePlan : null,
        ),
        _SummaryCard(
          cardKey: const Key('analytics-summary-completion'),
          icon: Icons.task_alt,
          title: '任务完成率',
          value: _ratioText(report.completionRate),
          // 分子与分母都要露出来，否则"75%"是一个无法核对的数字。
          detail: report.completionRate.isAvailable
              ? '完成 ${report.completionRate.numerator} / '
                    '范围内到期或完成 ${report.completionRate.denominator}'
              : '该范围暂无可计算任务',
          onTap: onOpenSource == null
              ? null
              : () => onOpenSource!(AnalyticsSummarySlot.completion),
        ),
        _SummaryCard(
          cardKey: const Key('analytics-summary-rest'),
          icon: Icons.bedtime_outlined,
          title: '保护时间达成率',
          value: rest == null || rest.totalMinutes == 0
              ? '未设置'
              : '${(rest.achievedRatio * 100).round()}%',
          detail: rest == null || rest.totalMinutes == 0
              ? '还没有设置睡眠或用餐保护时间'
              : '未被占用 ${formatAnalyticsMinutes(rest.freeMinutes)} / '
                    '保护共 ${formatAnalyticsMinutes(rest.totalMinutes)}',
          onTap: onOpenSource == null
              ? null
              : () => onOpenSource!(AnalyticsSummarySlot.restProtection),
          // 没有保护时间时给出下一步：去规划规则页设置睡眠与用餐时间。
          actionLabel: rest == null || rest.totalMinutes == 0
              ? '去设置保护时间'
              : null,
          onAction: rest == null || rest.totalMinutes == 0
              ? onOpenRestRules
              : null,
        ),
        _SummaryCard(
          cardKey: const Key('analytics-summary-issue'),
          icon: issue.icon,
          title: '最需处理的问题',
          value: issue.title,
          detail: issue.detail,
          onTap: onOpenSource == null
              ? null
              : () => onOpenSource!(AnalyticsSummarySlot.pressingIssue),
        ),
      ],
    );
  }

  /// "计划总时长"的构成说明。把课表与自排分开说，因为用户 2026-10-06 的原话就是
  /// "领域时间分配为什么不把固定日程统计进去"——这里顺手回答"我的时间有多少是课表"。
  String _plannedDetail(AnalyticsReport report) {
    final planned = report.domainDistribution.fold<int>(
      0,
      (sum, item) => sum + item.plannedMinutes,
    );
    final fixed = report.domainDistribution.fold<int>(
      0,
      (sum, item) => sum + item.fixedMinutes,
    );
    if (fixed == 0) return '全部来自已确认的计划块';
    if (planned == 0) return '全部来自固定日程（课表、会议等）';
    return '计划块 ${formatAnalyticsMinutes(planned)} + '
        '固定日程 ${formatAnalyticsMinutes(fixed)}';
  }

  String _ratioText(RatioMetric metric) =>
      metric.isAvailable ? '${(metric.ratio! * 100).round()}%' : '暂无数据';
}

/// 四项摘要里的一项（内部用）。
final class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.value,
    required this.detail,
    this.onTap,
    this.actionLabel,
    this.onAction,
  });

  final Key cardKey;
  final IconData icon;
  final String title;
  final String value;
  final String detail;
  final VoidCallback? onTap;

  /// 空状态里的下一步动作文案。为 `null`（或 [onAction] 为 `null`）时不渲染按钮。
  final String? actionLabel;

  /// 下一步动作。**与 [onTap] 是两件事**：`onTap` 是"看这个数字的来源"，本项是"去改变它"。
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Card(
        key: cardKey,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: PlannerPalette.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: PlannerPalette.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    // 能打开来源时才给这个提示：不能点的时候画一个箭头就是死入口（§3.2 同一口径）。
                    if (onTap != null)
                      const Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: PlannerPalette.textMuted,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  value,
                  style: const TextStyle(
                    color: PlannerPalette.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: const TextStyle(
                    color: PlannerPalette.textSecondary,
                    fontSize: 12,
                  ),
                ),
                // 空状态的下一步动作（§11 Task 12 Step 3）。只在**两个端口都非空**时渲染：
                // 有文案没动作是死入口，有动作没文案用户不知道点了会去哪。
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 6),
                  TextButton(
                    key: Key('${cardKey.toString()}-action'),
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「最需处理的问题」的判断结果。
final class _PressingIssue {
  const _PressingIssue({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;
}

/// 从报告里挑出**最该先处理的一件事**。
///
/// **判据与顺序**（每一条都能从报告里直接读出来，不做推断）：
/// 1. 有统计不到任何时间的领域 → 那个领域是"根本没排"，比比例难看更值得先处理；
/// 2. 保护时间被安排侵占 → 作息在给别的事让路；
/// 3. 逾期率高于按期完成率 → 计划本身估得不准；
/// 4. 以上都没有 → 明确说"没有明显问题"，而不是留一张空卡。
///
/// **为什么顺序是这样**：漏排是"缺一块"，被侵占是"正在受损"，逾期是"估得不准"——
/// 用户能立刻动手的程度依次下降。这条顺序写在这里，是为了让它可被质疑与修改，
/// 而不是藏在一串 `if` 里。
_PressingIssue _mostPressingIssue(AnalyticsReport report) {
  final coverage = report.areaCoverage;
  if (coverage != null && !coverage.allCovered) {
    return _PressingIssue(
      icon: Icons.grid_view_outlined,
      title: '未排计划：${coverage.uncovered.join('、')}',
      detail: '这 ${coverage.uncovered.length} 个领域在范围内一个计划块、一场固定日程都没有',
    );
  }

  final rest = report.restSummary;
  if (rest != null && rest.invadedMinutes > 0) {
    return _PressingIssue(
      icon: Icons.warning_amber_outlined,
      title:
          '保护时间被占用 '
          '${formatAnalyticsMinutes(rest.invadedMinutes)}',
      detail: '睡眠或用餐时间里有已确认的安排，作息在给别的事让路',
    );
  }

  if (report.overdueRate.isAvailable &&
      report.onTimeCompletionRate.isAvailable &&
      report.overdueRate.ratio! > report.onTimeCompletionRate.ratio!) {
    return _PressingIssue(
      icon: Icons.schedule_outlined,
      title:
          '逾期多于按期（${report.overdueRate.numerator} / '
          '${report.overdueRate.denominator}）',
      detail: '完成晚于截止的任务比按期完成的多，预计时长可能估短了',
    );
  }

  return const _PressingIssue(
    icon: Icons.check_circle_outline,
    title: '没有明显问题',
    detail: '领域都排到了时间，保护时间没有被侵占，逾期也没有多于按期',
  );
}
