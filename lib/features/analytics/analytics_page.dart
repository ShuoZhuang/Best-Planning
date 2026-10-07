import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/application/feedback_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/area_period_matrix.dart';
import 'package:personal_planner/domain/models/chart_kind.dart';
import 'package:personal_planner/domain/models/feedback_message.dart';
import 'package:personal_planner/design/planner_pickers.dart';
import 'package:personal_planner/features/analytics/chart_view.dart';
import 'package:personal_planner/features/analytics/feedback_cards.dart';

final class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({
    required this.analytics,
    required this.nowUtc,
    // 必填：统计的"今天／本周／本月"必须是**用户本机时区**的日界。此前这里按 UTC 取日界
    // （`DateTime.utc(now.year, now.month, now.day)`），于是对东八区用户在本地 00:00–08:00
    // 之间打开统计页，"今天"会落到**前一天**；需求 §13 与 R11 要求的正是"以本机当前时区
    // 保存和展示"。与 R11 那几处同类默认值一样，改为必填后"忘记传"是编译错误，而不是在
    // 别的时区静默算错一天。
    required this.zones,
    required this.timeZoneId,
    this.feedbackMessages = const [],
    this.loadTagNames,
    this.loadChartKinds,
    this.saveChartKind,
    super.key,
  });

  final AnalyticsQuery analytics;
  final DateTime nowUtc;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final List<FeedbackMessage> feedbackMessages;

  /// 读取可筛选的标签名；为空时不显示标签筛选。
  ///
  /// 由外部注入而不是让统计页自己去查标签表：统计页只需要"可以按哪些标签筛选"，
  /// 不需要知道标签存在哪里。为空时整块不渲染，而不是给一个空的下拉。
  final Future<Set<String>> Function()? loadTagNames;

  /// 读取用户为每张卡片选过的图表类型；为空时全部用默认类型。
  final Future<Map<AnalyticsChartSlot, ChartKind>> Function()? loadChartKinds;

  /// 保存某张卡片的图表类型选择。为空时选择只在本次会话内生效
  /// （测试与最小装配不必带持久化）。
  final Future<void> Function(AnalyticsChartSlot slot, ChartKind kind)?
  saveChartKind;

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

final class _AnalyticsPageState extends State<AnalyticsPage> {
  late AnalyticsFilter _filter;
  AnalyticsReport? _report;
  Object? _error;
  bool _loading = true;
  Set<String> _availableTags = const {};

  /// 「领域 × 周期」矩阵：上周 / 本周 / 本月各自的**计划块**时长，按领域成行。
  ///
  /// 它的周期是**固定的**三个，不随上面的范围选择变化——用户要的是"领域时间分配的横向纵向
  /// 对比"（FR-STAT 的横向＝领域之间、纵向＝周期之间），一个固定基准比一个跟着筛选器漂的表格
  /// 更能回答这个问题。标签筛选仍然生效（周期只换时间窗，不换筛选条件）。
  AreaPeriodMatrix? _matrix;

  /// 用户为每张卡片选过的图表类型。没选过的位置由 `resolveChartKind` 补默认值。
  Map<AnalyticsChartSlot, ChartKind> _chartKinds = const {};

  /// 某张卡片当前该用哪种图型。
  ChartKind _kindOf(AnalyticsChartSlot slot) =>
      resolveChartKind(slot, _chartKinds);

  /// 换一张卡片的图型：**先落界面再持久化**。
  ///
  /// 顺序是刻意的：写设置可能失败（磁盘满、文件被占），而"点了一下没反应"比"选择没被记住"
  /// 更让人困惑。持久化失败只丢一次记忆，不该回滚用户已经看到的界面。
  Future<void> _setChartKind(AnalyticsChartSlot slot, ChartKind kind) async {
    setState(() => _chartKinds = {..._chartKinds, slot: kind});
    try {
      await widget.saveChartKind?.call(slot, kind);
    } on Object {
      // 记忆失败不影响本次选择已经生效。
    }
  }

  Future<void> _loadChartKinds() async {
    final loader = widget.loadChartKinds;
    if (loader == null) return;
    final kinds = await loader();
    if (!mounted) return;
    setState(() => _chartKinds = kinds);
  }

  /// 由**本页自己算出来**的温和反馈（FR-STAT-08 的呈现侧）。
  ///
  /// 此前 `FeedbackService.generate` 已完整实现（且有单测）却**全库无人调用**，本页虽然接收
  /// `feedbackMessages` 并在有内容时渲染（渲染也有测试），但**没有任何生产者**，因此那一块
  /// **永远不显示**（见 §13.0 的 W10）。这里让页面用**已有的** `analytics` 查询自行取
  /// "紧邻其前的等长窗口"作对照，生产者因此不必穿透组合根四层。
  List<FeedbackMessage> _feedback = const [];

