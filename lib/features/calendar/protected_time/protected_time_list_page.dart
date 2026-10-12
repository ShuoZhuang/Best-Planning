import 'package:flutter/material.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';

/// 「管理保护时间」：一份**能看的清单**，可以新建也可以删（计划 Task 8 的
/// `protected_time_list_page.dart`；规范 §9.1／§9.3）。
///
/// **为什么需要它**：周视图工具栏那颗按钮的标签是「管理保护时间」，
/// 而它此前直接打开**新建编辑器** —— 用户能看到"管"，却看不到"被管的东西"。
/// `CalendarService.deleteEvent` 对保护时间也一直没有界面入口，
/// 尽管规范 §9.3 要求"保护时间支持与固定日程相同的范围"（至少含删除）。
///
/// **只列保护时间**：固定日程有自己的入口；混在一起会让这个页面名不副实
/// （与本批次 §7.1"标签与动作必须一致"同一条口径）。
final class ProtectedTimeListPage extends StatefulWidget {
  const ProtectedTimeListPage({
    required this.service,
    required this.timeZoneId,
    required this.zones,
    required this.nowUtc,
    this.onManaged,
    this.onEditSeries,
    super.key,
  });

  final CalendarService service;
  final String timeZoneId;
  final TimeZoneDatabase zones;

  /// 读取窗口的起点。**由调用方给定**而不是让页面自己去问时钟：
  /// 页面不该依赖一个可变的全局时间源，测试也才能固定它
  /// （与全仓库"时区／时钟都从入口注入"的口径一致）。
  final DateTime nowUtc;

  /// 「新建保护时间」的去处。为空时**不显示该按钮**——不给点了没反应的入口。
  final VoidCallback? onManaged;

  /// 打开某个系列的编辑页（计划 §2.3：管理页编辑**默认修改整个系列**）。
  ///
  /// 入参是**锚点 id**：管理页一行就是一个系列，而系列的身份是它的锚点行
  /// （`calendar_events.id`），不是标题——按标题找会把两条同名的保护时间混成一条。
  ///
  /// 为空时不显示编辑入口，与 [onManaged] 同一条口径。
  final void Function(String anchorId)? onEditSeries;

  @override
  State<ProtectedTimeListPage> createState() => _ProtectedTimeListPageState();
}

final class _ProtectedTimeListPageState extends State<ProtectedTimeListPage> {
  /// 读取窗口：今天起 180 天。
  ///
  /// 取一个明确窗口而不是"全部"：`occurrencesBetween` 的契约就是窗口查询，
  /// 而保护时间通常按周重复、长期有效，180 天足以覆盖用户要管理的范围。
  static const _windowDays = 180;

  bool _loaded = false;
  String? _error;
  List<CalendarOccurrence> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final now = widget.nowUtc;
      final occurrences = await widget.service.occurrencesBetween(
        now,
        now.add(const Duration(days: _windowDays)),
      );
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = null;
        _entries = [
          for (final occurrence in occurrences)
            if (occurrence.kind == CalendarEventKind.protected) occurrence,
        ];
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = '读取保护时间失败：$error';
      });
    }
  }

  Future<void> _delete(CalendarOccurrence entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('protected-delete-dialog'),
        title: Text('删除「${entry.title}」？'),
        content: const Text('这段时间将不再被保护，任务可以被排进来。'),
        actions: [
          TextButton(
            key: const Key('protected-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('protected-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // **按返回结果说话**：删除失败时如实报出，而不是把它从列表里抹掉假装成功。
    final ok = await widget.service.deleteEvent(entry.eventId);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('这次删除没有成功，请重试。')));
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '管理保护时间',
                key: const Key('protected-list-title'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            if (widget.onManaged case final onManaged?)
              FilledButton.icon(
                key: const Key('protected-list-new'),
                onPressed: onManaged,
                icon: const Icon(Icons.add),
                label: const Text('新建保护时间'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '保护时间是排程的硬禁区：任务不会被排进这些时段。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Expanded(child: _body(context)),
      ],
    ),
  );

  Widget _body(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error case final message?) {
      return Center(
        child: Text(message, key: const Key('protected-list-error')),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          '接下来 $_windowDays 天里还没有保护时间。'
          '可以在设置里加长期规则，或用「新建保护时间」加一次性时段。',
          key: const Key('protected-list-empty'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return ListView(
      children: [
        for (final entry in _entries)
          ListTile(
            key: Key('protected-list-${entry.eventId}'),
            leading: const Icon(Icons.shield_outlined),
            title: Text(entry.title),
            subtitle: Text(_label(entry)),
            trailing: IconButton(
              key: Key('protected-delete-${entry.eventId}'),
              onPressed: () => _delete(entry),
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
            ),
          ),
      ],
    );
  }

  /// 按**事项自己的时区**显示（规范 §4.1：换算只在入口做一次）。
  String _label(CalendarOccurrence entry) {
    final start = widget.zones.toLocal(entry.range.startUtc, widget.timeZoneId);
    final end = widget.zones.toLocal(entry.range.endUtc, widget.timeZoneId);
    String two(int value) => value.toString().padLeft(2, '0');
    final sameDay =
        start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    final from =
        '${two(start.month)}-${two(start.day)} '
        '${two(start.hour)}:${two(start.minute)}';
    final to = sameDay
        ? '${two(end.hour)}:${two(end.minute)}'
        : '${two(end.month)}-${two(end.day)} '
              '${two(end.hour)}:${two(end.minute)}';
    return '$from – $to';
  }
}
