import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_glass.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
import 'package:personal_planner/features/calendar/schedule_category_legend.dart';
import 'package:personal_planner/features/calendar/schedule_category_summary.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

final class TodayPage extends StatefulWidget {
  const TodayPage({
    required this.source,
    required this.day,
    this.toLocal,
    this.nowUtc,
    this.onStartFocus,
    this.onComplete,
    this.onOpenDetail,
    this.onDefer,
    this.onRequestAdjust,
    this.onToggleLock,
    this.onSkipCurrent,
    this.dismissedProposalId,
    this.onDismissReplan,
    this.replanProposalId,
    super.key,
  });

  final ScheduleViewSource source;
  final DateTime day;

  /// 视图数据以 UTC 保存；生产环境传入应用选定时区的换算函数。
  /// 测试与纯视图预览可省略，此时保持输入值不变。
  final DateTime Function(DateTime instantUtc)? toLocal;

  /// 判定"当前安排"的基准时刻。省略时取系统当前时间。
  final DateTime? nowUtc;

  // ── M4（路线图 §8）执行动作 ────────────────────────────────────────────────
  //
  // 与 `TaskDetailPage` 同一套做法：**页面不认识路由，导航由 router 注入**。
  // 端口为空时对应入口**不渲染**——这比"渲染一个点了没反应的按钮"诚实。

  /// 「开始专注」。§8 退出条件要求"从今日页开始专注不超过两次点击"，
  /// 因此这个入口直接做成卡片上的按钮，不藏进菜单。
  final ValueChanged<ScheduleViewItem>? onStartFocus;

  /// 「完成」。由调用方决定是改任务状态还是别的；页面只负责发起。
  final ValueChanged<ScheduleViewItem>? onComplete;

  /// 「查看详情」。
  final ValueChanged<ScheduleViewItem>? onOpenDetail;

  /// 「延后」。页面不收集时长——那属于确认界面，这里只发起。
  final ValueChanged<ScheduleViewItem>? onDefer;

  /// 「请求调整」→ 排程提案预览。
  final ValueChanged<ScheduleViewItem>? onRequestAdjust;

  /// 「锁定」这条计划块。只对任务块出现（`movableTaskBlockId` 之外的东西锁不了）。
  final ValueChanged<ScheduleViewItem>? onToggleLock;

  /// 「**跳过本次**」（2026-10-07 用户定义）。
  ///
  /// 语义：只放弃**这一个时间块**，任务仍是未完成待办、剩余时长不变，并继续参与重排；
  /// 由调用方去重新生成提案（默认进预览，"信任自动调整"开启时直接应用）。
  ///
  /// **刻意与另外两个动作分开**，页面只发出"跳过这一块"这一件事：
  /// · 「延后到明天」改的是 `availableFromUtc`（另一个动作）；
  /// · 「取消任务」改的是 `TaskStatus.cancelled`（另一个动作）。
  /// 页面不替调用方做这两种决定。
  final ValueChanged<ScheduleViewItem>? onSkipCurrent;

  /// 本次会话里已被用户关掉的那条重排提示对应的方案 id。
  ///
  /// **用 id 而不是 bool**：bool 会让"关掉一次之后就再也不提醒"，
  /// 而 §8 要求"重新生成的新方案仍会提醒"。只隐藏**同一条**。
  final String? dismissedProposalId;

  /// 关闭重排提示。
  final VoidCallback? onDismissReplan;

  /// 当前待确认方案的 id；为空表示没有待确认方案，此时不显示提示。
  final String? replanProposalId;

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