  @override
  void initState() {
    super.initState();
    final today = _todayLocalDate();
    _filter = AnalyticsFilter(
      startUtc: _localMidnight(today),
      endUtc: _localMidnight(_addDays(today, 1)),
    );
    _load();
    _loadTagNames();
    _loadChartKinds();
  }

  /// `nowUtc` 在**本机时区**下的日历日（只取年月日）。
  ///
  /// 用 `zones.toLocal` 而不是 `nowUtc.year/month/day`：后者拿到的是 **UTC** 的日期，
  /// 在 UTC+8 的凌晨会差一天。
  DateTime _todayLocalDate() {
    final local = widget.zones.toLocal(widget.nowUtc, widget.timeZoneId);
    return DateTime(local.year, local.month, local.day);
  }

  /// 本地日期的零点对应的 UTC 瞬时。
  DateTime _localMidnight(DateTime localDate) =>
      widget.zones.localMidnightToUtc(localDate, widget.timeZoneId);

  /// 按**日历**加减天数，而不是 `add(Duration(days: n))`。
  ///
  /// 后者是绝对时间加法：夏令时切换日的本地一天不是 24 小时，加 24 小时会回到当天 23:00，
  /// 日期不变——§13.0 的 C11 在保护时间展开器上记过同一处（"按日推进用了绝对时间加法"）。
  DateTime _addDays(DateTime localDate, int days) =>
      DateTime(localDate.year, localDate.month, localDate.day + days);

