import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_glass.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
import 'package:personal_planner/features/calendar/schedule_category_legend.dart';
import 'package:personal_planner/features/calendar/schedule_category_summary.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

final class TodayPage extends StatefulWidget {
  const TodayPage({
    required this.source,
    required this.day,
    this.toLocal,
    super.key,
  });

  final ScheduleViewSource source;
  final DateTime day;

  /// 视图数据以 UTC 保存；生产环境传入应用选定时区的换算函数。
  /// 测试与纯视图预览可省略，此时保持输入值不变。
  final DateTime Function(DateTime instantUtc)? toLocal;

  @override
  State<TodayPage> createState() => _TodayPageState();
}

final class _TodayPageState extends State<TodayPage> {
  late Stream<List<ScheduleViewItem>> _stream;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    _stream = widget.source.watch(
      widget.day,
      widget.day.add(const Duration(days: 1)),
    );
  }

  void _retry() => setState(_subscribe);

  @override
  void didUpdateWidget(covariant TodayPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.day != widget.day || oldWidget.source != widget.source) {
      _subscribe();
    }
  }

  @override
  Widget build(BuildContext context) {
    final toLocal = widget.toLocal ?? (value) => value;
    String formatTime(DateTime value) => _time(toLocal(value));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TodayHeader(day: toLocal(widget.day)),
          const SizedBox(height: 20),
          Expanded(
            child: StreamBuilder<List<ScheduleViewItem>>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return _RecoverableError(onRetry: _retry);
                }
                if (!snapshot.hasData) {
                  return const _LoadingState();
                }
                final items = [
                  for (final item in snapshot.data!)
                    if (item.range.startUtc.isBefore(
                          widget.day.add(const Duration(days: 1)),
                        ) &&
                        item.range.endUtc.isAfter(widget.day))
                      ScheduleViewItem(
                        id: item.id,
                        title: item.title,
                        kind: item.kind,
                        categoryKey: item.categoryKey,
                        categoryLabel: item.categoryLabel,
                        categoryColorArgb: item.categoryColorArgb,
                        categorySortOrder: item.categorySortOrder,
                        explanation: item.explanation,
                        // **拷贝时新字段容易漏**：这里的对象是"按当天裁剪过区间"的副本，
                        // 漏掉 `isCompleted` 会让"已完成"标记在这一页永远不显示——这条由
                        // `today_page_test.dart` 的标记用例守着。
                        isCompleted: item.isCompleted,
                        areaId: item.areaId,
                        range: TimeRange(
                          startUtc: item.range.startUtc.isBefore(widget.day)
                              ? widget.day
                              : item.range.startUtc,
                          endUtc:
                              item.range.endUtc.isAfter(
                                widget.day.add(const Duration(days: 1)),
                              )
                              ? widget.day.add(const Duration(days: 1))
                              : item.range.endUtc,
                        ),
                      ),
                ]..sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
                final categorySummaries = summarizeScheduleCategories(items);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: ScheduleCategoryLegend(
                        summaries: categorySummaries,
                      ),
                    ),
                    if (categorySummaries.isNotEmpty)
                      const SizedBox(height: 12),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth >= 960;
                          final timeline = _TimelinePanel(
                            items: items,
                            formatTime: formatTime,
                          );
                          final summary = _PlanningRail(
                            items: items,
                            categorySummaries: categorySummaries,
                            formatTime: formatTime,
                          );
                          if (wide) {
                            return Row(
                              key: const Key('today-wide-layout'),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(flex: 7, child: timeline),
                                const SizedBox(width: 16),
                                SizedBox(
                                  width: 310,
                                  child: SingleChildScrollView(child: summary),
                                ),
                              ],
                            );
                          }
                          return SingleChildScrollView(
                            key: const Key('today-compact-layout'),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                timeline,
                                const SizedBox(height: 16),
                                summary,
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

final class _TodayHeader extends StatelessWidget {
  const _TodayHeader({required this.day});

  final DateTime day;

  static const _weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('今日安排', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(
              '${day.month}月${day.day}日 · ${_weekdays[day.weekday - 1]}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    ],
  );
}

final class _TimelinePanel extends StatelessWidget {
  const _TimelinePanel({required this.items, required this.formatTime});

  final List<ScheduleViewItem> items;
  final String Function(DateTime value) formatTime;

  @override
  Widget build(BuildContext context) => _Panel(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final timeline = items.isEmpty
            ? const _EmptyTimeline()
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: Column(
                  children: [
                    for (var index = 0; index < items.length; index++)
                      _TimelineItem(
                        item: items[index],
                        isLast: index == items.length - 1,
                        formatTime: formatTime,
                      ),
                  ],
                ),
              );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _PanelHeading(
              title: '今日时间线',
              subtitle: '固定安排、保护时间与可移动事项',
              icon: Icons.view_timeline_outlined,
            ),
            const Divider(),
            if (constraints.hasBoundedHeight)
              Expanded(
                child: SingleChildScrollView(
                  key: const Key('today-timeline-scroll'),
                  child: timeline,
                ),
              )
            else
              timeline,
          ],
        );
      },
    ),
  );
}