  /// 判定"当前安排"用的时刻：显式传入优先（测试可控），否则取系统当前时间。
  DateTime get _effectiveNow => (widget.nowUtc ?? DateTime.now()).toUtc();

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
                        categoryKey: item.categoryKey,
                        categoryLabel: item.categoryLabel,
                        categoryColorArgb: item.categoryColorArgb,
                        categorySortOrder: item.categorySortOrder,
                        explanation: item.explanation,
                        // **拷贝时新字段容易漏**：这里的对象是"按当天裁剪过区间"的副本，
                        // 漏掉 `isCompleted` 会让"已完成"标记在这一页永远不显示——这条由
                        // `today_page_test.dart` 的标记用例守着。
                        // 同理，M4 加的 `taskId` 也必须带过来：漏了它，
                        // 「开始专注／完成／查看详情」在这些副本上会全部失灵
                        // （条目本身有 taskId，副本却是 null），而且症状是
                        // "按钮不见了"而不是报错——最难查的那种。
                        taskId: item.taskId,
                        isCompleted: item.isCompleted,
                        areaId: item.areaId,
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
                final categorySummaries = summarizeScheduleCategories(items);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // §8：顶部重排提示支持关闭，**关闭只隐藏这条提示，不取消待确认方案**。
                    // 因此它渲染与否只看"有没有方案"与"这条方案是否已被关掉"，
                    // 与 `_PlanningRail` 里的方案状态无关。
                    if (widget.replanProposalId != null &&
                        widget.replanProposalId != widget.dismissedProposalId)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _ReplanNotice(onDismiss: widget.onDismissReplan),
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ScheduleCategoryLegend(
                        summaries: categorySummaries,
                      ),
                    ),
                    if (categorySummaries.isNotEmpty)
                      const SizedBox(height: 12),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth >= 960;
                          final timeline = _TimelinePanel(
                            items: items,
                            formatTime: formatTime,
                            nowUtc: _effectiveNow,
                            onStartFocus: widget.onStartFocus,
                            onComplete: widget.onComplete,
                            onOpenDetail: widget.onOpenDetail,
                            onDefer: widget.onDefer,
                            onRequestAdjust: widget.onRequestAdjust,
                            onToggleLock: widget.onToggleLock,
                            onSkipCurrent: widget.onSkipCurrent,
                          );
                          final summary = _PlanningRail(
                            items: items,
                            categorySummaries: categorySummaries,
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
    ],
  );
}

final class _TimelinePanel extends StatelessWidget {
  const _TimelinePanel({
    required this.items,
    required this.formatTime,
    required this.nowUtc,
    this.onStartFocus,
    this.onComplete,
    this.onOpenDetail,
    this.onDefer,
    this.onRequestAdjust,
    this.onToggleLock,
    this.onSkipCurrent,
  });

  final List<ScheduleViewItem> items;
  final String Function(DateTime value) formatTime;
  final DateTime nowUtc;
  final ValueChanged<ScheduleViewItem>? onStartFocus;
  final ValueChanged<ScheduleViewItem>? onComplete;
  final ValueChanged<ScheduleViewItem>? onOpenDetail;
  final ValueChanged<ScheduleViewItem>? onDefer;
  final ValueChanged<ScheduleViewItem>? onRequestAdjust;
  final ValueChanged<ScheduleViewItem>? onToggleLock;
  final ValueChanged<ScheduleViewItem>? onSkipCurrent;

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
                        isCurrent: _isCurrent(items[index]),
                        onStartFocus: onStartFocus,
                        onComplete: onComplete,
                        onOpenDetail: onOpenDetail,
                        onDefer: onDefer,
                        onRequestAdjust: onRequestAdjust,
                        onToggleLock: onToggleLock,
                        onSkipCurrent: onSkipCurrent,
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

  /// "现在正落在这一条里"。
  ///
  /// 半开区间 `[start, end)`：`end` 那一瞬间已经不算"正在做"，否则相邻两条会同时是"当前"，
  /// 卡片上就会出现两组「开始专注」。
  bool _isCurrent(ScheduleViewItem item) =>
      !nowUtc.isBefore(item.range.startUtc) &&
      nowUtc.isBefore(item.range.endUtc);
}

final class _TimelineItem extends StatelessWidget {
  const _TimelineItem({
    required this.item,
    required this.isLast,
    required this.formatTime,
    required this.isCurrent,
    this.onStartFocus,
    this.onComplete,
    this.onOpenDetail,
    this.onDefer,
    this.onRequestAdjust,
    this.onToggleLock,
    this.onSkipCurrent,
  });

  final ScheduleViewItem item;
  final bool isLast;
  final String Function(DateTime value) formatTime;
  final bool isCurrent;
  final ValueChanged<ScheduleViewItem>? onStartFocus;
  final ValueChanged<ScheduleViewItem>? onComplete;
  final ValueChanged<ScheduleViewItem>? onOpenDetail;
  final ValueChanged<ScheduleViewItem>? onDefer;
  final ValueChanged<ScheduleViewItem>? onRequestAdjust;
  final ValueChanged<ScheduleViewItem>? onToggleLock;
  final ValueChanged<ScheduleViewItem>? onSkipCurrent;

  /// 这是不是一个**任务**条目。
  ///
  /// 只有任务才有"完成／开始专注／延后"这些动作：固定日程的完成是**时间过去**
  /// （数据源已经算好 `isCompleted`），保护时间是规则算出来的区间。对它们渲染这些按钮，
  /// 用户点了也无处落地。
  bool get _isTask => item.kind == ScheduleItemKind.task && item.taskId != null;

  /// 能不能"请求调整／锁定"：只有计划块能移动，判定与拖动那条路径共用同一个函数，
  /// 免得两处对"什么可移动"给出不同答案。
  bool get _isMovable => movableTaskBlockId(item) != null;

