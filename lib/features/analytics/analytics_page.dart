import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/application/execution/execution_metrics_query.dart';
import 'package:personal_planner/application/feedback_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/execution/execution_metrics.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/area_period_matrix.dart';
import 'package:personal_planner/domain/models/chart_kind.dart';
import 'package:personal_planner/domain/models/feedback_message.dart';
import 'package:personal_planner/design/planner_pickers.dart';
import 'package:personal_planner/features/analytics/analytics_adjustments_tab.dart';
import 'package:personal_planner/features/analytics/analytics_drilldown_sheet.dart';
import 'package:personal_planner/features/analytics/analytics_overview.dart';
import 'package:personal_planner/features/analytics/analytics_plan_quality_tab.dart';
import 'package:personal_planner/features/analytics/recurring_goal_summary.dart';
import 'package:personal_planner/features/analytics/analytics_rest_tab.dart';
import 'package:personal_planner/features/analytics/analytics_time_allocation_tab.dart';
import 'package:personal_planner/features/analytics/feedback_cards.dart';
import 'package:personal_planner/features/execution/execution_metrics_summary.dart';

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
    this.clock,
    this.feedbackMessages = const [],
    this.loadTagNames,
    this.loadChartKinds,
    this.saveChartKind,
    this.openBreakdown,
    this.openBreakdownTarget,
    this.recurringGoals,
    this.onOpenRecurringGoals,
    this.onGeneratePlan,
    this.onOpenRestRules,
    this.executionMetrics,
    super.key,
  });

  final AnalyticsQuery analytics;
  final DateTime nowUtc;
  final TimeZoneDatabase zones;
  final String timeZoneId;

  /// 读取"现在"的时钟。为空时一律用 [nowUtc]——那让行为**确定**：
  /// 页面算出来的范围只取决于显式传入的那个瞬时，测试因此可复现。
  ///
  /// **为什么需要有它**：§3.1 要求"程序跨过午夜后自动刷新『今天』，不能继续显示昨天"
  /// （§7.1 第 4 条）。而 [nowUtc] 是构造时的一个**瞬时**，页面若在 `initState` 里用它算一次
  /// 范围就再也不管，程序开着跨过午夜之后"今天"仍然是昨天——**不会报错**，用户看到一个
  /// 看起来正常、实际少算一天的页面。有了时钟，页面在每次重建时都能问一次"现在是哪一天"，
  /// 发现日期变了就把范围重新算一遍（重建由切回前台、托盘唤醒、父层定时器等触发）。
  ///
  /// 生产装配传 `clock.nowUtc`；测试传一个可控的闭包，就能把时间推到午夜之后。
  final DateTime Function()? clock;
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

  /// 点摘要或图表项时打开**来源明细**（§3.1、§7.1 第 6 条）。
  ///
  /// **为空时页面自己用内置的底部面板**（`showAnalyticsBreakdown`）——这条例外是刻意的：
  /// 明细面板不含路由，它只需要报告数据。而"从明细进入任务或日程"需要路由，那一步走
  /// [openBreakdownTarget]，由持有路由的装配层注入。
  final void Function(String title, String subtitle)? openBreakdown;

  /// 从明细进入任务或日程（§3.1 的"再从明细进入任务或日程"）。为空时明细行不可点。
  final void Function(AnalyticsBreakdownTarget target)? openBreakdownTarget;

  /// 周期目标的汇总（§3.1 最后一条、§11 Task 9）。
  ///
  /// **为空时整张卡不出现。** 未装配周期目标服务的装配（以及绝大多数既有测试）就是这种情况；
  /// 显示一张"周期目标 0"的卡只会让人以为功能坏了，而事实是这个批次没装配它。
  final RecurringGoalSummaryData? recurringGoals;

  /// 点周期目标摘要里的入口时的去向。为空时不给入口。
  final VoidCallback? onOpenRecurringGoals;

  /// 空状态里的下一步操作（§11 Task 12 Step 3）。
  ///
  /// **为空时那两处不渲染按钮**：没装配对应服务就没有可去之处，给一个点了没反应的入口
  /// 比没有入口更糟（与这个应用其它端口同一口径）。
  final VoidCallback? onGeneratePlan;
  final VoidCallback? onOpenRestRules;

  /// 1.11.0 执行指标查询。为空时不显示执行摘要卡。
  final ExecutionMetricsQuery? executionMetrics;

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

