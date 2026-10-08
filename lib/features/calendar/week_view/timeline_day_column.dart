import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/timeline_layout.dart';

/// 一天的时间轴列。
///
/// **M5（路线图 §9）**：卡片高度与持续时间成比例、同时发生的并排、可滚动看全天。
/// 几何全部来自 [layoutTimelineDay]（纯函数，已穷举测试）；这里只负责画。
///
/// **颜色必须复用统一目录**（§9）：走 [scheduleCategoryCardStyle]，与紧凑模式、今日页、
/// 单日页同一个派生器——同一事项在四个视图里必须逐值同色。
final class TimelineDayColumn extends StatelessWidget {
  const TimelineDayColumn({
    required this.items,
    required this.metrics,
    required this.localDayStart,
    required this.toLocal,
    this.onOpenItem,
    super.key,
  });

  /// 当天（已按当天裁剪）的条目。
  final List<ScheduleViewItem> items;

  final TimelineMetrics metrics;

  /// 当天本地 00:00，用来把 UTC 时刻换算成"当天第几分钟"。
  final DateTime localDayStart;

  /// 视图数据以 UTC 保存；生产环境传入应用选定时区的换算函数。
  final DateTime Function(DateTime instantUtc)? toLocal;

  final ValueChanged<ScheduleViewItem>? onOpenItem;

  DateTime _local(DateTime value) => (toLocal ?? (instant) => instant)(value);