  @override
  Widget build(BuildContext context) {
    // 与七日历、单日详情共用同一个派生器：同一事项在三个视图里必须逐值同色。
    // 此前这里用的是 `alpha: 0.10`（比七日历的 0.18 还浅），左侧强调条却是 100% 原色，
    // 于是"浅底 + 亮条"看起来像两块拼在一起。
    final visual = scheduleCategoryCardStyle(item.categoryColor);
    return Semantics(
      key: ValueKey('today-schedule-${item.id}'),
      label:
          '${item.title}，${item.categoryLabel}，${item.kind.label}，${formatTime(item.range.startUtc)}到${formatTime(item.range.endUtc)}'
          '${item.isCompleted ? '，已完成' : ''}',
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
                      color: visual.accent,
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
                key: ValueKey('today-schedule-card-${item.id}'),
                margin: const EdgeInsets.only(bottom: 10),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: visual.fill,
                  border: Border.all(color: visual.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                // **`stretch` 是这条竖条能不能被看见的关键**，不是排版洁癖：`Row` 默认
                // `CrossAxisAlignment.center`，而没有子节点的 `ColoredBox` 内在高度是 0，于是
                // "左侧强调条"会被量成 0×3 的零面积控件——控件树里有它、颜色也对、测试里
                // `tester.widget<ColoredBox>(...).color` 照样通过，屏幕上却什么都没有（用户就是
                // 这么发现它的）。卡片高度在这里本来就是紧约束（外层 `Row` 也是 `stretch`），
                // 所以只要把内层 `Row` 也设成 `stretch`，竖条就会被拉满整张卡片的高度。
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 3,
                      child: ColoredBox(
                        key: ValueKey('today-schedule-accent-${item.id}'),
                        color: visual.accent,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              item.kind.icon,
                              key: ValueKey('today-schedule-icon-${item.id}'),
                              size: 18,
                              color: visual.accent,
                            ),
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
                                    '${formatTime(item.range.startUtc)}–${formatTime(item.range.endUtc)} · ${item.categoryLabel}',
                                    style: const TextStyle(
                                      color: PlannerPalette.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // 「已完成」标记。任务：所属任务已勾选完成；固定日程：结束时间已过。
                            // 用 muted 而不是分类色：它不是分类信息，只是状态，不该跟分类抢注意力。
                            if (item.isCompleted) ...[
                              const SizedBox(width: 8),
                              Icon(
                                Icons.check_circle_outline,
                                key: ValueKey(
                                  'today-schedule-completed-${item.id}',
                                ),
                                size: 16,
                                color: PlannerPalette.textMuted,
                              ),
                            ],
                            // M4（路线图 §8）：卡片上的执行动作。
                            ..._actions(context),
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

  /// §8 的卡片动作区。
  ///
  /// **分工是刻意的**：
  /// - 「开始专注」「完成」是**当前安排**的主动作，直接做成按钮——§8 的退出条件要求
  ///   "从今日页开始专注不超过两次点击"（进页面 1 次 + 点按钮 1 次），藏进菜单就做不到；
  /// - 其余动作收进**一个菜单**：§8 明确要求"动作密度用菜单控制，不能每张卡片堆满按钮"。
  ///
  /// 端口为 `null` 时**不渲染**对应入口：渲染一个点了没反应的按钮，比不显示更糟
  /// （与 `TaskDetailPage` 对 `onStartFocus` 的处理一致）。
  List<Widget> _actions(BuildContext context) {
    final widgets = <Widget>[];

    // 主动作只给"任务"且"还没完成"的当前条目。
    // 已完成的任务不该再出现「完成」；固定日程与保护时间没有任务可做，因此一个都不给。
    if (isCurrent && _isTask && !item.isCompleted) {
      if (onStartFocus != null) {
        widgets.add(
          _CardAction(
            actionKey: Key('today-start-focus-${item.id}'),
            icon: Icons.play_arrow_rounded,
            label: '开始专注',
            onPressed: () => onStartFocus!(item),
          ),
        );
      }
      if (onComplete != null) {
        widgets.add(
          _CardAction(
            actionKey: Key('today-complete-${item.id}'),
            icon: Icons.check_rounded,
            label: '完成',
            onPressed: () => onComplete!(item),
          ),
        );
      }
    }

    // 菜单：详情／跳过本次／延后／请求调整／锁定。没有任何可用项时连按钮都不出现。
    final menuItems = <PopupMenuEntry<String>>[
      if (onOpenDetail != null)
        const PopupMenuItem(value: 'detail', child: Text('查看详情')),
      // 「跳过本次」（2026-10-07 用户定义）：只放弃这一个块，任务继续参与重排。
      // 只对**任务块**出现——固定日程与保护时间没有"要不要做"这回事。
      if (_isTask && onSkipCurrent != null)
        const PopupMenuItem(value: 'skip', child: Text('跳过本次')),
      if (_isTask && onDefer != null)
        const PopupMenuItem(value: 'defer', child: Text('延后')),
      if (_isMovable && onRequestAdjust != null)
        const PopupMenuItem(value: 'adjust', child: Text('请求调整')),
      if (_isMovable && onToggleLock != null)
        const PopupMenuItem(value: 'lock', child: Text('锁定')),
    ];
    if (menuItems.isNotEmpty) {
      widgets.add(
        PopupMenuButton<String>(
          key: Key('today-more-${item.id}'),
          tooltip: '更多操作',
          onSelected: (value) {
            switch (value) {
              case 'detail':
                onOpenDetail?.call(item);
              case 'skip':
                onSkipCurrent?.call(item);
              case 'defer':
                onDefer?.call(item);
              case 'adjust':
                onRequestAdjust?.call(item);
              case 'lock':
                onToggleLock?.call(item);
            }
          },
          itemBuilder: (context) => menuItems,
        ),
      );
    }
    return widgets;
  }
}

/// 卡片上的一个小动作按钮。
///
/// 用 `TextButton.icon` 而不是 `IconButton`：§8 的动作是给用户读的，
/// 光一个图标得靠猜（而且这一页此前已经因为"无文字控件"吃过亏）。
final class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Key actionKey;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: TextButton.icon(
      key: actionKey,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: PlannerPalette.textPrimary,
        backgroundColor: PlannerPalette.surfaceHover,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
  );
}

/// §8 的顶部重排提示。
///
/// **关闭只隐藏这条提示，不取消待确认方案**——因此这里不做任何"丢弃方案"的动作，
/// 只是把 `onDismiss` 交回去。隐藏之后方案仍在，用户可以去计划预览页处理。
final class _ReplanNotice extends StatelessWidget {
  const _ReplanNotice({this.onDismiss});

  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) => _Panel(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
      child: Row(
        children: [
          const Icon(
            Icons.auto_awesome_outlined,
            color: PlannerPalette.accent,
            size: 20,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '有一份新的安排建议待确认。可以先看看它改了什么。',
              style: TextStyle(color: PlannerPalette.textPrimary),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              key: const Key('today-replan-dismiss'),
              tooltip: '关闭这条提示',
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded),
              color: PlannerPalette.textSecondary,
            ),
        ],
      ),
    ),
  );
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
  const _PlanningRail({
    required this.items,
    required this.categorySummaries,
    required this.formatTime,
  });

