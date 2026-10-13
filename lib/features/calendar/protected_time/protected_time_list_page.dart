import 'package:flutter/material.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/protected_time_series.dart';
import 'package:personal_planner/domain/repositories/protected_time_series_repository.dart';

/// 「管理保护时间」：用户自建的保护时间**系列清单**（规范 §9.1／§9.3；
/// 课程与保护时间管理修复计划 Task 6）。
///
/// ## 本轮改掉了什么
///
/// 页面此前读的是"未来 180 天的**展开结果**"，于是
///
/// - 一条"每周二健身"按发生次数出现 26 行（用户以为建了 26 条）；
/// - 180 天之外的系列**根本读不到**；
/// - 只能删，不能改（改名完全没有入口）。
///
/// 现在读的是**锚点行**：一行 = 一条用户建的系列，可以直接打开编辑。
///
/// **只列用户自建的那些**：睡眠／早餐／午餐／晚餐／固定休息来自
/// `PlanningRules.protectedTimes`，没有 `CalendarEvent` 锚点（计划 §2.3 末段），
/// 因此这份清单里不出现它们——那不是遗漏，是事实。
final class ProtectedTimeListPage extends StatefulWidget {
  const ProtectedTimeListPage({
    required this.reader,
    required this.timeZoneId,
    required this.zones,
    this.calendar,
    this.nowUtc,
    this.onManaged,
    this.onEditSeries,
    super.key,
  });

  /// 系列读模型（一条锚点一行）。
  final ProtectedTimeSeriesReader reader;

  /// 删除仍走日历服务：删的是锚点行本身。为空时不显示删除入口。
  final CalendarService? calendar;

  final String timeZoneId;
  final TimeZoneDatabase zones;

  /// 保留给"按今天高亮"之类展示用途；系列清单本身不依赖时钟。
  final DateTime? nowUtc;

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
  bool _loaded = false;
  String? _error;
  List<ProtectedTimeSeries> _series = const [];

  /// 是否把**已经结束**的系列也列出来（计划 Task 8 Step 2）。
  ///
  /// **默认关闭**：假期里打开管理页，上学期那几十条规则会把当前要改的那几条挤到屏幕外。
  /// 但它们不能被丢掉——"上学期那条周三的保护时间"是真实存在的记录，
  /// 而用户有时正是要去删掉它。因此开关放在这里，而不是直接过滤掉。
  bool _showEnded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final series = await widget.reader.listProtectedSeries();
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = null;
        _series = series;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = '读取保护时间失败：$error';
      });
    }
  }

  Future<void> _delete(ProtectedTimeSeries series) async {
    final calendar = widget.calendar;
    if (calendar == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('protected-delete-dialog'),
        title: Text('删除「${series.title}」？'),
        content: Text(
          series.repeats
              ? '这会删掉整条重复规则。这段时间将不再被保护，任务可以被排进来。'
              : '这段时间将不再被保护，任务可以被排进来。',
        ),
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
    final ok = await calendar.deleteEvent(series.anchorId);
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
        Row(
          children: [
            Expanded(
              child: Text(
                '保护时间是排程的硬禁区：任务不会被排进这些时段。'
                '每条规则只列一行，改一条就是改整个系列。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            // **默认关闭，但不隐藏**：看不见的开关等于没有这个能力。
            //
            // 用 `Switch` 而不是 `SwitchListTile`：后者要一张铺满宽度的列表行才能布局，
            // 而这里它必须与说明文字**并列**——放进 `Row` 里会得到无界宽度并直接抛
            // `BoxConstraints forces an infinite width`（实测如此）。
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  key: const Key('protected-show-ended'),
                  value: _showEnded,
                  onChanged: (value) => setState(() => _showEnded = value),
                ),
                const Text('显示已结束'),
              ],
            ),
          ],
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
    if (_series.isEmpty) {
      return Center(
        child: Text(
          '还没有自定义保护时间。'
          '可以在设置里加长期规则，或用「新建保护时间」加一次性时段。',
          key: const Key('protected-list-empty'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    // **按"今天"过滤已结束的那些**（计划 Task 8 Step 2）。时区用页面自己的，
    // 与展示其余部分同一口径——混用两个时区会让"已结束"的边界日差一天。
    final today = widget.zones.toLocal(
      widget.nowUtc ?? DateTime.now().toUtc(),
      widget.timeZoneId,
    );
    final visible = [
      for (final series in _series)
        if (_showEnded || !series.endedBefore(today)) series,
    ];

    if (visible.isEmpty) {
      // **空状态要说清"东西去哪了"**：直接显示"还没有自定义保护时间"会让用户
      // 以为规则被删了——而它们只是都结束了。
      return Center(
        child: Text(
          '当前没有进行中的保护时间。'
          '打开上面的「显示已结束」可以看到已经结束的 ${_series.length} 条。',
          key: const Key('protected-list-all-ended'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return ListView(
      children: [for (final series in visible) _tile(context, series)],
    );
  }

  Widget _tile(BuildContext context, ProtectedTimeSeries series) {
    final onEdit = widget.onEditSeries;
    return ListTile(
      // **一行一个系列**：key 用锚点 id，测试与"点哪一行"都落在这个身份上。
      key: Key('protected-series-${series.anchorId}'),
      leading: const Icon(Icons.shield_outlined),
      title: Text(series.title),
      subtitle: Text(_label(series)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onEdit != null)
            IconButton(
              key: Key('protected-edit-${series.anchorId}'),
              onPressed: () => onEdit(series.anchorId),
              icon: const Icon(Icons.edit_outlined),
              // **语义标签里带上标题**（计划 §Global Constraints："非空语义标签"）：
              // 只说"编辑"的按钮，读屏用户不知道自己在改哪一条。
              tooltip: '编辑「${series.title}」',
            ),
          if (widget.calendar != null)
            IconButton(
              key: Key('protected-delete-${series.anchorId}'),
              onPressed: () => _delete(series),
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除「${series.title}」',
            ),
        ],
      ),
    );
  }

  /// 按**事项自己的时区**显示（规范 §4.1：换算只在入口做一次）。
  ///
  /// 这条路径**不再做 UTC 换算**：系列读模型给的就是本地分钟与本地日期，
  /// 再换一次只会在夏令时切换日引入第二个真相。
  String _label(ProtectedTimeSeries series) {
    final clock = '${_hhmm(series.startMinute)}–${_hhmm(series.endMinute)}';
    final until = series.validUntilLocalDate;
    final span = until == null
        ? '${_date(series.validFromLocalDate)} 起'
        : '${_date(series.validFromLocalDate)} – ${_date(until)}';
    if (!series.repeats) return '$span $clock（单次）';
    final days = (series.weekdays.toList()..sort())
        .map(_weekdayLabel)
        .join('、');
    final cadence = series.intervalWeeks == 2 ? '隔周' : '每周';
    return '$span $cadence$days $clock';
  }

  static String _hhmm(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';

  static String _date(DateTime value) =>
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static String _weekdayLabel(int weekday) => switch (weekday) {
    DateTime.monday => '周一',
    DateTime.tuesday => '周二',
    DateTime.wednesday => '周三',
    DateTime.thursday => '周四',
    DateTime.friday => '周五',
    DateTime.saturday => '周六',
    DateTime.sunday => '周日',
    _ => '周?',
  };
}