final class _TimelineItem extends StatelessWidget {
  const _TimelineItem({
    required this.item,
    required this.isLast,
    required this.formatTime,
  });

  final ScheduleViewItem item;
  final bool isLast;
  final String Function(DateTime value) formatTime;

  @override
  Widget build(BuildContext context) {
    // 与七日历、单日详情共用同一个派生器：同一事项在三个视图里必须逐值同色。
    // 此前这里用的是 `alpha: 0.10`（比七日历的 0.18 还浅），左侧强调条却是 100% 原色，
    // 于是"浅底 + 亮条"看起来像两块拼在一起。
    final visual = scheduleCategoryCardStyle(item.categoryColor);
    return Semantics(
      key: ValueKey('today-schedule-${item.id}'),
      label:
          '${item.title}，${item.categoryLabel}，${item.kind.label}，${formatTime(item.range.startUtc)}到${formatTime(item.range.endUtc)}'
          '${item.isCompleted ? '，已完成' : ''}',
      child: SizedBox(
        height: 82,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 54,
              child: Padding(
                padding: const EdgeInsets.only(top: 11),
                child: Text(
                  formatTime(item.range.startUtc),
                  style: const TextStyle(
                    color: PlannerPalette.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 24,
              child: Column(
                children: [
                  const SizedBox(height: 14),
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: visual.accent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: PlannerPalette.surface,
                        width: 2,
                      ),
                    ),
                  ),
                  if (!isLast)
                    Expanded(
                      child: Container(width: 1, color: PlannerPalette.outline),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                key: ValueKey('today-schedule-card-${item.id}'),
                margin: const EdgeInsets.only(bottom: 10),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: visual.fill,
                  border: Border.all(color: visual.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                // **`stretch` 是这条竖条能不能被看见的关键**，不是排版洁癖：`Row` 默认
                // `CrossAxisAlignment.center`，而没有子节点的 `ColoredBox` 内在高度是 0，于是
                // "左侧强调条"会被量成 0×3 的零面积控件——控件树里有它、颜色也对、测试里
                // `tester.widget<ColoredBox>(...).color` 照样通过，屏幕上却什么都没有（用户就是
                // 这么发现它的）。卡片高度在这里本来就是紧约束（外层 `Row` 也是 `stretch`），
                // 所以只要把内层 `Row` 也设成 `stretch`，竖条就会被拉满整张卡片的高度。
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 3,
                      child: ColoredBox(
                        key: ValueKey('today-schedule-accent-${item.id}'),
                        color: visual.accent,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              item.kind.icon,
                              key: ValueKey('today-schedule-icon-${item.id}'),
                              size: 18,
                              color: visual.accent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: PlannerPalette.textPrimary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${formatTime(item.range.startUtc)}–${formatTime(item.range.endUtc)} · ${item.categoryLabel}',
                                    style: const TextStyle(
                                      color: PlannerPalette.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // 「已完成」标记。任务：所属任务已勾选完成；固定日程：结束时间已过。
                            // 用 muted 而不是分类色：它不是分类信息，只是状态，不该跟分类抢注意力。
                            if (item.isCompleted) ...[
                              const SizedBox(width: 8),
                              Icon(
                                Icons.check_circle_outline,
                                key: ValueKey(
                                  'today-schedule-completed-${item.id}',
                                ),
                                size: 16,
                                color: PlannerPalette.textMuted,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 250,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.free_breakfast_outlined,
            size: 34,
            color: PlannerPalette.textMuted,
          ),
          SizedBox(height: 10),
          Text(
            '今天暂无安排',
            style: TextStyle(
              color: PlannerPalette.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 4),
          Text('留白也是计划的一部分', style: TextStyle(color: PlannerPalette.textMuted)),
        ],
      ),
    ),
  );
}

final class _PlanningRail extends StatelessWidget {
  const _PlanningRail({
    required this.items,
    required this.categorySummaries,
    required this.formatTime,
  });

  final List<ScheduleViewItem> items;
  final List<ScheduleCategorySummary> categorySummaries;
  final String Function(DateTime value) formatTime;

  @override
  Widget build(BuildContext context) {
    final current = _currentOrNext(items);
    final totalMinutes = items.fold<int>(
      0,
      (sum, item) => sum + item.range.durationMinutes,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Panel(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Eyebrow(label: '当前安排'),
                const SizedBox(height: 14),
                if (current == null) ...[
                  const Text(
                    '暂时没有进行中的事项',
                    style: TextStyle(
                      color: PlannerPalette.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    '可以安心休息，或从任务清单中选择下一件事。',
                    style: TextStyle(color: PlannerPalette.textSecondary),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Icon(
                        current.kind.icon,
                        color: current.categoryColor,
                        size: 20,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          current.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: PlannerPalette.textPrimary,
                            fontSize: 17,
                            height: 1.35,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  Text(
                    '${formatTime(current.range.startUtc)}–${formatTime(current.range.endUtc)} · ${current.categoryLabel}',
                    style: const TextStyle(color: PlannerPalette.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _Panel(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Eyebrow(label: '今日容量'),
                const SizedBox(height: 10),
                Text(
                  '共安排 ${_durationText(totalMinutes)}',
                  style: const TextStyle(
                    color: PlannerPalette.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${items.length} 个时间块，以真实日程时长统计',
                  style: const TextStyle(color: PlannerPalette.textMuted),
                ),
                const SizedBox(height: 16),
                _CapacityBar(summaries: categorySummaries),
                const SizedBox(height: 14),
                for (
                  var index = 0;
                  index < categorySummaries.length;
                  index++
                ) ...[
                  if (index > 0) const SizedBox(height: 8),
                  _MetricRow(
                    key: ValueKey(
                      'today-capacity-category-${categorySummaries[index].categoryKey}',
                    ),
                    label: categorySummaries[index].categoryLabel,
                    value: _durationText(categorySummaries[index].minutes),
                    color: categorySummaries[index].categoryColor,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const _Panel(
          child: Padding(
            padding: EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 20,
                  color: PlannerPalette.positive,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '暂无待确认调整',
                        style: TextStyle(
                          color: PlannerPalette.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '突发变化发生时，系统会先提供预览。',
                        style: TextStyle(color: PlannerPalette.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class _CapacityBar extends StatelessWidget {
  const _CapacityBar({required this.summaries});

  final List<ScheduleCategorySummary> summaries;

  @override
  Widget build(BuildContext context) {
    final total = summaries.fold<int>(0, (sum, item) => sum + item.minutes);
    if (total == 0) {
      return Container(
        key: const Key('today-capacity-bar'),
        height: 7,
        decoration: BoxDecoration(
          color: PlannerPalette.surfaceHover,
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        key: const Key('today-capacity-bar'),
        height: 7,
        child: Row(
          // **`stretch` 必不可少**：`Row` 默认 `CrossAxisAlignment.center`，而每段是无子节点的
          // `ColoredBox`（内在高度 0），于是"有安排时"整条容量条会被量成 0 高、完全看不见——
          // 反而"当天没有安排"那条灰色底条是普通 `Container(height: 7)`，一直看得见。用户看到的
          // 现象就是"有数据时容量条消失"。这里靠 `stretch` 让各段铺满这 7 像素。
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final summary in summaries)
              if (summary.minutes > 0)
                Expanded(
                  flex: summary.minutes,
                  child: ColoredBox(color: summary.categoryColor),
                ),
          ],
        ),
      ),
    );
  }
}

final class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
    required this.color,
    super.key,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          label,
          style: const TextStyle(color: PlannerPalette.textSecondary),
        ),
      ),
      Text(
        value,
        style: const TextStyle(
          color: PlannerPalette.textPrimary,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}

final class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => PlannerGlassSurface(child: child);
}

final class _PanelHeading extends StatelessWidget {
  const _PanelHeading({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 15, 18, 14),
    child: Row(
      children: [
        Icon(icon, color: PlannerPalette.accent, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: PlannerPalette.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: PlannerPalette.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

final class _Eyebrow extends StatelessWidget {
  const _Eyebrow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label.toUpperCase(),
    style: const TextStyle(
      color: PlannerPalette.textMuted,
      fontSize: 12,
      letterSpacing: 0.8,
      fontWeight: FontWeight.w700,
    ),
  );
}

final class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(height: 12),
        Text('正在加载今日安排'),
      ],
    ),
  );
}

final class _RecoverableError extends StatelessWidget {
  const _RecoverableError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off_outlined, size: 40),
        const SizedBox(height: 8),
        const Text('暂时无法加载今日安排'),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

ScheduleViewItem? _currentOrNext(List<ScheduleViewItem> items) {
  if (items.isEmpty) return null;
  final now = DateTime.now().toUtc();
  for (final item in items) {
    if (!item.range.endUtc.isBefore(now)) return item;
  }
  return items.last;
}

String _durationText(int minutes) {
  if (minutes <= 0) return '0 分钟';
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  if (hours == 0) return '$remainder 分钟';
  if (remainder == 0) return '$hours 小时';
  return '$hours 小时 $remainder 分钟';
}

String _time(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';