  Future<void> _loadTagNames() async {
    final loader = widget.loadTagNames;
    if (loader == null) return;
    final names = await loader();
    if (!mounted) return;
    setState(() => _availableTags = names);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // **顺序是刻意的**：先取对照窗口、再取矩阵的三个周期、最后取当前窗口。既有的 widget 测试
      // 以"最后一次查询即用户所选窗口"来断言筛选器（`filters.last`），把当前窗口放在最后可以
      // 不动那些断言。那里的位置耦合是既有事实，本处不新增耦合，但也不假装它不存在。
      final length = _filter.endUtc.difference(_filter.startUtc);
      final previous = await widget.analytics.query(
        AnalyticsFilter(
          startUtc: _filter.startUtc.subtract(length),
          endUtc: _filter.startUtc,
          areaIds: _filter.areaIds,
          projectIds: _filter.projectIds,
          tags: _filter.tags,
          statuses: _filter.statuses,
        ),
      );
      final matrix = await _loadAreaPeriodMatrix();
      final report = await widget.analytics.query(_filter);
      if (!mounted) return;
      setState(() {
        _report = report;
        _matrix = matrix;
        _feedback = const FeedbackService().generate(report, previous);
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 组装「领域 × 周期」矩阵：上周 / 本周 / 本月，各查一次。
  ///
  /// 周期边界一律走 [_localMidnight]（本机时区日界），与页面顶部那段口径说明一致——用 UTC 日界
  /// 会让"周一"在 UTC+8 偏一天。周一为一周之始，与 `_selectWeek` 同一规则。
  Future<AreaPeriodMatrix> _loadAreaPeriodMatrix() async {
    final today = _todayLocalDate();
    final monday = _addDays(today, -(today.weekday - 1));
    final periods = <({String label, AnalyticsFilter filter})>[
      (label: '上周', filter: _rangeFilter(_addDays(monday, -7), monday)),
      (label: '本周', filter: _rangeFilter(monday, _addDays(monday, 7))),
      (
        label: '本月',
        filter: _rangeFilter(
          DateTime(today.year, today.month),
          DateTime(today.year, today.month + 1),
        ),
      ),
    ];

    final reports = <({String label, AnalyticsReport report})>[];
    for (final period in periods) {
      reports.add((
        label: period.label,
        report: await widget.analytics.query(period.filter),
      ));
    }
    return buildAreaPeriodMatrix(reports);
  }

  /// 只换时间窗、**沿用当前筛选条件**（领域／项目／标签／状态）的区间。
  AnalyticsFilter _rangeFilter(
    DateTime localStart,
    DateTime localEndExclusive,
  ) => AnalyticsFilter(
    startUtc: _localMidnight(localStart),
    endUtc: _localMidnight(localEndExclusive),
    areaIds: _filter.areaIds,
    projectIds: _filter.projectIds,
    tags: _filter.tags,
    statuses: _filter.statuses,
  );

  /// 外部注入的 `feedbackMessages` 优先（测试与显式装配用），否则用本页按对照窗口算出的结果。
  List<FeedbackMessage> get _messages =>
      widget.feedbackMessages.isNotEmpty ? widget.feedbackMessages : _feedback;

  void _selectToday() {
    final today = _todayLocalDate();
    _setRange(_localMidnight(today), _localMidnight(_addDays(today, 1)));
  }

  void _selectWeek() {
    final today = _todayLocalDate();
    // 周一为一周之始；同样用日历加法退到周一。
    final monday = _addDays(today, -(today.weekday - 1));
    _setRange(_localMidnight(monday), _localMidnight(_addDays(monday, 7)));
  }

  void _selectMonth() {
    final today = _todayLocalDate();
    _setRange(
      _localMidnight(DateTime(today.year, today.month)),
      _localMidnight(DateTime(today.year, today.month + 1)),
    );
  }

  Future<void> _selectCustom() async {
    // 选择器显示的是**用户看到的本地日期**，因此预填值也要按本机时区换算，
    // 不能用 `_filter.startUtc.year`（那是 UTC 的分量，同样会差一天）。
    final localStart = widget.zones.toLocal(
      _filter.startUtc,
      widget.timeZoneId,
    );
    final localEnd = widget.zones.toLocal(
      _filter.endUtc.subtract(const Duration(microseconds: 1)),
      widget.timeZoneId,
    );
    final selected = await showDateRangePicker(
      builder: plannerPickerBuilder,
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(
        start: DateTime(localStart.year, localStart.month, localStart.day),
        end: DateTime(localEnd.year, localEnd.month, localEnd.day),
      ),
      helpText: '选择统计范围',
      cancelText: '取消',
      confirmText: '应用',
      // **全屏模式下确认按钮用的是 `saveText`，不是 `confirmText`**（`DateRangePickerDialog`
      // 在窄屏会走全屏形态）。不传它就只能拿 `MaterialLocalizations.saveButtonLabel`，
      // 而在没有中文本地化时那正是英文的 `Save`——2026-10-07 用户截图里那个按钮就是它。
      // 两个都传，两种形态才都是"应用"。
      saveText: '应用',
    );
    if (selected == null) return;
    _setRange(
      _localMidnight(
        DateTime(selected.start.year, selected.start.month, selected.start.day),
      ),
      // 用户选的末日**含当天**，因此终点取次日零点。
      _localMidnight(
        DateTime(selected.end.year, selected.end.month, selected.end.day + 1),
      ),
    );
  }

  void _setRange(DateTime start, DateTime end) {
    setState(() {
      // 换时间范围必须保留已选标签：两处都从现有 filter 出发，否则换一次范围就会把
      // 标签筛选悄悄丢掉，而界面上的标签看起来仍然是选中的。
      _filter = AnalyticsFilter(
        startUtc: start,
        endUtc: end,
        tags: _filter.tags,
      );
    });
    _load();
  }

  void _setTags(Set<String> tags) {
    setState(() {
      _filter = AnalyticsFilter(
        startUtc: _filter.startUtc,
        endUtc: _filter.endUtc,
        tags: tags,
      );
    });
    _load();
  }

  /// 多选是"同时满足"而不是"满足任意一个"，因此用集合而不是单选。
  void _toggleTag(String name) {
    final next = {..._filter.tags};
    if (!next.remove(name)) next.add(name);
    _setTags(next);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('统计与复盘')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  '看见时间去了哪里',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                // **这句话原本写的是"计划、实际投入和推断结论分别展示"**。2026-10-06 用户要求把
                // "实际"这一侧从统计里全部拿掉（"这个程序原先的本质就是计划，实际是什么没有统计
                // 必要"），因此口径说明必须跟着改——留着一句介绍用户看不到的东西，比没有介绍更糟。
                const Text('只看你计划了什么：固定日程、已确认的计划块、保护时间与完成情况。休息与娱乐同样是有价值的时间。'),
                const SizedBox(height: 18),
                _RangeControls(
                  filter: _filter,
                  onToday: _selectToday,
                  onWeek: _selectWeek,
                  onMonth: _selectMonth,
                  onCustom: _selectCustom,
                ),
                if (widget.loadTagNames != null) ...[
                  const SizedBox(height: 14),
                  _TagFilter(
                    available: _availableTags,
                    selected: _filter.tags,
                    onToggle: _toggleTag,
                    onClear: () => _setTags(const {}),
                  ),
                ],
                if (_loading) ...[
                  const SizedBox(height: 18),
                  const LinearProgressIndicator(),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 18),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('统计加载失败：$_error'),
                    ),
                  ),
                ],
                if (_report case final report?) ...[
                  const SizedBox(height: 22),
                  // **顺序即重点**（2026-10-06 用户确认的改版）：
                  //   ①② 领域时间分配——横向占比、纵向总计（用户的主诉求）
                  //   ③  我规划得合理吗——完成情况 + 领域覆盖缺口
                  //   ④  我有没有好好休息——休息时长、作息规律性、工作休息比例
                  //   ⑤  精力、中断与调整（FR-STAT-06，原样保留）
                  // "计划 vs 实际"整组已按用户要求移除，理由与口径偏离记在规格里。
                  _AreaShareSection(
                    report: report,
                    kind: _kindOf(AnalyticsChartSlot.areaShare),
                    onKind: (kind) =>
                        _setChartKind(AnalyticsChartSlot.areaShare, kind),
                  ),
                  const SizedBox(height: 20),
                  if (_matrix case final matrix?) ...[
                    _PeriodTotalSection(
                      matrix: matrix,
                      kind: _kindOf(AnalyticsChartSlot.periodTotal),
                      onKind: (kind) =>
                          _setChartKind(AnalyticsChartSlot.periodTotal, kind),
                    ),
                    const SizedBox(height: 20),
                  ],
                  _PlanQualitySection(report: report),
                  if (_messages.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    FeedbackCards(messages: _messages, filter: report.filter),
                  ],
                  const SizedBox(height: 20),
                  _RestSection(
                    report: report,
                    restKind: _kindOf(AnalyticsChartSlot.restDuration),
                    onRestKind: (kind) =>
                        _setChartKind(AnalyticsChartSlot.restDuration, kind),
                    workRestKind: _kindOf(AnalyticsChartSlot.workRest),
                    onWorkRestKind: (kind) =>
                        _setChartKind(AnalyticsChartSlot.workRest, kind),
                    routineKind: _kindOf(AnalyticsChartSlot.routine),
                    onRoutineKind: (kind) =>
                        _setChartKind(AnalyticsChartSlot.routine, kind),
                  ),
                  const SizedBox(height: 20),
                  _EvidenceLists(report: report),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

final class _TagFilter extends StatelessWidget {
  const _TagFilter({
    required this.available,
    required this.selected,
    required this.onToggle,
    required this.onClear,
  });

  final Set<String> available;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final names = available.toList()..sort();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '按标签筛选',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (selected.isNotEmpty)
                  TextButton(
                    key: const Key('analytics-clear-tags'),
                    onPressed: onClear,
                    child: const Text('清除标签筛选'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // 说清语义：多选是交集而不是并集，否则用户会以为多选等于"任一命中"。
            const Text('可多选：只有同时带上全部所选标签的任务才会被统计。'),
            const SizedBox(height: 12),
            if (names.isEmpty)
              // 空列表要说明原因与下一步，否则看起来像筛选功能坏了。
              const Text('尚无标签。在任务详情页给任务打上标签后，这里就能按标签筛选。')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final name in names)
                    FilterChip(
                      key: Key('analytics-tag-$name'),
                      label: Text(name),
                      selected: selected.contains(name),
                      onSelected: (_) => onToggle(name),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

final class _RangeControls extends StatelessWidget {
  const _RangeControls({
    required this.filter,
    required this.onToday,
    required this.onWeek,
    required this.onMonth,
    required this.onCustom,
  });

  final AnalyticsFilter filter;
  final VoidCallback onToday;
  final VoidCallback onWeek;
  final VoidCallback onMonth;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    final format = DateFormat('yyyy-MM-dd');
    final inclusiveEnd = filter.endUtc.subtract(const Duration(days: 1));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // **扩展点：将来加"学期"维度就加在这里（2026-10-04 登记）。**
            //
            // 用户原始需求里写着「统计范围可选今天／本周／本月／自定义，并**为以后增加学期维度
            // 预留空间**」，而规格 §17「后续路线」把「学期目标、考试周和假期模板」划在首版之外。
            // 因此这里**不实现**学期，但把"以后怎么加"写清楚，免得下一个做的人重新推一遍：
            //
            // 1. **服务层不需要改**：`AnalyticsFilter` 就是一对起止瞬时（`startUtc`／`endUtc`），
            //    今天／本周／本月／自定义走的都是同一个查询，因此学期只是**另一个区间**；
            // 2. **界面上加一个按钮**（与下面四个并列）→ 用学期起止算出区间 → 与 `onCustom` 同样
            //    的方式回调即可；**本机时区日界**必须沿用上面 `analytics_page.dart` 顶部那段说明
            //    里的口径（按用户本机时区的日界，而不是 UTC），否则"学期的第一天"会偏一天；
            // 3. **需要的新数据是"学期起止日期"**（外加考试周／假期模板）：本仓库现在**没有**
            //    这个概念，所以那一步要先在设置里落一个键（形如 `planning.term.v1`），
            //    并进 `input_snapshot_builder` 的哈希——否则改了学期不会触发计划重算；
            // 4. **在那之前，用户已经可以用「自定义范围」选中一个学期**：所以这不是功能缺口，
            //    只是"少一个一键预设"。这一判断同时写在 `docs/testing/original-requirements-audit.md`
            //    的第 ⑮ 条里。
            // **四个按钮都要有 key**：新增的「领域时间分配」矩阵表头里也有"上周／本周／本月"
            // 这几个字，按文本查找会命中多个控件——测试点不动，也不再唯一。
            OutlinedButton(
              key: const Key('analytics-range-today'),
              onPressed: onToday,
              child: const Text('今天'),
            ),
            OutlinedButton(
              key: const Key('analytics-range-week'),
              onPressed: onWeek,
              child: const Text('本周'),
            ),
            OutlinedButton(
              key: const Key('analytics-range-month'),
              onPressed: onMonth,
              child: const Text('本月'),
            ),
            FilledButton.tonal(
              key: const Key('analytics-range-custom'),
              onPressed: onCustom,
              child: const Text('自定义范围'),
            ),
            Text(
              '${format.format(filter.startUtc)} — '
              '${format.format(inclusiveEnd)}',
            ),
          ],
        ),
      ),
    );
  }
}

/// **① 横向：领域占比**——所选范围里各领域的时间占比。
///
/// 口径是"总占用"（计划块 + 固定日程）。用户 2026-10-06 的原话："领域时间分配为什么不把固定日程
/// 统计进去，有的固定日程不是也有领域的吗"——课表本来就有领域，此前数据集里根本没有日历事件，
/// 于是占比只统计任务计划块，把每周占大头的那部分漏掉了。
final class _AreaShareSection extends StatelessWidget {
  const _AreaShareSection({
    required this.report,
    required this.kind,
    required this.onKind,
  });