final class _AnalyticsPageState extends State<AnalyticsPage>
    with SingleTickerProviderStateMixin {
  late AnalyticsFilter _filter;
  AnalyticsReport? _report;
  Object? _error;
  bool _loading = true;
  Set<String> _availableTags = const {};

  /// 四个页签（§3.1）。默认「时间分配」——它是用户的主诉求（领域时间分配）。
  late final TabController _tabs = TabController(length: 4, vsync: this)
    ..addListener(_onTabChanged);

  /// 页签切换要重建主体：这里**不是**用 `TabBarView`（它的高度是固定的，而四页内容长短
  /// 差得多——矮的那页会在下面留一大片空白，高的那页会被裁掉）。因此手动按 `_tabs.index`
  /// 渲染，并用 `setState` 驱动。
  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

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

  /// 打开某一项的来源明细（§3.1、§7.1 第 6 条）。
  ///
  /// 明细的内容由 `analyticsBreakdownFor` 从**同一份报告**分解出来，不重新计算任何指标——
  /// 统计页的任何一处都不该出现第二套口径。行内跳转走注入的 [AnalyticsPage.openBreakdownTarget]；
  /// 未装配时明细行不可点（不显示点了没反应的箭头）。
  Future<void> _openBreakdown(
    AnalyticsReport report,
    AnalyticsSummarySlot slot,
  ) async {
    final data = analyticsBreakdownFor(report, slot);
    final injected = widget.openBreakdown;
    if (injected != null) {
      injected(data.title, data.subtitle);
      return;
    }
    await showAnalyticsBreakdown(
      context,
      data: data,
      onOpenRow: widget.openBreakdownTarget == null
          ? null
          : (row) {
              final target = row.target;
              if (target != null) widget.openBreakdownTarget!(target);
            },
    );
  }

  @override
  void initState() {
    super.initState();
    // §3.1："默认范围为**本周**"。此前默认是"今天"，而用户打开统计页想看的是这一周的安排，
    // 每天都要手工点一次「本周」。
    _filter = _weekFilter(_todayLocalDate());
    _nowAnchor = _readNow();
    _syncDateAcrossMidnight();
    _load();
    _loadTagNames();
    _loadChartKinds();
  }

  /// 上一次"今天"是哪个本地日，以及当时算出的范围是哪种预设。
  ///
  /// 用来发现"程序跨过午夜但没有重启"（§7.1 第 4 条）。存**预设**而不是原始区间是刻意的：
  /// 用户选了「本月」时跨过午夜不需要动他的选择，只有"跟着今天走"的那三种预设（今天／本周／
  /// 本月）才要在日期变化后重算。
  DateTime _nowAnchor = DateTime(1970);
  ExecutionMetrics? _executionMetrics;
  ExecutionSourceBreakdown? _executionBreakdown;

  /// 读一次"现在"：[AnalyticsPage.clock] 优先，否则用构造时传入的 [AnalyticsPage.nowUtc]。
  DateTime _readNow() => widget.clock?.call() ?? widget.nowUtc;

  /// `nowUtc` 在**本机时区**下的日历日（只取年月日）。
  ///
  /// 用 `zones.toLocal` 而不是 `nowUtc.year/month/day`：后者拿到的是 **UTC** 的日期，
  /// 在 UTC+8 的凌晨会差一天。
  DateTime _todayLocalDate() => _localDateOf(_readNow());

  DateTime _localDateOf(DateTime instantUtc) {
    final local = widget.zones.toLocal(instantUtc, widget.timeZoneId);
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

  /// 含 [today] 的那一周（周一起 7 天）的区间。
  AnalyticsFilter _weekFilter(DateTime today) {
    final monday = _addDays(today, -(today.weekday - DateTime.monday));
    return AnalyticsFilter(
      startUtc: _localMidnight(monday),
      endUtc: _localMidnight(_addDays(monday, 7)),
    );
  }

  /// 程序跨过午夜后重算"跟着今天走"的范围（§3.1／§7.1 第 4 条）。
  ///
  /// 在每次重建时调用。发现**本地日**变了就按当前预设重算一遍并重新查询；用户选的是
  /// 「自定义范围」时不动——那是他显式指定的日期，跨午夜与它无关。
  ///
  /// **为什么不用定时器**：定时器要处理"程序被挂起／系统休眠"下的漂移，还要在 dispose 时
  /// 拆掉，而重建本来就会发生（切回前台、托盘唤醒、父层刷新）。这里只依赖"日期变了"这个
  /// 事实，因此无论界面因为什么原因重建，答案都对。
  void _syncDateAcrossMidnight() {
    final today = _todayLocalDate();
    if (today == _nowAnchor) return;
    _nowAnchor = today;

    final kind = _rangeKindFor(
      _filter,
      zones: widget.zones,
      timeZoneId: widget.timeZoneId,
    );
    final refreshed = switch (kind) {
      _RangeKind.today => AnalyticsFilter(
        startUtc: _localMidnight(today),
        endUtc: _localMidnight(_addDays(today, 1)),
        tags: _filter.tags,
      ),
      _RangeKind.week => AnalyticsFilter(
        startUtc: _weekFilter(today).startUtc,
        endUtc: _weekFilter(today).endUtc,
        tags: _filter.tags,
      ),
      _RangeKind.month => AnalyticsFilter(
        startUtc: _localMidnight(DateTime(today.year, today.month)),
        endUtc: _localMidnight(DateTime(today.year, today.month + 1)),
        tags: _filter.tags,
      ),
      // 自定义范围与"今天"无关：用户指定的是哪几天，跨午夜不该把它改掉。
      _RangeKind.custom => null,
    };
    if (refreshed == null) return;
    if (refreshed.startUtc == _filter.startUtc &&
        refreshed.endUtc == _filter.endUtc) {
      return;
    }
    _filter = refreshed;
    _load();
  }

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
      ExecutionMetrics? execution;
      ExecutionSourceBreakdown? breakdown;
      final executionQuery = widget.executionMetrics;
      if (executionQuery != null) {
        try {
          execution = await executionQuery.metricsForWindow(
            fromUtc: _filter.startUtc,
            toUtc: _filter.endUtc,
            asOfUtc: _readNow(),
          );
          breakdown = await executionQuery.sourceBreakdown(
            fromUtc: _filter.startUtc,
            toUtc: _filter.endUtc,
          );
        } on Object {
          // 执行指标失败不能拖垮整个统计页；摘要卡保持上一次结果或隐藏。
        }
      }
      if (!mounted) return;
      setState(() {
        _report = report;
        _matrix = matrix;
        _executionMetrics = execution;
        _executionBreakdown = breakdown;
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
    // 换算抽成纯函数（`analyticsRangeForSelectedDays`）：这样才能对**跨月、跨年、
    // 单日**这些边界直接写测试，而不必每次去驱动日期选择器。
    final range = analyticsRangeForSelectedDays(
      selected,
      zones: widget.zones,
      timeZoneId: widget.timeZoneId,
    );
    _setRange(range.startUtc, range.endUtc);
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
  Widget build(BuildContext context) {
    // §3.1／§7.1 第 4 条：先确认"今天"还是不是今天。跨过午夜时这里会把范围重算一遍，
    // 因此下面的「今天」高亮与查询窗口都跟着走，不会继续显示昨天。
    _syncDateAcrossMidnight();
    return Scaffold(
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
                    // **以区间为唯一真相反推高亮**：见 `_rangeKindFor` 的说明。
                    selected: _rangeKindFor(
                      _filter,
                      zones: widget.zones,
                      timeZoneId: widget.timeZoneId,
                    ),
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
                  if (_executionMetrics case final metrics?) ...[
                    const SizedBox(height: 16),
                    ExecutionMetricsSummary(
                      metrics: metrics,
                      breakdown: _executionBreakdown,
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
                        // 加载失败要**被播报**（M2 §6：错误不能只靠视觉表达）。
                        child: Semantics(
                          liveRegion: true,
                          child: Text('统计加载失败：$_error'),
                        ),
                      ),
                    ),
                  ],
                  if (_report case final report?) ...[
                    const SizedBox(height: 22),
                    // ── 首页四项摘要（§3.1）────────────────────────────────────
                    //
                    // **顺序即重点**：用户打开这一页第一眼要看到四个数字，而不是自己去图里找。
                    // 摘要之后才是四个页签。
                    AnalyticsOverview(
                      report: report,
                      // **摘要卡总是可点的**：`_openBreakdown` 自己决定走注入的面板还是内置面板。
                      // 早先这里写成"`openBreakdown == null` 就不给入口"，于是未注入端口的装配下
                      // 摘要卡变成不可点的死入口——而内置面板（`showAnalyticsBreakdown`）本来
                      // 就能处理这种情况，一行代码就能自证。
                      onOpenSource: (slot) => _openBreakdown(report, slot),
                      // 空状态的下一步动作（§11 Task 12 Step 3）。为空时那两处不渲染按钮。
                      onGeneratePlan: widget.onGeneratePlan,
                      onOpenRestRules: widget.onOpenRestRules,
                    ),
                    // ── 周期目标摘要（§3.1 最后一条、§11 Task 9）──────────────────
                    //
                    // **刻意放在四项摘要之后、四个页签之前**：它既不是"这一段时间分给了谁"
                    // （那由领域时间分配回答），也不是一个可以与"计划总时长"相加的数字，
                    // 因此单独一张卡，并且卡里自己声明口径。装配层没接周期目标时整张卡不出现
                    // （`recurringGoals` 为空），而不是显示一个空壳。
                    if (widget.recurringGoals case final goals?) ...[
                      const SizedBox(height: 20),
                      AnalyticsRecurringGoalSummary(
                        data: goals,
                        onOpenDetail: widget.onOpenRecurringGoals,
                      ),
                    ],
                    const SizedBox(height: 20),
                    // ── 四个页签（§3.1）────────────────────────────────────────
                    //
                    // 页签之前，这一页是一条长列表：领域占比、时间总计、完成情况、休息三卡、
                    // 调整记录全部堆在一个滚动条里，用户得一路滑下去才知道有哪些内容。
                    // 分成四个页签之后，每一页回答一个不同的问题：
                    //   时间分配 → 时间分给了谁；计划质量 → 计划合不合理；
                    //   休息与作息 → 有没有给自己留休息；调整记录 → 计划是怎么被改出来的。
                    //
                    // 「时间分配」是默认页签（§3.1）。
                    TabBar(
                      controller: _tabs,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: const [
                        Tab(key: Key('analytics-tab-time'), text: '时间分配'),
                        Tab(key: Key('analytics-tab-quality'), text: '计划质量'),
                        Tab(key: Key('analytics-tab-rest'), text: '休息与作息'),
                        Tab(
                          key: Key('analytics-tab-adjustments'),
                          text: '调整记录',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // 四个页签各自的高度不同，因此**不能用固定高度的 TabBarView**：
                    // 矮的那一页会在下面留一大片空白，高的那一页会被裁掉（页面整体已经是
                    // 一个可滚动列表）。用 `AnimatedSize` + 只渲染当前页，既没有裁切，
                    // 也保住了页签切换时的高度过渡。
                    AnimatedSize(
                      duration: const Duration(milliseconds: 160),
                      alignment: Alignment.topCenter,
                      child: switch (_tabs.index) {
                        0 => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AnalyticsAreaShareSection(
                              report: report,
                              kind: _kindOf(AnalyticsChartSlot.areaShare),
                              onKind: widget.openBreakdown == null
                                  ? (kind) => _setChartKind(
                                      AnalyticsChartSlot.areaShare,
                                      kind,
                                    )
                                  : null,
                            ),
                            const SizedBox(height: 20),
                            if (_matrix case final matrix?)
                              AnalyticsPeriodTotalSection(
                                matrix: matrix,
                                kind: _kindOf(AnalyticsChartSlot.periodTotal),
                              ),
                          ],
                        ),
                        1 => PlanQualityTab(report: report),
                        2 => RestTab(
                          report: report,
                          restKind: _kindOf(AnalyticsChartSlot.restDuration),
                          workRestKind: _kindOf(AnalyticsChartSlot.workRest),
                          routineKind: _kindOf(AnalyticsChartSlot.routine),
                        ),
                        _ => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AdjustmentsTab(report: report),
                            // 温和反馈（FR-STAT-08 的呈现侧）属于"这套计划是怎么被改出来的"，
                            // 因此与调整记录同一页，而不是塞在时间分配下面。
                            if (_messages.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              FeedbackCards(
                                messages: _messages,
                                filter: report.filter,
                              ),
                            ],
                          ],
                        ),
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 把用户在选择器里选中的**日期范围**换算成统计用的 UTC 窗口。
///
/// **核心口径：末日含当天。** `showDateRangePicker` 交回的是一个"用户眼里的日期区间"，
/// 而 `AnalyticsFilter`（以及底下所有查询）用的是**半开区间** `[startUtc, endUtc)`。
/// 因此终点必须取"末日次日零点"——少这一天，用户选了 10 月 1 日到 10 月 7 日却看不到 7 号，
/// 而且**不会报错**，只是每个数字都偏小一点（这类"静默少算一天"最难发现）。
///
/// **按日历加减天数，不用 `add(Duration(days: 1))`**：后者是绝对时间加法，夏令时切换日的
/// 本地一天不是 24 小时，加 24 小时会落回当天 23:00、日期不变。本仓库在保护时间展开器上
/// 吃过同一处亏（§13.0 的 C11）。
///
/// **抽成顶层的纯函数**（而不是留在 State 里）是为了能对跨月、跨年、闰年二月、单日这些边界
/// 直接写测试，不必每次去驱动日期选择器。顺带也说明了一件事：我第一版把它插在了 State 的
/// 方法之间，于是它成了**类的方法**、测试里根本找不到——如果只跑集成路径就发现不了。
({DateTime startUtc, DateTime endUtc}) analyticsRangeForSelectedDays(
  DateTimeRange selected, {
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) {
  DateTime midnightOf(DateTime date) => zones.localMidnightToUtc(
    DateTime(date.year, date.month, date.day),
    timeZoneId,
  );

  final start = selected.start;
  final end = selected.end;
  return (
    startUtc: midnightOf(start),
    // 「次日零点」由日历加法得出：`DateTime(y, m, d + 1)` 会自动进位到下个月/下一年，
    // 因此跨月、跨年、闰年二月都不需要特判。
    endUtc: midnightOf(DateTime(end.year, end.month, end.day + 1)),
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

/// 统计范围的四种预设（M9 收口后修）。
///
/// **修的是什么**：四个按钮里「自定义范围」写死成 `FilledButton.tonal`，另外三个是
/// `OutlinedButton`——于是**无论当前范围是什么，「自定义范围」永远是高亮的那一个**。
/// 用户的原话是"时间范围应该选哪个亮哪个，现在是自定义范围常亮，会影响使用"：
/// 他选了「本周」，界面上却是「自定义范围」亮着，看不出自己当前看的是哪一段。
///
/// 修法：**由 `filter` 反推当前选中哪一个**（见 [_rangeKindFor]），再据此决定样式。
enum _RangeKind { today, week, month, custom }

/// 从当前筛选区间反推它属于哪个预设。
///
/// **为什么反推而不是记一个 `_selectedKind` 字段**：区间是可以被别处改掉的
/// （`_setRange` 由四个入口共用，将来还可能从路由参数进来），记一个字段就得在每个入口
/// 手动同步，漏一处就会出现"按钮亮着但范围不是它"。**以区间为唯一真相**，
/// 高亮永远和实际查询的那段一致，不可能漂移。
///
/// **只看区间自己的形状，不拿"今天"去套。** 早先的实现是"把今天的三种预设区间算出来，
/// 看哪一个等于当前区间"，那在**跨过午夜之后必然失效**：用户昨天选了「今天」，区间停在
/// 昨天，而"今天的预设"已经是新的一天——于是它被判成「自定义范围」，上面那条按预设重算的
/// 刷新逻辑直接跳过（实测：跨午夜后不再重载，正是要修的那条缺陷）。改成按**形状**判断：
///
/// - 起止落在同一个本地日历日 → `today`；
/// - 起止都落在本地周一且相差 7 天 → `week`（周一起算，与 `_weekFilter` 同一规则）；
/// - 起点是该月 1 日、终点是次月 1 日 → `month`；
/// - 其余 → `custom`（用户显式选的日期区间，跨午夜不该被动）。
///
/// **比较的是瞬时而不是日期**：三个预设都由同一套 `localMidnightToUtc` 算出来，
/// 因此同一段区间必然逐微秒相等。用日期比较反而会在夏令时切换日误判。
_RangeKind _rangeKindFor(
  AnalyticsFilter filter, {
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) {
  final startLocal = _localDateOfInstant(zones, timeZoneId, filter.startUtc);
  final endLocal = _localDateOfInstant(zones, timeZoneId, filter.endUtc);
  DateTime midnight(DateTime date) =>
      zones.localMidnightToUtc(date, timeZoneId);
  // 按日历加减天数：绝对时间加法在夏令时切换日会退回当天 23:00，日期不变。
  DateTime addDays(DateTime date, int days) =>
      DateTime(date.year, date.month, date.day + days);

  if (endLocal == addDays(startLocal, 1)) return _RangeKind.today;
  if (filter.endUtc == midnight(addDays(startLocal, 7)) &&
      startLocal.weekday == DateTime.monday) {
    return _RangeKind.week;
  }
  if (startLocal.day == 1 &&
      endLocal == DateTime(startLocal.year, startLocal.month + 1)) {
    return _RangeKind.month;
  }
  return _RangeKind.custom;
}

/// UTC 瞬时 → 它所在**本地日**的年月日。与 State 里的 `_localDateOf` 同一口径，
/// 但这一层是顶层纯函数，因此测试与 State 用的是同一段逻辑。
DateTime _localDateOfInstant(
  TimeZoneDatabase zones,
  String timeZoneId,
  DateTime instantUtc,
) {
  final local = zones.toLocal(instantUtc, timeZoneId);
  return DateTime(local.year, local.month, local.day);
}

final class _RangeControls extends StatelessWidget {
  const _RangeControls({
    required this.filter,
    required this.selected,
    required this.onToday,
    required this.onWeek,
    required this.onMonth,
    required this.onCustom,
  });

  final AnalyticsFilter filter;

  /// 当前区间属于哪个预设（由 [_rangeKindFor] 算出）。
  final _RangeKind selected;

  final VoidCallback onToday;
  final VoidCallback onWeek;
  final VoidCallback onMonth;
  final VoidCallback onCustom;

  /// 一个范围按钮。**选中的那个是实心（`FilledButton.tonal`），其余是描边**
  /// ——"选哪个亮哪个"。`key` 由 kind 派生，与既有测试用的 key 完全一致。
  Widget _rangeButton(_RangeKind kind, String label, VoidCallback onPressed) {
    final key = Key('analytics-range-${kind.name}');
    return selected == kind
        ? FilledButton.tonal(key: key, onPressed: onPressed, child: Text(label))
        : OutlinedButton(key: key, onPressed: onPressed, child: Text(label));
  }

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
            //
            // **样式随 `selected` 变**（M9 收口后修）：选中的那个用 `FilledButton.tonal`，
            // 其余用 `OutlinedButton`。此前「自定义范围」写死成实心，于是它永远亮着。
            for (final (kind, label, onPressed) in [
              (_RangeKind.today, '今天', onToday),
              (_RangeKind.week, '本周', onWeek),
              (_RangeKind.month, '本月', onMonth),
              (_RangeKind.custom, '自定义范围', onCustom),
            ])
              _rangeButton(kind, label, onPressed),
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
