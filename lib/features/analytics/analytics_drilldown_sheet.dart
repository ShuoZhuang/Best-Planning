// 来源明细（路线图 §3.1、§7.1 第 6 条、§11 Task 4）。
//
// §3.1 要求"每个摘要、比例和图表项都能打开来源明细，再从明细进入任务或日程"，§7.1 第 6 条把它
// 写成硬口径："所有比例显示分子与分母，所有图表项能查看来源"。
//
// **这个件解决的是一类具体的不信任**：统计页给出"学业 19 小时"时，用户唯一能做的核对方式是
// 自己去日历里数。明细面板把那个数字背后的东西列出来——每一行是哪个领域、多少分钟、
// 由几件事构成——并且**能点进那件事本身**。
//
// **没有来源时给解释，不给空列表**（§11 Task 4 Step 6 与 §12 的要求）：一个空白面板看起来像
// 功能坏了，而"这个范围内没有已确认的计划块"是一句有用的信息。
import 'package:flutter/material.dart';
import 'package:personal_planner/core/area_palette.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/features/analytics/analytics_axis_policy.dart';

/// 四项摘要里可以打开来源的那几项。
enum AnalyticsSummarySlot {
  plannedMinutes,
  completion,
  restProtection,
  pressingIssue,
}

/// 明细里的一行：一个**稳定实体**加它占的分钟数。
///
/// [id] 必须是领域 id 或任务 id 这类稳定标识，而不是标题——标题会改、会重名，拿它当键就没法
/// 跳转，也没法去重。§11 Task 4 的接口要求正是"包含稳定实体 ID、标题、分钟、领域色和目标路由"。
final class AnalyticsBreakdown {
  const AnalyticsBreakdown({
    required this.id,
    required this.title,
    required this.minutes,
    required this.colorArgb,
    this.target,
  });

  final String id;
  final String title;
  final int minutes;
  final int colorArgb;

  /// 这一行能去的地方；`null` 表示它没有对应页面（此时界面不显示入口）。
  final AnalyticsBreakdownTarget? target;
}

/// 明细行的去向。与 M1 的 `ScheduleItemOpenTarget` 同一个思路：把"该去哪儿"表达成数据，
/// 由持有路由的那一层翻译，页面不认识路由。
sealed class AnalyticsBreakdownTarget {
  const AnalyticsBreakdownTarget();
}

/// 进入某个领域的时间分配（领域管理页）。
final class AreaBreakdownTarget extends AnalyticsBreakdownTarget {
  const AreaBreakdownTarget(this.areaId);
  final String areaId;
}

/// 进入某条固定日程所在的那一天。
final class EventBreakdownTarget extends AnalyticsBreakdownTarget {
  const EventBreakdownTarget({
    required this.eventId,
    required this.dayStartUtc,
  });
  final String eventId;
  final DateTime dayStartUtc;
}

/// 进入某个任务。
final class TaskBreakdownTarget extends AnalyticsBreakdownTarget {
  const TaskBreakdownTarget(this.taskId);
  final String taskId;
}

/// 一个摘要项的完整明细：一行标题 + 若干行 + 一句"这些行是什么口径"。
final class AnalyticsBreakdownSheetData {
  const AnalyticsBreakdownSheetData({
    required this.title,
    required this.subtitle,
    required this.rows,
    required this.emptyExplanation,
  });

  final String title;

  /// 口径说明。§7.1 第 6 条要的"分子与分母"就写在这里。
  final String subtitle;

  final List<AnalyticsBreakdown> rows;

  /// 没有行时显示的**解释**，而不是空列表。
  final String emptyExplanation;
}

