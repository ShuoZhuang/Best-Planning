import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
import 'package:personal_planner/features/calendar/schedule_category_legend.dart';
import 'package:personal_planner/features/calendar/schedule_category_summary.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

final class WeekViewPage extends StatefulWidget {
  const WeekViewPage({
    required this.source,
    required this.weekStart,
    required this.moveController,
    this.onProposalCreated,
    this.onOpenDay,
    this.onCreateEvent,
    this.onImportTimetable,
    this.toLocal,
    super.key,
  });

  final ScheduleViewSource source;
  final DateTime weekStart;
  final WeekMoveController moveController;
  final ValueChanged<String>? onProposalCreated;

  /// 打开某一天的日视图（FR-CAL-03）。参数是该日本地 00:00 对应的 UTC 时刻。
  ///
  /// 与周视图互为切换，因此不占用导航项；为空时不显示切换按钮。
  final ValueChanged<DateTime>? onOpenDay;
  final VoidCallback? onCreateEvent;
  final VoidCallback? onImportTimetable;
  final DateTime Function(DateTime instantUtc)? toLocal;

  @override
  State<WeekViewPage> createState() => _WeekViewPageState();
}

final class _WeekViewPageState extends State<WeekViewPage> {
  late Stream<List<ScheduleViewItem>> _stream;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    // **订阅窗口要比显示的八天更宽，左边多一天**：用户在 2026-10-07 要求"就像手机上的天气预报
    // 一样"——七天前面补一列"昨天"，可以往回看一眼刚过去的那天。少订阅那一天，昨天那一列会
    // 永远是空的，而界面上看起来像"昨天没有安排"（假空，比不显示更糟）。
    _stream = widget.source.watch(
      widget.weekStart.subtract(const Duration(days: 1)),
      widget.weekStart.add(const Duration(days: 7)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '七日日历',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              if (widget.onOpenDay != null)
                TextButton.icon(
                  key: const Key('open-day-view'),
                  // `weekStart` 是当前显示区间的第一天，而路由器传进来的就是"今天的本地
                  // 零点"，因此它正好是日视图要的那一天。
                  onPressed: () => widget.onOpenDay!(widget.weekStart),
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: const Text('查看当日'),
                ),
              if (widget.onImportTimetable != null)
                TextButton.icon(
                  key: const Key('import-timetable'),
                  onPressed: widget.onImportTimetable,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('导入课表'),
                ),
              if (widget.onCreateEvent != null)
                FilledButton.icon(
                  key: const Key('create-calendar-event'),
                  onPressed: widget.onCreateEvent,
                  icon: const Icon(Icons.add),
                  label: const Text('新建固定日程'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: StreamBuilder<List<ScheduleViewItem>>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('暂时无法加载七日计划'),
                        TextButton(
                          onPressed: () => setState(_subscribe),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: Text('正在加载七日计划'));
                }
                if (snapshot.data!.isEmpty) {
                  return const Center(child: Text('未来七天暂无安排'));
                }
                final summaries = summarizeScheduleCategories(snapshot.data!);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: ScheduleCategoryLegend(summaries: summaries),
                    ),
                    const SizedBox(height: 12),
                    Expanded(child: _week(context, snapshot.data!)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _week(BuildContext context, List<ScheduleViewItem> items) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // **索引从 -1 开始**：-1 是"昨天"那一列，0..6 仍然是"今天起七天"。
          //
          // 这个下标方案是刻意选的：`week-day-0` 依旧是**今天**，因此既有的用例与「查看当日」的
          // 语义都不用改，而昨天有一个稳定且一目了然的 key（`week-day--1`）。
          for (var index = -1; index < 7; index++)
            _DayColumn(
              key: ValueKey('week-day-$index'),
              day: widget.weekStart.add(Duration(days: index)),
              localDay: (widget.toLocal ?? (date) => date)(
                widget.weekStart.add(Duration(days: index)),
              ),
              relativeLabel: _relativeLabel(index),
              isToday: index == 0,
              toLocal: widget.toLocal,
              onOpenDay: widget.onOpenDay,
              items: items.where((item) {
                final day = widget.weekStart.add(Duration(days: index));
                return item.range.startUtc.isBefore(
                      day.add(const Duration(days: 1)),
                    ) &&
                    item.range.endUtc.isAfter(day);
              }).toList(),
              onMove: (item) async {
                final day = widget.weekStart.add(Duration(days: index));
                // FR-CAL-05 的"手动移动后可选择锁定"：放手后先问一次是否锁定。放在拖动这一侧
                // 而不是页面之外，是因为"锁定"是这次放置的属性，问在别处会丢掉上下文。
                final lock = await _askLock(context, item, day);
                if (lock == null) return;
                final proposalId = await widget.moveController.proposeMove(
                  item,
                  day,
                  lock: lock,
                );
                if (proposalId != null && mounted) {
                  widget.onProposalCreated?.call(proposalId);
                }
              },
            ),
        ],
      ),
    );
  }

  /// 列头第一行：`昨天` / `今天` / `明天` 优先，其余显示星期。
  ///
  /// 用户 2026-10-07 的要求原话："七日日历里要是昨天 今天 明天，然后后面就是周几周几"。
  /// 这也正是天气应用的做法：最近三天用相对日称呼（一眼知道是哪天），更远的日子用星期几
  /// （才读得出"离今天还有多远"）。
  String _relativeLabel(int index) {
    if (index == -1) return '昨天';
    if (index == 0) return '今天';
    if (index == 1) return '明天';
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final day = widget.weekStart.add(Duration(days: index));
    final local = (widget.toLocal ?? (date) => date)(day);
    return '周${names[local.weekday - 1]}';
  }
}

