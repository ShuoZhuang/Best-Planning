import 'package:flutter/material.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

/// 日视图（FR-CAL-03）。
///
/// 与周视图共用同一个 `ScheduleViewSource`：它本身就是"任意区间的条目流"，因此日视图只需
/// 传一天的窗口，不必另造一套数据装配——两个视图看到的东西因此必然一致。
///
/// 与周视图的差别是**显示时间**：周视图的卡片只给类型与标题，而日视图的全部意义就在于
/// "这一天几点到几点做什么"，所以这里按本机时区把 UTC 区间换算成本地时刻展示（需求 §13）。
final class DayViewPage extends StatelessWidget {
  const DayViewPage({
    required this.source,
    required this.dayStartUtc,
    required this.zones,
    required this.timeZoneId,
    this.onOpenWeek,
    super.key,
  });

  final ScheduleViewSource source;

  /// 该日本地 00:00 对应的 UTC 时刻。
  final DateTime dayStartUtc;

  final TimeZoneDatabase zones;
  final String timeZoneId;

  /// 切回周视图。为空时不显示该按钮（例如未装配路由的测试场景）。
  final VoidCallback? onOpenWeek;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<ScheduleViewItem>>(
    stream: source.watch(
      dayStartUtc,
      dayStartUtc.add(const Duration(days: 1)),
    ),
    builder: (context, snapshot) {
      final localDay = zones.toLocal(dayStartUtc, timeZoneId);
      final items = [...?snapshot.data]
        ..sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${localDay.month} 月 ${localDay.day} 日',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                if (onOpenWeek != null)
                  TextButton.icon(
                    key: const Key('open-week-view'),
                    onPressed: onOpenWeek,
                    icon: const Icon(Icons.calendar_view_week_outlined),
                    label: const Text('查看本周'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (snapshot.hasError)
              Text('读取日程失败：${snapshot.error}')
            else if (!snapshot.hasData)
              const Center(child: CircularProgressIndicator())
            else if (items.isEmpty)
              // 空列表要说明"空"是什么意思：这一天确实没有安排，而不是功能坏了。
              const Text('这一天没有固定日程、保护时间或已确认的计划块。')
            else
              Expanded(
                child: ListView(
                  children: [
                    for (final item in items)
                      _DayItemTile(
                        item: item,
                        start: zones.toLocal(item.range.startUtc, timeZoneId),
                        end: zones.toLocal(item.range.endUtc, timeZoneId),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}

final class _DayItemTile extends StatelessWidget {
  const _DayItemTile({
    required this.item,
    required this.start,
    required this.end,
  });

  final ScheduleViewItem item;
  final DateTime start;
  final DateTime end;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: item.kind.color(scheme),
      child: ListTile(
        key: Key('day-item-${item.id}'),
        leading: Icon(item.kind.icon),
        title: Text(item.title),
        subtitle: Text(
          [
            // 类型用文字而不只是颜色：需求 §12 要求不能只靠颜色区分。
            '${_clock(start)}–${_clock(end)}',
            item.kind.label,
            ?item.explanation,
          ].join(' · '),
        ),
      ),
    );
  }

  static String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}