  final AnalyticsReport report;
  final ChartKind kind;
  final ValueChanged<ChartKind> onKind;

  @override
  Widget build(BuildContext context) {
    final distribution = [
      for (final item in report.domainDistribution)
        if (item.totalMinutes > 0) item,
    ];
    return _SectionCard(
      cardKey: const Key('analytics-area-share'),
      slot: AnalyticsChartSlot.areaShare,
      kind: kind,
      onKind: onKind,
      title: '领域占比',
      subtitle: '横向对比：所选范围里时间分给了哪些领域（含固定日程）',
      chart: AnalyticsChart(
        kind: kind,
        emptyLabel: '所选范围里还没有已确认的计划块或固定日程。',
        data: [
          for (var index = 0; index < distribution.length; index++)
            ChartDatum(
              label: distribution[index].label,
              value: distribution[index].totalMinutes,
              color: chartColorAt(index),
            ),
        ],
      ),
      footnote: distribution
          .map(
            (item) =>
                '${item.label} ${_minutes(item.totalMinutes)}'
                '（计划 ${item.plannedMinutes} 分钟 + '
                '固定日程 ${item.fixedMinutes} 分钟）',
          )
          .join('\n'),
    );
  }
}

/// **② 纵向：时间总计**——上周／本周／本月各自的总占用，下面是逐领域的矩阵表。
///
/// 图表类型可选柱状/条形/折线；**矩阵表不参与选择**（表就是表），它给出每个格子精确的分钟数与
/// 该周期内的占比，"横向占比 + 纵向总计"两件事因此在一张表里对齐。
final class _PeriodTotalSection extends StatelessWidget {
  const _PeriodTotalSection({
    required this.matrix,
    required this.kind,
    required this.onKind,
  });

