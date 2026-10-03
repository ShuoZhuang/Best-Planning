import 'package:flutter/material.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

final class WeekViewPage extends StatefulWidget {
  const WeekViewPage({
    required this.source,
    required this.weekStart,
    required this.moveController,
    this.onProposalCreated,
    this.onOpenDay,
    this.onCreateEvent,
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
    _stream = widget.source.watch(
      widget.weekStart,
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
                return _week(context, snapshot.data!);
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
          for (var index = 0; index < 7; index++)
            _DayColumn(
              key: ValueKey('week-day-$index'),
              day: widget.weekStart.add(Duration(days: index)),
              items: items.where((item) {
                final date = item.range.startUtc;
                final day = widget.weekStart.add(Duration(days: index));
                return date.year == day.year &&
                    date.month == day.month &&
                    date.day == day.day;
              }).toList(),
              onMove: (item) async {
                final proposalId = await widget.moveController.proposeMove(
                  item,
                  widget.weekStart.add(Duration(days: index)),
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
}

final class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.items,
    required this.onMove,
    super.key,
  });

  final DateTime day;
  final List<ScheduleViewItem> items;
  final ValueChanged<ScheduleViewItem> onMove;

  @override
  Widget build(BuildContext context) {
    return DragTarget<ScheduleViewItem>(
      onAcceptWithDetails: (details) => onMove(details.data),
      builder: (context, candidates, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 176,
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? Theme.of(context).colorScheme.surfaceContainerLow
              : Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${day.month}月${day.day}日',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            for (final item in items) _DraggableScheduleCard(item: item),
          ],
        ),
      ),
    );
  }
}

final class _DraggableScheduleCard extends StatelessWidget {
  const _DraggableScheduleCard({required this.item});
  final ScheduleViewItem item;

  @override
  Widget build(BuildContext context) {
    final card = Card(
      color: item.kind.color(Theme.of(context).colorScheme),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(item.kind.icon, size: 16),
                const SizedBox(width: 4),
                Text(
                  item.kind.label,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(item.title),
          ],
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
