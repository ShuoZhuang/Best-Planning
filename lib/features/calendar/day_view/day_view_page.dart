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
    this.onDeleteEvent,
    this.onDeleteOccurrence,
    super.key,
  });

  final ScheduleViewSource source;

  /// 该日本地 00:00 对应的 UTC 时刻。
  final DateTime dayStartUtc;

  final TimeZoneDatabase zones;
  final String timeZoneId;

  /// 切回周视图。为空时不显示该按钮（例如未装配路由的测试场景）。
  /// 删除这条日程（FR-CAL-01）。为空时不显示删除按钮。
  ///
  /// **页面不认识仓储**：它只把条目 id 交回，删除与随后的刷新由注入方负责——与
  /// `onOpenWeek` 同理。为空时整块不渲染，而不是给一个点了没反应的图标。
  final Future<bool> Function(String eventId)? onDeleteEvent;

  /// 只删除重复日程的**某一次**（FR-CAL-02）。为空时对话框里不出现"只删这一次"。
  ///
  /// 页面只交出条目 id、这次出现的起点与标题：判定"是不是重复日程"、以及例外的时区都由
  /// 仓储负责（它才摸得到规则行）。标题随回调带上，是因为写入的例外行就是一条日程记录。
  final Future<bool> Function(
    String eventId,
    DateTime occurrenceStartUtc,
    String title,
  )?
  onDeleteOccurrence;

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
                      // 删除按钮放在卡片**外面**而不是 `_DayItemTile` 里面：这样不必给
                      // 展示用的子控件增加一个只为删除而存在的参数，卡片也不必知道删除。
                      Row(
                        children: [
                          Expanded(
                            child: _DayItemTile(
                              item: item,
                              start: zones.toLocal(
                                item.range.startUtc,
                                timeZoneId,
                              ),
                              end: zones.toLocal(item.range.endUtc, timeZoneId),
                            ),
                          ),
                          if (onDeleteEvent != null)
                            IconButton(
                              key: Key('delete-${item.id}'),
                              tooltip: '删除这条日程',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _confirmDelete(
                                context,
                                item,
                                onDeleteEvent: onDeleteEvent,
                                onDeleteOccurrence: onDeleteOccurrence,
                              ),
                            ),
                        ],
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

/// 删除日程前问清"只删这一次"还是"删除整条／整个系列"。
///
/// **为什么要问**：这两件事在数据上完全不同——"这一次"会写一条零长度的例外行，系列的其它各次
/// 保留；"整条"会删掉锚点行，重复日程的**所有**出现随之消失。而删除**不可逆**，用一句话把两种
/// 后果说清楚，比事后让用户困惑要好。单次日程两种选择结果相同，正文里已说明。
///
/// 页面不认识仓储：它只把条目 id、起点与标题交回注入的回调，判定与换算都在仓储侧。
Future<void> _confirmDelete(
  BuildContext context,
  ScheduleViewItem item, {
  required Future<bool> Function(String eventId)? onDeleteEvent,
  required Future<bool> Function(
    String eventId,
    DateTime occurrenceStartUtc,
    String title,
  )?
  onDeleteOccurrence,
}) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('删除「${item.title}」'),
      content: const Text(
        '重复日程：只删这一次会保留其它各次；删除整条会连同整个系列一起删除。\n'
        '单次日程：两种选择结果相同。',
      ),
      actions: [
        TextButton(
          key: const Key('delete-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        if (onDeleteOccurrence != null)
          TextButton(
            key: const Key('delete-this-occurrence'),
            onPressed: () => Navigator.of(dialogContext).pop('occurrence'),
            child: const Text('只删这一次'),
          ),
        TextButton(
          key: const Key('delete-entire'),
          onPressed: () => Navigator.of(dialogContext).pop('entire'),
          child: const Text('删除整条'),
        ),
      ],
    ),
  );
  if (choice == 'occurrence') {
    await onDeleteOccurrence!(
      item.id,
      item.range.startUtc,
      item.title,
    );
  } else if (choice == 'entire') {
    await onDeleteEvent!(item.id);
  }
}

final class _DayItemTile extends StatelessWidget {  const _DayItemTile({
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