  final AreaPeriodMatrix matrix;
  final ChartKind kind;
  final ValueChanged<ChartKind> onKind;

  @override
  Widget build(BuildContext context) {
    final totals = [
      for (var column = 0; column < matrix.periods.length; column++)
        ChartDatum(
          label: matrix.periods[column],
          value: matrix.periodTotal(column),
          color: chartColorAt(column),
        ),
    ];
    return Card(
      key: const Key('analytics-period-total'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(
              title: '时间总计',
              subtitle: '纵向对比：上周 / 本周 / 本月的总占用（含固定日程）',
              slot: AnalyticsChartSlot.periodTotal,
              kind: kind,
              onKind: onKind,
            ),
            const SizedBox(height: 12),
            AnalyticsChart(
              kind: kind,
              height: 180,
              emptyLabel: '上周、本周与本月都还没有已确认的计划块或固定日程。',
              data: totals,
            ),
            // 判据与图表的空状态一致：**合计为 0** 时不画表。领域仍会出现在报告的分布里（只是
            // 分钟数为 0），所以 `matrix.isEmpty` 是 false——用它会画出一张全是"—"的表。
            if (matrix.totalMinutes > 0) ...[
              const SizedBox(height: 14),
              _MatrixTable(matrix: matrix),
            ],
          ],
        ),
      ),
    );
  }
}