final class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.localDay,
    required this.items,
    required this.onMove,
    this.relativeLabel,
    this.isToday = false,
    this.toLocal,
    this.onOpenDay,
    super.key,
  });

  final DateTime day;
  final DateTime localDay;
  final List<ScheduleViewItem> items;
  final ValueChanged<ScheduleViewItem> onMove;
  final ValueChanged<DateTime>? onOpenDay;
  final DateTime Function(DateTime)? toLocal;

  /// 列头第一行：`昨天` / `今天` / `周三`。为空时不显示那一行。
  final String? relativeLabel;

  /// 是否是"今天"那一列。天气应用会把今天标出来，这里同样处理——否则八列长得一样，
  /// 用户得靠日期自己去数"今天是哪一列"。
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<ScheduleViewItem>(
      onAcceptWithDetails: (details) => onMove(details.data),
      builder: (context, candidates, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 176,
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? (isToday
                    ? scheme.surfaceContainerHigh
                    : scheme.surfaceContainerLow)
              : scheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            // 今天用主色描边 + 更亮的底：八列里一眼能找到它。
            color: isToday ? scheme.primary : scheme.outlineVariant,
            width: isToday ? 1.6 : 1,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  onTap: onOpenDay == null ? null : () => onOpenDay!(day),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (relativeLabel != null)
                          Text(
                            relativeLabel!,
                            key: ValueKey('week-day-label-$relativeLabel'),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: isToday
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                  fontWeight: isToday
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${localDay.month}月${localDay.day}日',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            if (onOpenDay != null)
                              const Icon(Icons.chevron_right_rounded, size: 18),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (var index = 0; index < items.length; index++) ...[
                  if (index > 0) const SizedBox(height: scheduleItemGap),
                  _DraggableScheduleCard(
                    item: items[index],
                    toLocal: toLocal,
                    onTap: onOpenDay == null ? null : () => onOpenDay!(day),
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

/// 放手后问一次"是否锁定"，返回 `null` 表示用户取消。
///
/// **为什么默认勾选**：手动放置是用户的显式指令，默认不让后续自动调整把它挪走；取消勾选
/// 仍然**按用户放的位置落地**（装配层照样钉住），只是落地为未锁定，后续重排可以再移动它。
/// 把这个差别写在对话框里，是因为两个分支的后果不同且都不可从界面回推。
Future<bool?> _askLock(
  BuildContext context,
  ScheduleViewItem item,
  DateTime day,
) => showDialog<bool>(
  context: context,
  builder: (dialogContext) => _MoveConfirmDialog(title: item.title, day: day),
);

final class _MoveConfirmDialog extends StatefulWidget {
  const _MoveConfirmDialog({required this.title, required this.day});

  final String title;
  final DateTime day;

  @override
  State<_MoveConfirmDialog> createState() => _MoveConfirmDialogState();
}

final class _MoveConfirmDialogState extends State<_MoveConfirmDialog> {
  bool _lock = true;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      '把「${widget.title}」移到 ${widget.day.month} 月 ${widget.day.day} 日',
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          key: const Key('move-lock'),
          value: _lock,
          onChanged: (value) => setState(() => _lock = value ?? false),
          title: const Text('锁定'),
          subtitle: const Text('锁定后，后续的自动调整不会再把这一块挪走'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const Text('取消勾选仍会移到这一天，但之后的重新排程可以再移动它。'),
      ],
    ),
    actions: [
      TextButton(
        key: const Key('move-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      TextButton(
        key: const Key('move-confirm'),
        onPressed: () => Navigator.of(context).pop(_lock),
        child: const Text('移动'),
      ),
    ],
  );
}

final class _DraggableScheduleCard extends StatelessWidget {
  const _DraggableScheduleCard({required this.item, this.toLocal, this.onTap});
  final ScheduleViewItem item;
  final DateTime Function(DateTime)? toLocal;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 卡片颜色**只**从共享派生器取：填充不透明、描边低亮，三个视图逐值一致。
    // 这里不能自己再叠 `withValues(alpha: …)`——那正是"卡片发白"的成因：底下的玻璃
    // 背景会透上来，四种材质模式下同一张卡片的观感各不相同。
    final visual = scheduleCategoryCardStyle(item.categoryColor);
    final card = Card(
      key: ValueKey('week-schedule-card-${item.id}'),
      color: visual.fill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: visual.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Semantics(
        label:
            '${item.title}，${_time((toLocal ?? (date) => date)(item.range.startUtc))}到${_time((toLocal ?? (date) => date)(item.range.endUtc))}，${item.categoryLabel}，${item.kind.label}'
            '${item.isCompleted ? '，已完成' : ''}',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(item.kind.icon, size: 16, color: visual.accent),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        item.categoryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                    // 「已完成」标记：任务勾选完成、或固定日程时间已过。
                    // 用 muted 而不是分类色——它是状态，不该跟分类抢注意力。
                    if (item.isCompleted)
                      Icon(
                        Icons.check_circle_outline,
                        key: ValueKey('week-schedule-completed-${item.id}'),
                        size: 14,
                        color: PlannerPalette.textMuted,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_time((toLocal ?? (date) => date)(item.range.startUtc))}–'
                  '${_time((toLocal ?? (date) => date)(item.range.endUtc))}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 4),
                Text(item.title),
              ],
            ),
          ),
        ),
      ),
    );
    return LongPressDraggable<ScheduleViewItem>(
      data: item,
      feedback: Material(
        elevation: 6,
        child: SizedBox(width: 160, child: card),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: card,
    );
  }
}

String _time(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:'
    '${date.minute.toString().padLeft(2, '0')}';
