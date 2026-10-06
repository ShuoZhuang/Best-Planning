import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_glass.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/time_range.dart';
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
                        explanation: item.explanation,
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
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 960;
                    final timeline = _TimelinePanel(
                      items: items,
                      formatTime: formatTime,
                    );
                    final summary = _PlanningRail(
                      items: items,
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
      const _Legend(),
    ],
  );
}

/// 图例：**按类型**列出今天的颜色含义，与卡片取色同一套口径。
///
/// 曾短暂改成"按领域 + 保护"着色（领域色由 `areas.color` 提供），但整屏卡片各按领域上色后
/// 观感明显变差，用户要求恢复到原来的按类型着色，图例因此一并回到四项。
///
/// 注：第三项的"可移动任务"沿用旧文案，而任务的类型标签其实是"任务"——两者不一致是历史遗留，
/// 与配色无关，因此这次原样保留，避免借着"恢复配色"顺手改文案。
final class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 6,
    children: const [
      _LegendItem(color: PlannerPalette.accent, label: '固定'),
      _LegendItem(color: PlannerPalette.positive, label: '保护'),
      _LegendItem(color: PlannerPalette.warning, label: '可移动任务'),
      _LegendItem(color: Color(0xffb391d3), label: '生活'),
    ],
  );
}

final class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
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
    final tone = _toneFor(item.kind);
    return Semantics(
      label:
          '${item.title}，${item.kind.label}，${formatTime(item.range.startUtc)}到${formatTime(item.range.endUtc)}',
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
                      color: tone,
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
                margin: const EdgeInsets.only(bottom: 10),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.10),
                  border: Border.all(color: PlannerPalette.outline),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Container(width: 3, color: tone),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(item.kind.icon, size: 18, color: tone),
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
                                    '${formatTime(item.range.startUtc)}–${formatTime(item.range.endUtc)} · ${item.kind.label}',
                                    style: const TextStyle(
                                      color: PlannerPalette.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
  const _PlanningRail({required this.items, required this.formatTime});

  final List<ScheduleViewItem> items;
  final String Function(DateTime value) formatTime;

  @override
  Widget build(BuildContext context) {
    final current = _currentOrNext(items);
    final totalMinutes = items.fold<int>(
      0,
      (sum, item) => sum + item.range.durationMinutes,
    );
    final fixedMinutes = items
        .where((item) => item.kind == ScheduleItemKind.fixed)
        .fold<int>(0, (sum, item) => sum + item.range.durationMinutes);
    final protectedMinutes = items
        .where((item) => item.kind == ScheduleItemKind.protectedTime)
        .fold<int>(0, (sum, item) => sum + item.range.durationMinutes);
    final flexibleMinutes = totalMinutes - fixedMinutes - protectedMinutes;

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
                        color: _toneFor(current.kind),
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
                    '${formatTime(current.range.startUtc)}–${formatTime(current.range.endUtc)} · ${current.kind.label}',
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
                _CapacityBar(
                  fixed: fixedMinutes,
                  protectedTime: protectedMinutes,
                  flexible: flexibleMinutes,
                ),
                const SizedBox(height: 14),
                _MetricRow(
                  label: '固定日程',
                  value: _durationText(fixedMinutes),
                  color: PlannerPalette.accent,
                ),
                const SizedBox(height: 8),
                _MetricRow(
                  label: '保护时间',
                  value: _durationText(protectedMinutes),
                  color: PlannerPalette.positive,
                ),
                const SizedBox(height: 8),
                _MetricRow(
                  label: '任务与生活',
                  value: _durationText(flexibleMinutes),
                  color: PlannerPalette.warning,
                ),
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
  const _CapacityBar({
    required this.fixed,
    required this.protectedTime,
    required this.flexible,
  });

  final int fixed;
  final int protectedTime;
  final int flexible;

  @override
  Widget build(BuildContext context) {
    final total = fixed + protectedTime + flexible;
    if (total == 0) {
      return Container(
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
        height: 7,
        child: Row(
          children: [
            if (fixed > 0)
              Expanded(
                flex: fixed,
                child: const ColoredBox(color: PlannerPalette.accent),
              ),
            if (protectedTime > 0)
              Expanded(
                flex: protectedTime,
                child: const ColoredBox(color: PlannerPalette.positive),
              ),
            if (flexible > 0)
              Expanded(
                flex: flexible,
                child: const ColoredBox(color: PlannerPalette.warning),
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

Color _toneFor(ScheduleItemKind kind) => switch (kind) {
  ScheduleItemKind.fixed => PlannerPalette.accent,
  ScheduleItemKind.protectedTime => PlannerPalette.positive,
  ScheduleItemKind.task => PlannerPalette.warning,
  ScheduleItemKind.life => const Color(0xffb391d3),
};

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