  @override
  Widget build(BuildContext context) {
    // 把每条的时间范围算**一次**，几何与文字共用同一份结果——算两次迟早会不一致。
    final ranges = <String, ({int start, int end})>{
      for (final item in items)
        item.id: minuteRangeInDay(
          _local(item.range.startUtc),
          _local(item.range.endUtc),
        ),
    };
    final blocks = layoutTimelineDay(
      items: items,
      metrics: metrics,
      startMinuteOf: (item) => ranges[item.id]!.start,
      endMinuteOf: (item) => ranges[item.id]!.end,
    );
    final byId = {for (final item in items) item.id: item};

    return SizedBox(
      height: metrics.contentHeight,
      child: Stack(
        children: [
          for (final block in blocks)
            if (byId[block.itemId] case final item?)
              Positioned(
                top: block.top,
                // 留 1 像素缝：相邻两块的边框紧贴会看起来像一整块。
                height: (block.height - 1).clamp(1, double.infinity),
                left: 0,
                right: 0,
                child: FractionallySizedBox(
                  // **横向定位用 Alignment，不用 Padding**：这一层拿不到列宽，
                  // 用像素化的 left 偏移就等于凭空猜一个宽度（我第一版就是这么错的）。
                  // FractionallySizedBox 负责宽度，Alignment 负责它在剩余空间里的位置。
                  alignment: Alignment(-1 + 2 * block.leftFraction, 0),
                  widthFactor: block.widthFraction,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: _TimelineCard(
                      item: item,
                      startMinute: ranges[item.id]!.start,
                      endMinute: ranges[item.id]!.end,
                      formatTime: (value) => _hhmm(_local(value)),
                      onTap: onOpenItem == null
                          ? null
                          : () => onOpenItem!(item),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

String _hhmm(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

/// 把"当天第几分钟"变成一个可格式化的时刻。
///
/// 日期取一个固定值：时间轴只画时分，日期由**列**决定，因此这里不能也不需要知道是哪天。
DateTime _clockAt(int minute) =>
    DateTime.utc(2000).add(Duration(minutes: minute));

/// 时间轴上的一张卡片。
final class _TimelineCard extends StatelessWidget {
  const _TimelineCard({
    required this.item,
    required this.startMinute,
    required this.endMinute,
    required this.formatTime,
    this.onTap,
  });

  final ScheduleViewItem item;
  final int startMinute;
  final int endMinute;
  final String Function(DateTime value) formatTime;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 与紧凑模式共用同一个派生器：同一事项在四个视图里必须逐值同色。
    final visual = scheduleCategoryCardStyle(item.categoryColor);
    final timeLabel =
        '${formatTime(_clockAt(startMinute))}–${formatTime(_clockAt(endMinute))}';

    final card = Container(
      key: ValueKey('week-timeline-card-${item.id}'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: visual.fill,
        border: Border.all(color: visual.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左侧强调条：与今日页、紧凑模式同一视觉语言。
          SizedBox(width: 3, child: ColoredBox(color: visual.accent)),
          Expanded(
            // **按量到的实际高度决定放几行**（§9："短任务保持最小可点击高度"）。
            //
            // 这不是过度设计：150% 缩放下"标题 + 起止时间"两行需要约 47 像素，而最短的卡片
            // 只有 44 像素高（最小高度 18 已按缩放放大），于是 `Column` 会溢出 8 像素——
            // 实测过，报的是 `A RenderFlex overflowed by 8.0 pixels on the bottom`。
            // 一个"越放大越用不了"的时间轴不算可操作（§9 退出条件）。
            //
            // 兜底不放信息：时间在 Tooltip 里始终完整，标题仍以省略号显示。
            child: LayoutBuilder(
              builder: (context, constraints) {
                // **卡片内限制文本缩放上限**（§9："短任务保持最小可点击高度"）。
                //
                // 这不是"无视无障碍设置"，而是这道布局的硬约束：一张 15 分钟的卡片只有几十像素高，
                // 150% 缩放下单是标题一行就要约 24 像素，两行加内边距需要约 47——**无论怎么排版都放不下**
                // （实测 `A RenderFlex overflowed by 8.0 pixels`）。取舍是这样的：
                // · 整页其余部分（列头、图例、切换、详情页）**照常跟随系统缩放**，该放大的都放大了；
                // · 只有这几十字高的卡片把缩放**封顶**，否则"越放大越看不全"，反而更不可用。
                // 封顶值 1.3：再高就开始溢出，低于它就正常放大。
                final scale = MediaQuery.textScalerOf(context).scale(1);
                final capped = MediaQuery.textScalerOf(context)
                    .clamp(maxScaleFactor: 1.3);
                final showRange = constraints.maxHeight >= 30 * scale;
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: capped),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // §9：长标题**限行数**，完整标题通过 Tooltip 或详情查看。
                        Tooltip(
                          message: '${item.title}\n$timeLabel',
                          child: Text(
                            item.title,
                            key: ValueKey('week-timeline-title-${item.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: PlannerPalette.textPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        // §9：同时显示**真实起止时间**——比例高度只是观感，精确时间必须文字给出。
                        // 卡片矮到放不下时让位给标题：时间在 Tooltip 里始终完整，不丢信息。
                        if (showRange)
                          Text(
                            timeLabel,
                            key: ValueKey('week-timeline-range-${item.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: PlannerPalette.textSecondary,
                              fontSize: 10,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );

    if (onTap == null) {
      return card;
    }
    return Semantics(
      button: true,
      label: '${item.title}，$timeLabel',
      child: InkWell(onTap: onTap, child: card),
    );
  }
}

/// 时间轴左侧的整点刻度。
final class TimelineHourAxis extends StatelessWidget {
  const TimelineHourAxis({required this.metrics, super.key});

  final TimelineMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final firstHour = (metrics.windowStartMinute / 60).ceil();
    final lastHour = (metrics.windowEndMinute / 60).floor();
    return SizedBox(
      height: metrics.contentHeight,
      width: 48,
      child: Stack(
        children: [
          for (var hour = firstHour; hour <= lastHour; hour++)
            Positioned(
              // 与卡片用**同一个** `topFor`，因此刻度与卡片不会错位。
              top: metrics.topFor(hour * 60),
              left: 0,
              right: 6,
              child: Align(
                alignment: Alignment.topRight,
                child: Text(
                  '${hour.toString().padLeft(2, '0')}:00',
                  style: const TextStyle(
                    color: PlannerPalette.textMuted,
                    fontSize: 10,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