  final List<ScheduleViewItem> items;
  final List<ScheduleCategorySummary> categorySummaries;
  final String Function(DateTime value) formatTime;

  @override
  Widget build(BuildContext context) {
    final current = _currentOrNext(items);
    final totalMinutes = items.fold<int>(
      0,
      (sum, item) => sum + item.range.durationMinutes,
    );
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
                        color: current.categoryColor,
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
                    '${formatTime(current.range.startUtc)}–${formatTime(current.range.endUtc)} · ${current.categoryLabel}',
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
                _CapacityBar(summaries: categorySummaries),
                const SizedBox(height: 14),
                for (
                  var index = 0;
                  index < categorySummaries.length;
                  index++
                ) ...[
                  if (index > 0) const SizedBox(height: 8),
                  _MetricRow(
                    key: ValueKey(
                      'today-capacity-category-${categorySummaries[index].categoryKey}',
                    ),
                    label: categorySummaries[index].categoryLabel,
                    value: _durationText(categorySummaries[index].minutes),
                    color: categorySummaries[index].categoryColor,
                  ),
                ],
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
  const _CapacityBar({required this.summaries});

  final List<ScheduleCategorySummary> summaries;

  @override
  Widget build(BuildContext context) {
    final total = summaries.fold<int>(0, (sum, item) => sum + item.minutes);
    if (total == 0) {
      return Container(
        key: const Key('today-capacity-bar'),
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
        key: const Key('today-capacity-bar'),
        height: 7,
        child: Row(
          // **`stretch` 必不可少**：`Row` 默认 `CrossAxisAlignment.center`，而每段是无子节点的
          // `ColoredBox`（内在高度 0），于是"有安排时"整条容量条会被量成 0 高、完全看不见——
          // 反而"当天没有安排"那条灰色底条是普通 `Container(height: 7)`，一直看得见。用户看到的
          // 现象就是"有数据时容量条消失"。这里靠 `stretch` 让各段铺满这 7 像素。
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final summary in summaries)
              if (summary.minutes > 0)
                Expanded(
                  flex: summary.minutes,
                  child: ColoredBox(color: summary.categoryColor),
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
    super.key,
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