/// 按摘要项组装它的来源明细。
///
/// 只做**已经存在的数字的分解**，不重新计算任何指标：总时长来自 `domainDistribution`、
/// 完成率来自 `completionRate`、保护时间来自 `restSummary`。统计页的任何一处都不该在这里
/// 出现第二套口径——那正是"同一个数字在两个地方不一样"的来源。
AnalyticsBreakdownSheetData analyticsBreakdownFor(
  AnalyticsReport report,
  AnalyticsSummarySlot slot,
) {
  switch (slot) {
    case AnalyticsSummarySlot.plannedMinutes:
      final items = [
        for (final item in report.domainDistribution)
          if (item.totalMinutes > 0) item,
      ];
      return AnalyticsBreakdownSheetData(
        title: '计划总时长',
        subtitle:
            '口径：所选范围里各领域的**总占用** = 已确认计划块 + 固定日程。'
            '共 ${items.length} 个领域。',
        rows: [
          for (final item in items)
            AnalyticsBreakdown(
              id: item.id,
              title: item.label,
              minutes: item.totalMinutes,
              colorArgb: resolveAreaColorArgb(
                item.storedColorArgb,
                item.sortOrder,
              ),
              target: item.id.isEmpty ? null : AreaBreakdownTarget(item.id),
            ),
        ],
        emptyExplanation:
            '这个范围里没有已确认的计划块，也没有固定日程。'
            '生成计划或导入课表之后，这里会逐领域列出时间是怎么分掉的。',
      );

    case AnalyticsSummarySlot.completion:
      final metric = report.completionRate;
      return AnalyticsBreakdownSheetData(
        title: '任务完成率',
        subtitle: metric.isAvailable
            ? '口径：完成 ${metric.numerator} 个 / 范围内到期或完成 '
                  '${metric.denominator} 个任务。分子与分母都来自同一批筛选后的任务。'
            : '口径：这个范围里没有到期的任务，因此算不出完成率——'
                  '分母为 0 时显示"暂无数据"，而不是 0%。',
        rows: [
          AnalyticsBreakdown(
            id: 'completion-numerator',
            title: '已完成',
            minutes: metric.numerator,
            colorArgb: PlannerPalette.accent.toARGB32(),
          ),
          AnalyticsBreakdown(
            id: 'completion-denominator',
            title: '范围内到期或完成（分母）',
            minutes: metric.denominator,
            colorArgb: PlannerPalette.textMuted.toARGB32(),
          ),
          if (metric.isAvailable)
            AnalyticsBreakdown(
              id: 'completion-missing',
              title: '到期但未完成',
              minutes: metric.denominator - metric.numerator,
              colorArgb: PlannerPalette.textSecondary.toARGB32(),
            ),
        ],
        emptyExplanation: '这个范围里没有到期的任务，因此没有可分解的来源。',
      );

    case AnalyticsSummarySlot.restProtection:
      final rest = report.restSummary;
      final windows = rest?.windows ?? const <RestWindowMetric>[];
      return AnalyticsBreakdownSheetData(
        title: '保护时间达成率',
        subtitle: rest == null || rest.totalMinutes == 0
            ? '口径：达成率 = 未被占用的保护时间 / 保护时间总量。'
                  '当前没有设置任何保护时间，因此不显示百分比，而是显示"未设置"。'
            : '口径：未被占用 ${formatAnalyticsMinutes(rest.freeMinutes)} / '
                  '保护共 ${formatAnalyticsMinutes(rest.totalMinutes)}，'
                  '范围内 ${rest.days} 天。',
        rows: [
          for (final window in windows)
            AnalyticsBreakdown(
              id: 'rest-${window.label}',
              title: window.invadedMinutes == 0
                  ? '${window.label}（完整保留）'
                  : '${window.label}（被占用 '
                        '${formatAnalyticsMinutes(window.invadedMinutes)}）',
              minutes: window.minutes,
              colorArgb: PlannerPalette.accent.toARGB32(),
            ),
        ],
        emptyExplanation:
            '还没有设置睡眠或用餐保护时间。在「设置 → 规划规则」里加上之后，'
            '这一项会按每类窗口列出总量与被占用的分钟数。',
      );

    case AnalyticsSummarySlot.pressingIssue:
      final coverage = report.areaCoverage;
      final rows = <AnalyticsBreakdown>[
        if (coverage != null)
          AnalyticsBreakdown(
            id: 'coverage-uncovered',
            title: '未排计划的领域',
            minutes: coverage.uncovered.length,
            colorArgb: PlannerPalette.textPrimary.toARGB32(),
          ),
        if (report.overdueRate.isAvailable)
          AnalyticsBreakdown(
            id: 'overdue-numerator',
            title: '逾期完成',
            minutes: report.overdueRate.numerator,
            colorArgb: PlannerPalette.textSecondary.toARGB32(),
          ),
        if (report.overdueRate.isAvailable)
          AnalyticsBreakdown(
            id: 'overdue-denominator',
            title: '范围内到期（分母）',
            minutes: report.overdueRate.denominator,
            colorArgb: PlannerPalette.textMuted.toARGB32(),
          ),
      ];
      return AnalyticsBreakdownSheetData(
        title: '最需处理的问题',
        subtitle:
            '口径：按"用户能立刻动手的程度"排序——漏排的领域 → 被侵占的保护时间 → 逾期。'
            '这一项的判据写在 `analytics_overview.dart` 里，可以直接质疑与修改。',
        rows: rows,
        emptyExplanation:
            '这个范围里没有明显的缺口：领域都排到了时间，保护时间没有被侵占，'
            '逾期也没有多于按期完成。',
      );
  }
}

