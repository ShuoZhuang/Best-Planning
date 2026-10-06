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
    this.onDeleteFollowing,
    this.onReplaceOccurrence,
    this.onReplaceFollowing,
    this.onReplaceSeries,
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

  final Future<bool> Function(String eventId, DateTime occurrenceStartUtc)?
  onDeleteFollowing;

  /// **改写**某一次（FR-CAL-02 的"修改单次实例"）。为空时不显示该按钮。
  ///
  /// 交回的是**本地时刻**：与 `onDeleteOccurrence` 同理，页面不做时区换算，换算由注入方
  /// （持有 `TimeZoneDatabase` 的路由）负责。单次日程与重复日程在这一层的表现相同，"改这一次"
  /// 与"改整条"是否等价由仓储按数据判断。
  final Future<bool> Function(
    String eventId,
    DateTime occurrenceStartUtc,
    DateTime newStartUtc,
    DateTime newEndUtc,
    String title,
  )?
  onReplaceOccurrence;

  final Future<bool> Function(
    String eventId,
    DateTime occurrenceStartUtc,
    DateTime newStartUtc,
    DateTime newEndUtc,
  )?
  onReplaceFollowing;

  /// 改写**整个系列**（FR-CAL-02 的"整个系列"编辑）。为空时对话框里不出现该选项。
  ///
  /// 与 [onReplaceOccurrence] 分成两个回调而不是加一个布尔参数：两条路径**写入的东西不同**
  /// （一条写例外，一条改锚点与规则），分开后各自的契约与用例也更清楚。
  final Future<bool> Function(
    String eventId,
    DateTime newStartUtc,
    DateTime newEndUtc,
  )?
  onReplaceSeries;

  final VoidCallback? onOpenWeek;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<ScheduleViewItem>>(
    stream: source.watch(dayStartUtc, dayStartUtc.add(const Duration(days: 1))),
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
                child: ListView.separated(
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: scheduleItemGap),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    // 只对**固定日程**开放删除与改写：保护时间是算出来的区间，任务块
                    // 属于计划。把条目 id 原样交给日程端口会删 0 行而不报错。
                    final eventId = fixedEventId(item);
                    return Row(
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
                        // 两个图标位**对每个条目都在**，只是不可用时变暗且点不动。
                        //
                        // 为什么不做成"不可用就不显示"：那样只有固定日程带图标，其余卡片
                        // 右边空着，同一列里宽窄参差（用户报的就是这个）。图标位的宽度
                        // 因此必须与可用性无关。
                        if (onDeleteEvent != null)
                          IconButton(
                            key: Key('delete-${item.id}'),
                            tooltip: eventId == null ? '只有固定日程可以删除' : '删除这条日程',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: eventId == null
                                ? null
                                : () => _confirmDelete(
                                    context,
                                    item,
                                    eventId: eventId,
                                    onDeleteEvent: onDeleteEvent,
                                    onDeleteOccurrence: onDeleteOccurrence,
                                    onDeleteFollowing: onDeleteFollowing,
                                  ),
                          ),
                        if (onReplaceOccurrence != null)
                          IconButton(
                            key: Key('edit-${item.id}'),
                            tooltip: eventId == null ? '只有固定日程可以改写' : '改这一次',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: eventId == null
                                ? null
                                : () => _editOccurrence(
                                    context,
                                    item,
                                    eventId: eventId,
                                    onReplaceOccurrence: onReplaceOccurrence,
                                    onReplaceFollowing: onReplaceFollowing,
                                    onReplaceSeries: onReplaceSeries,
                                    zones: zones,
                                    timeZoneId: timeZoneId,
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
    },
  );
}

/// 改写某一次的对话框：两个文本框（本地时刻），保存时把解析结果交给注入的回调。
///
/// 用文本框而不是日期/时间选择器：**格式与事件编辑器一致**（`YYYY-MM-DD HH:mm`），用户在两个
/// 地方看到同一种写法；也让这条路径能在测试里被直接驱动。
Future<void> _editOccurrence(
  BuildContext context,
  ScheduleViewItem item, {
  required String eventId,
  required Future<bool> Function(
    String eventId,
    DateTime occurrenceStartUtc,
    DateTime newStartUtc,
    DateTime newEndUtc,
    String title,
  )?
  onReplaceOccurrence,
  required Future<bool> Function(
    String eventId,
    DateTime occurrenceStartUtc,
    DateTime newStartUtc,
    DateTime newEndUtc,
  )?
  onReplaceFollowing,
  required Future<bool> Function(
    String eventId,
    DateTime newStartUtc,
    DateTime newEndUtc,
  )?
  onReplaceSeries,
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) async {
  final result = await showDialog<(DateTime, DateTime, _OccurrenceScope)>(
    context: context,
    // 控制器由对话框**自己**持有并释放。在 `showDialog` 返回后立刻 dispose 会在退出动画
    // 期间触发 "A TextEditingController was used after being disposed"——本文件第一版正是
    // 这样写的，五条既有用例一起把它顶了出来。
    builder: (dialogContext) => _OccurrenceEditDialog(
      title: item.title,
      initialStart: _formatLocal(item.range.startUtc, zones, timeZoneId),
      initialEnd: _formatLocal(item.range.endUtc, zones, timeZoneId),
      allowsFollowing: onReplaceFollowing != null,
      allowsWholeSeries: onReplaceSeries != null,
    ),
  );
  if (result == null) return;
  final (start, end, scope) = result;
  if (scope == _OccurrenceScope.series) {
    await onReplaceSeries!(eventId, start, end);
    return;
  }
  if (scope == _OccurrenceScope.following) {
    await onReplaceFollowing!(eventId, item.range.startUtc, start, end);
    return;
  }
  await onReplaceOccurrence!(
    eventId,
    item.range.startUtc,
    start,
    end,
    item.title,
  );
}

enum _OccurrenceScope { single, following, series }

/// "改这一次"的对话框：两个文本框（本地时刻），保存时把解析结果交回调用方。
///
/// 用文本框而不是日期/时间选择器：**格式与事件编辑器一致**（`YYYY-MM-DD HH:mm`），用户在两个
/// 地方看到同一种写法；也让这条路径能在测试里被直接驱动。
final class _OccurrenceEditDialog extends StatefulWidget {
  const _OccurrenceEditDialog({
    required this.title,
    required this.initialStart,
    required this.initialEnd,
    this.allowsFollowing = false,
    this.allowsWholeSeries = false,
  });

  final String title;
  final String initialStart;
  final String initialEnd;
  final bool allowsFollowing;

  /// 是否允许选"改整个系列"。未注入对应回调时为 false——**不给一个选了也不生效的勾选框**。
  final bool allowsWholeSeries;

  @override
  State<_OccurrenceEditDialog> createState() => _OccurrenceEditDialogState();
}

final class _OccurrenceEditDialogState extends State<_OccurrenceEditDialog> {
  late final TextEditingController _start;
  late final TextEditingController _end;
  String? _error;
  _OccurrenceScope _scope = _OccurrenceScope.single;

  @override
  void initState() {
    super.initState();
    _start = TextEditingController(text: widget.initialStart);
    _end = TextEditingController(text: widget.initialEnd);
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _save() {
    final start = _parseLocalDateTime(_start.text);
    final end = _parseLocalDateTime(_end.text);
    // **在对话框内校验**：解析失败或结束不晚于开始时留在对话框里说明，而不是把非法输入交给
    // 下游、让用户在外面收到一个更含糊的错误。
    if (start == null || end == null) {
      setState(() => _error = '时间格式应为 YYYY-MM-DD HH:mm');
      return;
    }
    if (!end.isAfter(start)) {
      setState(() => _error = '结束时间必须晚于开始时间');
      return;
    }
    Navigator.of(context).pop((start, end, _scope));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('改「${widget.title}」的这一次'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('occurrence-start'),
          controller: _start,
          decoration: const InputDecoration(
            labelText: '开始（本地，如 2026-10-12 14:00）',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('occurrence-end'),
          controller: _end,
          decoration: const InputDecoration(labelText: '结束（本地）'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (widget.allowsFollowing || widget.allowsWholeSeries) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const Key('occurrence-scope-single'),
                label: const Text('仅本次'),
                selected: _scope == _OccurrenceScope.single,
                onSelected: (_) =>
                    setState(() => _scope = _OccurrenceScope.single),
              ),
              if (widget.allowsFollowing)
                ChoiceChip(
                  key: const Key('occurrence-scope-following'),
                  label: const Text('本次及以后'),
                  selected: _scope == _OccurrenceScope.following,
                  onSelected: (_) =>
                      setState(() => _scope = _OccurrenceScope.following),
                ),
              if (widget.allowsWholeSeries)
                ChoiceChip(
                  key: const Key('occurrence-scope-series'),
                  label: const Text('整个系列'),
                  selected: _scope == _OccurrenceScope.series,
                  onSelected: (_) =>
                      setState(() => _scope = _OccurrenceScope.series),
                ),
            ],
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        key: const Key('occurrence-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      TextButton(
        key: const Key('occurrence-save'),
        onPressed: _save,
        child: const Text('保存'),
      ),
    ],
  );
}

/// 把 UTC 时刻按**应用时区**格式化成预填文本。
///
/// 刻意不用 `DateTime.toLocal()`：那走的是**系统**时区，而列表本身按应用解析出的 `timeZoneId`
/// 显示。两者不一致时，预填文本会与用户看到的时刻差一个偏移，保存后又会再偏一次。
String _formatLocal(
  DateTime instantUtc,
  TimeZoneDatabase zones,
  String timeZoneId,
) {
  final local = zones.toLocal(instantUtc, timeZoneId);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

DateTime? _parseLocalDateTime(String raw) {
  final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})$')
      .firstMatch(raw.trim());
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
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
  required String eventId,
  required Future<bool> Function(String eventId)? onDeleteEvent,
  required Future<bool> Function(
    String eventId,
    DateTime occurrenceStartUtc,
    String title,
  )?
  onDeleteOccurrence,
  required Future<bool> Function(String eventId, DateTime occurrenceStartUtc)?
  onDeleteFollowing,
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
        if (onDeleteFollowing != null)
          TextButton(
            key: const Key('delete-following-occurrences'),
            onPressed: () => Navigator.of(dialogContext).pop('following'),
            child: const Text('本次及以后'),
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
    await onDeleteOccurrence!(eventId, item.range.startUtc, item.title);
  } else if (choice == 'following') {
    await onDeleteFollowing!(eventId, item.range.startUtc);
  } else if (choice == 'entire') {
    await onDeleteEvent!(eventId);
  }
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
      color: item.color(scheme),
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