/// **③ 我规划得合理吗**：完成情况 + **领域覆盖缺口**。
///
/// "完成率/按期完成/逾期率"三个问的都是"计划本身合不合理"，与"计划 vs 实际"无关，因此按要求保留。
/// **逾期率此前一直算出来却从未显示**——它是最便宜的一条。
final class _PlanQualitySection extends StatelessWidget {
  const _PlanQualitySection({required this.report});
  final AnalyticsReport report;

  @override
  Widget build(BuildContext context) {
    final coverage = report.areaCoverage;
    return Wrap(
      key: const Key('analytics-plan-quality'),
      spacing: 12,
      runSpacing: 12,
      children: [
        _MetricCard(
          icon: Icons.task_alt,
          title: _ratioText('完成率', report.completionRate),
          detail: report.completionRate.isAvailable
              ? '范围内到期或完成的任务'
              : '该范围暂无可计算任务',
        ),
        _MetricCard(
          icon: Icons.schedule_outlined,
          title: _ratioText('按期完成', report.onTimeCompletionRate),
          detail: '分母是已完成且设有截止时间的任务',
        ),
        _MetricCard(
          icon: Icons.warning_amber_outlined,
          title: _ratioText('逾期', report.overdueRate),
          detail: '分母是范围内到期的任务；完成晚于截止即算逾期',
        ),
        if (coverage != null)
          _MetricCard(
            key: const Key('analytics-area-coverage'),
            icon: Icons.grid_view_outlined,
            title: coverage.allCovered
                ? '领域覆盖 ${coverage.covered.length} / ${coverage.totalAreas}'
                : '未排计划：${coverage.uncovered.join('、')}',
            detail: coverage.allCovered
                ? '每个领域在这个范围里都有时间'
                : '这 ${coverage.uncovered.length} 个领域在范围内一个计划块、'
                      '一场固定日程都没有',
          ),
      ],
    );
  }
}

/// **④ 我有没有好好休息**：休息时长（A）、工作与休息比例（D）、作息规律性（C）。
///
/// 三项**全部只看计划侧数据**：用户明确要求把"实际投入"从统计里拿掉，而"有没有好好休息"改看
/// 自己的规划——把任务排进睡眠、天天在不同时刻开工，就是规划层面的"没给自己留休息"。
final class _RestSection extends StatelessWidget {
  const _RestSection({
    required this.report,
    required this.restKind,
    required this.onRestKind,
    required this.workRestKind,
    required this.onWorkRestKind,
    required this.routineKind,
    required this.onRoutineKind,
  });

  final AnalyticsReport report;
  final ChartKind restKind;
  final ValueChanged<ChartKind> onRestKind;
  final ChartKind workRestKind;
  final ValueChanged<ChartKind> onWorkRestKind;
  final ChartKind routineKind;
  final ValueChanged<ChartKind> onRoutineKind;

  @override
  Widget build(BuildContext context) {
    final rest = report.restSummary;
    final workRest = report.workRest;
    final routine = report.routine;
    if (rest == null && workRest == null && routine.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const Key('analytics-rest'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('休息', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (rest != null) ...[
          _RestDurationCard(rest: rest, kind: restKind, onKind: onRestKind),
          const SizedBox(height: 16),
        ],
        if (workRest != null) ...[
          _WorkRestCard(
            metric: workRest,
            kind: workRestKind,
            onKind: onWorkRestKind,
          ),
          const SizedBox(height: 16),
        ],
        if (!routine.isEmpty)
          _RoutineCard(
            routine: routine,
            kind: routineKind,
            onKind: onRoutineKind,
          ),
      ],
    );
  }
}

/// A：各类休息的容量与被侵占量。
final class _RestDurationCard extends StatelessWidget {
  const _RestDurationCard({
    required this.rest,
    required this.kind,
    required this.onKind,
  });

  final RestSummaryMetric rest;
  final ChartKind kind;
  final ValueChanged<ChartKind> onKind;

  @override
  Widget build(BuildContext context) {
    final percent = (rest.achievedRatio * 100).round();
    return _SectionCard(
      cardKey: const Key('analytics-rest-duration'),
      slot: AnalyticsChartSlot.restDuration,
      kind: kind,
      onKind: onKind,
      title: '休息时长',
      subtitle:
          '保护时间共 ${_minutes(rest.totalMinutes)}，'
          '平均每天 ${_minutes(rest.averageDailyMinutes)}；'
          '其中 ${_minutes(rest.invadedMinutes)} 被安排占用（达成 $percent%）',
      chart: AnalyticsChart(
        kind: kind,
        emptyLabel: '还没有设置任何保护时间。',
        data: [
          for (var index = 0; index < rest.windows.length; index++)
            ChartDatum(
              label: rest.windows[index].label,
              value: rest.windows[index].minutes,
              color: chartColorAt(index),
            ),
        ],
      ),
      footnote: rest.windows
          .map(
            (window) =>
                '${window.label} ${_minutes(window.minutes)}'
                '${window.invadedMinutes == 0 ? '（完整保留）' : '，被占用 ${window.invadedMinutes} 分钟'}',
          )
          .join('\n'),
    );
  }
}

/// D：工作 / 生活 / 休息 / 未安排 的四段比例。
final class _WorkRestCard extends StatelessWidget {
  const _WorkRestCard({
    required this.metric,
    required this.kind,
    required this.onKind,
  });