/// 打开来源明细的底部面板。
///
/// 用 `showModalBottomSheet` 而不是新开一个页面：明细是**对当前数字的补充**，用户看完要立刻
/// 回到原来的页签（§3.2 的"返回后保留来源页"是同一诉求）。新开一页会把统计页整页换掉，
/// 回来时页签与滚动位置都可能丢。
Future<void> showAnalyticsBreakdown(
  BuildContext context, {
  required AnalyticsBreakdownSheetData data,
  void Function(AnalyticsBreakdown row)? onOpenRow,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => AnalyticsBreakdownSheet(
      data: data,
      onOpenRow: onOpenRow == null
          ? null
          : (row) {
              Navigator.of(sheetContext).pop();
              onOpenRow(row);
            },
    ),
  );
}

/// 来源明细面板本体。
///
/// 与 `showAnalyticsBreakdown` 分开，是为了能**直接挂进 widget 测试**而不必真的弹一个
/// modal——弹窗在测试里要额外处理 `pumpAndSettle` 与路由，而这一件的内容才是要验的东西。
final class AnalyticsBreakdownSheet extends StatelessWidget {
  const AnalyticsBreakdownSheet({
    required this.data,
    this.onOpenRow,
    super.key,
  });

  final AnalyticsBreakdownSheetData data;
  final ValueChanged<AnalyticsBreakdown>? onOpenRow;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(data.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              data.subtitle,
              style: const TextStyle(
                color: PlannerPalette.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            if (data.rows.isEmpty)
              // 空来源给**解释**，不给空列表。
              Padding(
                key: const Key('analytics-breakdown-empty'),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  data.emptyExplanation,
                  style: const TextStyle(color: PlannerPalette.textSecondary),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  key: const Key('analytics-breakdown-rows'),
                  shrinkWrap: true,
                  itemCount: data.rows.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final row = data.rows[index];
                    final target = row.target;
                    final canOpen = target != null && onOpenRow != null;
                    return ListTile(
                      key: Key('analytics-breakdown-${row.id}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          // 与图表同一套颜色（`domainDistribution` 带的存储色），
                          // 因此明细里的色块和图里那一根是同一个值。
                          color: Color(row.colorArgb),
                          shape: BoxShape.circle,
                        ),
                      ),
                      title: Text(row.title),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            formatAnalyticsMinutes(row.minutes),
                            style: const TextStyle(
                              color: PlannerPalette.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          // 没有去处时**不画箭头**：一个点了没反应的箭头是死入口。
                          if (canOpen)
                            const Icon(
                              Icons.chevron_right,
                              size: 18,
                              color: PlannerPalette.textMuted,
                            ),
                        ],
                      ),
                      onTap: canOpen ? () => onOpenRow!(row) : null,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