  final WorkRestMetric metric;
  final ChartKind kind;
  final ValueChanged<ChartKind> onKind;

  @override
  Widget build(BuildContext context) => _SectionCard(
    cardKey: const Key('analytics-work-rest'),
    slot: AnalyticsChartSlot.workRest,
    kind: kind,
    onKind: onKind,
    title: '工作与休息的比例',
    subtitle:
        '休息（含生活）占 ${(metric.restRatio * 100).round()}%，'
        '工作占 ${(metric.workRatio * 100).round()}%',
    chart: AnalyticsChart(
      kind: kind,
      emptyLabel: '暂无可比较的时间。',
      data: [
        ChartDatum(
          label: '工作/学习',
          value: metric.workMinutes,
          color: chartColorAt(0),
        ),
        ChartDatum(
          label: '生活',
          value: metric.lifeMinutes,
          color: chartColorAt(1),
        ),
        ChartDatum(
          label: '空着的休息',
          value: metric.restMinutes,
          color: chartColorAt(2),
        ),
        ChartDatum(
          label: '未安排',
          value: metric.idleMinutes,
          color: chartColorAt(3),
        ),
      ],
    ),
    footnote:
        '工作/学习 ${_minutes(metric.workMinutes)}，'
        '生活 ${_minutes(metric.lifeMinutes)}，'
        '空着的休息 ${_minutes(metric.restMinutes)}，'
        '未安排 ${_minutes(metric.idleMinutes)}',
  );
}

/// C：作息规律性——每天的开工与收工时刻，以及它们的极差。
final class _RoutineCard extends StatelessWidget {
  const _RoutineCard({
    required this.routine,
    required this.kind,
    required this.onKind,
  });

  final RoutineMetric routine;
  final ChartKind kind;
  final ValueChanged<ChartKind> onKind;

  @override
  Widget build(BuildContext context) {
    final startSpread = routine.startSpreadMinutes ?? 0;
    final endSpread = routine.endSpreadMinutes ?? 0;
    return _SectionCard(
      cardKey: const Key('analytics-routine'),
      slot: AnalyticsChartSlot.routine,
      kind: kind,
      onKind: onKind,
      title: '作息规律性',
      subtitle:
          '开工相差 ${_minutes(startSpread)}，收工相差 ${_minutes(endSpread)}；'
          '平均 ${_clockText(routine.averageStartMinute)} 开工、'
          '${_clockText(routine.averageEndMinute)} 收工',
      chart: AnalyticsChart(
        kind: kind,
        emptyLabel: '这个范围里还没有任何安排。',
        data: [
          for (var index = 0; index < routine.perDay.length; index++)
            ChartDatum(
              label:
                  '${routine.perDay[index].localDate.month}/'
                  '${routine.perDay[index].localDate.day}',
              // 用**每天安排的跨度**当数值：它同时反映"多早开工"和"多晚收工"，
              // 比单独画开工时刻更能看出"这一天被拉得多长"。
              value:
                  routine.perDay[index].lastMinute -
                  routine.perDay[index].firstMinute,
              color: chartColorAt(index),
            ),
        ],
      ),
      footnote: routine.perDay
          .map(
            (day) =>
                '${day.localDate.month}/${day.localDate.day} '
                '${_clockText(day.firstMinute)}–${_clockText(day.lastMinute)}',
          )
          .join('\n'),
    );
  }
}

/// 统一的"标题 + 图型选择 + 图 + 脚注"卡片，避免每张各写一遍同样的骨架。
final class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.cardKey,
    required this.slot,
    required this.kind,
    required this.onKind,
    required this.title,
    required this.subtitle,
    required this.chart,
    required this.footnote,
  });

  final Key cardKey;
  final AnalyticsChartSlot slot;
  final ChartKind kind;
  final ValueChanged<ChartKind> onKind;
  final String title;
  final String subtitle;
  final Widget chart;
  final String footnote;

  @override
  Widget build(BuildContext context) => Card(
    key: cardKey,
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: title,
            subtitle: subtitle,
            slot: slot,
            kind: kind,
            onKind: onKind,
          ),
          const SizedBox(height: 12),
          chart,
          if (footnote.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(footnote, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    ),
  );
}

/// 卡片抬头：标题、一行口径说明、右侧的图型选择器。
final class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.slot,
    required this.kind,
    required this.onKind,
  });

  final String title;
  final String subtitle;
  final AnalyticsChartSlot slot;
  final ChartKind kind;
  final ValueChanged<ChartKind> onKind;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      const SizedBox(width: 12),
      ChartKindSelector(slot: slot, current: kind, onChanged: onKind),
    ],
  );
}

/// 分钟数 → "X 小时 Y 分钟"。图表与脚注共用同一套写法。
String _minutes(int value) {
  final hours = value ~/ 60;
  final rest = value % 60;
  if (hours == 0) return '$rest 分钟';
  if (rest == 0) return '$hours 小时';
  return '$hours 小时 $rest 分钟';
}

/// 本地分钟数 → `HH:mm`（1440 记作 `24:00`）。
String _clockText(int? minute) {
  if (minute == null) return '—';
  final hour = minute ~/ 60;
  final rest = minute % 60;
  return '${hour.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
}

String _ratioText(String label, RatioMetric metric) => metric.isAvailable
    ? '$label ${metric.numerator} / ${metric.denominator}'
    : '$label 暂无数据';

final class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.title,
    required this.detail,
    super.key,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 310,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 矩阵表：行是领域（按合计降序），列是周期，格子是"分钟数 + 该周期内的占比"。
final class _MatrixTable extends StatelessWidget {
  const _MatrixTable({required this.matrix});
  final AreaPeriodMatrix matrix;

  @override
  Widget build(BuildContext context) {
    final headerStyle = Theme.of(context).textTheme.labelLarge;
    final bodyStyle = Theme.of(context).textTheme.bodyMedium;
    final mutedStyle = Theme.of(context).textTheme.bodySmall;
    return Table(
      key: const Key('analytics-area-period-table'),
      columnWidths: {
        0: const FlexColumnWidth(1.6),
        for (var column = 0; column < matrix.periods.length; column++)
          column + 1: const FlexColumnWidth(),
        matrix.periods.length + 1: const FlexColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            _cell('领域', headerStyle),
            for (final period in matrix.periods) _cell(period, headerStyle),
            _cell('合计', headerStyle),
          ],
        ),
        for (var index = 0; index < matrix.rows.length; index++)
          TableRow(
            children: [
              _cell(
                matrix.rows[index].label,
                bodyStyle,
                key: Key('area-period-row-${matrix.rows[index].label}'),
              ),
              for (var column = 0; column < matrix.periods.length; column++)
                _cell(
                  matrix.rows[index].minutes[column] == 0
                      ? '—'
                      : '${matrix.rows[index].minutes[column]} 分钟'
                            '（${matrix.sharePercent(matrix.rows[index].minutes[column], column)}%）',
                  matrix.rows[index].minutes[column] == 0
                      ? mutedStyle
                      : bodyStyle,
                ),
              _cell('${matrix.rows[index].totalMinutes} 分钟', bodyStyle),
            ],
          ),
        TableRow(
          children: [
            _cell('合计', headerStyle),
            for (var column = 0; column < matrix.periods.length; column++)
              _cell('${matrix.periodTotal(column)} 分钟', headerStyle),
            _cell('${matrix.totalMinutes} 分钟', headerStyle),
          ],
        ),
      ],
    );
  }

  Widget _cell(String text, TextStyle? style, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
    child: Text(text, style: style),
  );
}

/// FR-STAT-05 的"休息保护情况"那一行在领域模型上（`RestProtectionMetric.summaryLabel`）：
/// 那句话有真实分支（有没有放宽过），而它所在的卡在 `ListView` 里、视口外不会被构建，
/// 放在页面里就只能靠 widget 测试去够它。
final class _EvidenceLists extends StatelessWidget {
  const _EvidenceLists({required this.report});
  final AnalyticsReport report;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('中断与调整', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          // **"不同精力时段的完成效果"与"休息保护情况"两行已按用户要求移除**：
          // 前者按**实际投入**分桶，后者按"实际专注有没有落进保护时间"算，两者都属于
          // "实际"这一侧。休息那一侧已由上面的《休息》一节按**计划侧**重做（休息时长/作息
          // 规律性/工作休息比例）。FR-STAT-06 的三项原样保留。
          Text(_rankedText('常见中断', report.commonInterruptions)),
          const SizedBox(height: 6),
          Text(_rankedText('重排原因', report.replanReasons)),
          const SizedBox(height: 6),
          Text(
            '建议行为：接受 ${report.suggestionBehavior.accepted}，'
            '修改 ${report.suggestionBehavior.modified}，'
            '拒绝 ${report.suggestionBehavior.rejected}',
          ),
        ],
      ),
    ),
  );
}

String _rankedText(String label, List<RankedMetric> values) => values.isEmpty
    ? '$label：暂无记录'
    : '$label：${values.map((item) => '${item.code} ${item.count} 次').join('，')}';
