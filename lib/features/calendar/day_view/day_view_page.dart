import 'package:flutter/material.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/calendar_event_edit.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
import 'package:personal_planner/features/calendar/schedule_category_legend.dart';
import 'package:personal_planner/features/calendar/schedule_category_summary.dart';
import 'package:personal_planner/design/planner_date_time_fields.dart';
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
    this.onEditEvent,
    this.onSetEventArea,
    this.loadAreaOptions,
    this.highlightEventId,
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

  /// **改写**某一次／此次及以后／整个系列（FR-CAL-02；计划 Task 8 Step 3）。
  ///
  /// **三个范围合成一个回调**：范围只是请求上的一个字段，而写入的取舍
  /// （写例外还是改锚点与规则、要不要做并发校验）全在用例层。
  ///
  /// 分成三个回调时它们各自成型，于是**没有位置放备注与修订号**——而这正是
  /// "改了名保存后一切照旧"与"填了备注却消失"两个缺陷的来源。
  /// 交回的是**本地时刻**：与 `onDeleteOccurrence` 同理，页面不做时区换算，
  /// 换算由注入方（持有 `TimeZoneDatabase` 的路由）负责。
  ///
  /// 为空时列表里不出现编辑入口。
  final Future<OccurrenceEditOutcome> Function(OccurrenceEditRequest request)?
  onEditEvent;

  final VoidCallback? onOpenWeek;

  /// 调整固定日程的**所属领域**（`null` 取消归属）。返回是否改成功。
  ///
  /// 领域是整条日程的属性，与"改这一次"不同路，因此单独一个回调而不是塞进改写回调里。
  final Future<bool> Function(String eventId, String? areaId)? onSetEventArea;

  /// 可选领域清单（供"调整归属"对话框使用）。为空时不显示该入口。
  final Future<List<ScheduleAreaOption>> Function()? loadAreaOptions;

  /// 要**定位**的那一条固定日程的领域事件 id（M1，路线图 §3.2）。
  ///
  /// §3.2 要求"固定日程进入对应日期的日视图，**并定位该日程**；若定位暂时做不到，
  /// 至少进入正确日期"。路由因此把 [DayOpenTarget.eventId] 作为 `?event=` 传下来，
  /// 这一页据此把那一条**标记出来**——用户从今日页点了一条 8:00 的课，落到日视图时
  /// 那一条会被高亮，而不是让他在十几条里自己找。
  ///
  /// 为空时（从周视图、或手工输入 URL 进来）页面与从前完全一样。
  final String? highlightEventId;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<ScheduleViewItem>>(
    stream: source.watch(dayStartUtc, dayStartUtc.add(const Duration(days: 1))),
    builder: (context, snapshot) {
      final localDay = zones.toLocal(dayStartUtc, timeZoneId);
      final items = [...?snapshot.data]
        ..sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
      final summaries = summarizeScheduleCategories(items);
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
            if (summaries.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerRight,
                child: ScheduleCategoryLegend(summaries: summaries),
              ),
              const SizedBox(height: 12),
            ],
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
                    // 提升为局部变量：公开字段不会被 Dart 提升为不可空，直接判空过不了类型检查。
                    final setArea = onSetEventArea;
                    final loadOptions = loadAreaOptions;
                    // M1（§3.2）的"定位该日程"：从今日页点进来的那一条会被标记出来。
                    // 判定用**领域事件 id**（`fixedEventId`）而不是条目 id——路由传下来的是
                    // 领域 id，条目 id 带着 `fixed:` 命名空间，直接比会永远不相等。
                    final isHighlighted =
                        highlightEventId != null && eventId == highlightEventId;
                    return Container(
                      key: isHighlighted
                          ? const Key('day-highlighted-item')
                          : null,
                      // 用**描边**而不是底色：这一页的卡片底色已经承载了分类信息
                      // （领域色/保护色），改底色会让"被定位的那一条"看起来像换了分类。
                      decoration: isHighlighted
                          ? BoxDecoration(
                              border: Border.all(
                                color: PlannerPalette.accent,
                                width: 2,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            )
                          : null,
                      child: Row(
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
                              tooltip: eventId == null
                                  ? '只有固定日程可以删除'
                                  : '删除这条日程',
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
                          if (setArea != null && loadOptions != null)
                            IconButton(
                              key: Key('area-${item.id}'),
                              tooltip: eventId == null
                                  ? '只有固定日程可以调整归属'
                                  : '调整所属领域',
                              icon: const Icon(Icons.folder_outlined),
                              onPressed: eventId == null
                                  ? null
                                  : () => _chooseArea(
                                      context,
                                      item,
                                      eventId: eventId,
                                      onSetEventArea: setArea,
                                      loadAreaOptions: loadOptions,
                                    ),
                            ),
                          if (onEditEvent != null)
                            IconButton(
                              key: Key('edit-${item.id}'),
                              // **不再说"只有固定日程可以改写"**：保护时间也走这一条路
                              // （计划 Task 8 Step 3），而那句提示会让用户以为保护时间不能改。
                              tooltip: '改这一次、此次及以后或整个系列',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: eventId == null
                                  ? null
                                  : () => _editOccurrence(
                                      context,
                                      item,
                                      eventId: eventId,
                                      onEditEvent: onEditEvent,
                                      zones: zones,
                                      timeZoneId: timeZoneId,
                                    ),
                            ),
                        ],
                      ),
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
/// 一次"改写这一次／此次及以后／整个系列"的请求（计划 Task 8 Step 3）。
///
/// ## 为什么把它收成一个类型
///
/// 此前这条路上有三个各自成形回调（`onReplaceOccurrence` / `...Following` / `...Series`），
/// 而它们**只能传时间与标题**：备注根本没有位置放，修订号也没有。于是
///
/// - 日视图对话框收得到备注，却传不出去（`OccurrenceEditResult.notes` 无人使用）；
/// - "只改这一次"走的还是 `@Deprecated` 的包装器，它靠一张**进程内标题缓存**猜
///   "这条事项叫什么"，冷启动时猜不到就只能写占位文字「未命名事项」。
///
/// 一个请求对象把这三件事一次说清：**改哪一个范围、改哪一次、改成什么样**。
/// 界面只负责填它，写入的取舍（写例外还是改规则、要不要做并发校验）留给用例层。
final class OccurrenceEditRequest {
  const OccurrenceEditRequest({
    required this.anchorId,
    required this.scope,
    required this.occurrenceStartUtc,
    required this.draft,
    this.expectedUpdatedAtUtc,
  });

  /// 要改的**锚点**（系列的根），不是这一次的 id。
  final String anchorId;

  final EventEditScope scope;

  /// 被编辑的那一次的发生时刻。`entireSeries` 时为 `null`——
  /// "整条系列"不指向某一次，硬塞一个时刻会让写入端以为要按它定位。
  final DateTime? occurrenceStartUtc;

  final CalendarEventEditDraft draft;

  /// 页面读到这一条时的修订号（空表示"无从判断"，跳过过期检测）。
  final DateTime? expectedUpdatedAtUtc;
}

/// 一次改写在界面上的结果。
///
/// **三态而不是布尔**：`失败`（可以重试）与 `已过期`（必须重新打开）对用户要做的事
/// 完全不同。压成一个 `false` 会让界面只能说"没成功"，用户于是反复重试同一件
/// 永远不会成功的事——而正确的动作是关掉重开。
enum OccurrenceEditOutcome { saved, stale, failed }

Future<void> _editOccurrence(
  BuildContext context,
  ScheduleViewItem item, {
  required String eventId,
  required Future<OccurrenceEditOutcome> Function(
    OccurrenceEditRequest request,
  )?
  onEditEvent,
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) async {
  final edit = onEditEvent;
  if (edit == null) return;
  final result = await showDialog<OccurrenceEditResult>(
    context: context,
    // 控制器由对话框**自己**持有并释放。在 `showDialog` 返回后立刻 dispose 会在退出动画
    // 期间触发 "A TextEditingController was used after being disposed"——本文件第一版正是
    // 这样写的，五条既有用例一起把它顶了出来。
    builder: (dialogContext) => _OccurrenceEditDialog(
      title: item.title,
      initialNotes: item.notes,
      initialStartUtc: item.range.startUtc,
      initialEndUtc: item.range.endUtc,
      zones: zones,
      timeZoneId: timeZoneId,
      // **只给真正的重复系列显示范围选项**：一次性的保护时间上摆三个同义选项，
      // 用户会以为"仅本次"与"整个系列"不同，而它们对一条没有规则的事项是同一件事。
      allowsFollowing: item.repeats,
      allowsWholeSeries: item.repeats,
    ),
  );
  if (result == null) return;

  final outcome = await edit(
    OccurrenceEditRequest(
      anchorId: eventId,
      scope: result.scope,
      occurrenceStartUtc: result.scope == EventEditScope.entireSeries
          ? null
          : item.range.startUtc,
      draft: CalendarEventEditDraft(
        title: result.title,
        // **备注也一起带出去**（计划 §1.2）：此前对话框收得到它、回调却没有位置放，
        // 于是用户在这一次上填的备注点保存之后就消失了。
        notes: result.notes,
        startAtUtc: result.startUtc,
        endAtUtc: result.endUtc,
        timeZoneId: timeZoneId,
        // **类别必须从条目种类翻译过来，不能直接传**：`ScheduleItemKind` 是**视图**层的
        // 枚举（还包含任务块、专注块等），而 `CalendarEventKind` 是**领域**层的两值枚举。
        // 直接传在类型上就不成立；而"保护时间被改写成固定日程"会让它从此进入投入统计
        // （规范 §9.1 明确保护时间不计入任何投入）。
        kind: item.kind == ScheduleItemKind.protectedTime
            ? CalendarEventKind.protected
            : CalendarEventKind.fixed,
      ),
      expectedUpdatedAtUtc: item.updatedAtUtc,
    ),
  );
  if (!context.mounted) return;
  switch (outcome) {
    case OccurrenceEditOutcome.saved:
      return;
    case OccurrenceEditOutcome.stale:
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          key: Key('occurrence-edit-stale'),
          content: Text('这一条在别处已被修改，请关掉重新打开后再改。'),
        ),
      );
    case OccurrenceEditOutcome.failed:
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          key: Key('occurrence-edit-failed'),
          content: Text('这次改写没有成功，原内容未改变，请重试。'),
        ),
      );
  }
}

/// 选择领域并保存（`null` 表示取消归属）。
///
/// 返回值包一层是为了区分"取消对话框"与"选择不归属领域"——两者都是 `null` 的话，
/// 取消会被误当成一次真实的清空操作。
final class _AreaSelection {
  const _AreaSelection(this.areaId);

  final String? areaId;
}

Future<void> _chooseArea(
  BuildContext context,
  ScheduleViewItem item, {
  required String eventId,
  required Future<bool> Function(String eventId, String? areaId) onSetEventArea,
  required Future<List<ScheduleAreaOption>> Function() loadAreaOptions,
}) async {
  final options = await loadAreaOptions();
  if (!context.mounted) return;
  final selection = await showDialog<_AreaSelection>(
    context: context,
    builder: (dialogContext) => _AreaPickerDialog(
      title: item.title,
      options: options,
      initialAreaId: item.areaId,
    ),
  );
  if (selection == null) return;
  final saved = await onSetEventArea(eventId, selection.areaId);
  if (!context.mounted) return;
  showPlannerMessage(context, message: saved ? '已调整归属' : '暂时无法调整归属，请稍后再试');
}

/// "调整归属"对话框：一个领域下拉 + 取消归属。
final class _AreaPickerDialog extends StatefulWidget {
  const _AreaPickerDialog({
    required this.title,
    required this.options,
    this.initialAreaId,
  });

  final String title;
  final List<ScheduleAreaOption> options;
  final String? initialAreaId;

  @override
  State<_AreaPickerDialog> createState() => _AreaPickerDialogState();
}

final class _AreaPickerDialogState extends State<_AreaPickerDialog> {
  String? _areaId;

  @override
  void initState() {
    super.initState();
    // 预选当前归属，但只在它确实还在选项里时（领域可能已被删除）。
    final initial = widget.initialAreaId;
    _areaId = widget.options.any((option) => option.id == initial)
        ? initial
        : null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('area-picker-dialog'),
    title: Text('调整「${widget.title}」的归属'),
    content: DropdownButtonFormField<String>(
      key: const Key('area-picker'),
      initialValue: _areaId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '所属领域', hintText: '不归属领域'),
      items: [
        const DropdownMenuItem(value: null, child: Text('不归属领域')),
        for (final option in widget.options)
          DropdownMenuItem(value: option.id, child: Text(option.name)),
      ],
      onChanged: (value) => setState(() => _areaId = value),
    ),
    actions: [
      TextButton(
        key: const Key('area-picker-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('area-picker-save'),
        onPressed: () => Navigator.of(context).pop(_AreaSelection(_areaId)),
        child: const Text('保存'),
      ),
    ],
  );
}

/// 改写某一次的对话框：**日期、时间、标题与备注都可改**（1.8.0，规范 §2.7／§8.1；
/// 课程与保护时间管理修复计划 §2.3）。
///
/// 此前这里是两个文本框，要求用户敲 `YYYY-MM-DD HH:mm`。改成选择器之后，
/// 日视图与固定日程编辑器（`EventEditorForm`）用的是**同一个组件与同一套校验**，
/// 这正是规范 §8.2 最后一句要求的"复用同一组件和校验"。
///
/// **标题与备注是本轮补上的**（计划 §1.2／§2.3）：对话框此前只有日期与时间，
/// 保存时把原 `item.title` **原样传回**，于是"改名"在界面上根本无从发生——
/// 用户改了框里的字，保存之后一切照旧；而备注连框都没有。
final class _OccurrenceEditDialog extends StatefulWidget {
  const _OccurrenceEditDialog({
    required this.title,
    required this.initialStartUtc,
    required this.initialEndUtc,
    required this.zones,
    required this.timeZoneId,
    this.initialNotes = '',
    this.allowsFollowing = false,
    this.allowsWholeSeries = false,
  });

  final String title;

  /// 当前备注，**预填**进备注框。
  ///
  /// 课表导入把教师名写在这一列里，因此它常常不是空的；显示空框会让用户
  /// 以为备注丢了，从而重新输入一遍。
  final String initialNotes;

  /// 这一段的**本地**起止。由调用方按事项时区换算好再交进来，
  /// 对话框因此不需要自己认识时区。
  final DateTime initialStartUtc;
  final DateTime initialEndUtc;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final bool allowsFollowing;

  /// 是否允许选"改整个系列"。未注入对应回调时为 false——**不给一个选了也不生效的勾选框**。
  final bool allowsWholeSeries;

  @override
  State<_OccurrenceEditDialog> createState() => _OccurrenceEditDialogState();
}

/// 对话框返回的编辑结果：标题、备注与两个**UTC**时刻，外加作用范围。
///
/// **为什么不再用 `(DateTime, DateTime, scope)` 元组**：加上标题与备注之后是五个值，
/// 位置元组在调用点会变成一串难以核对的下标（`$1`…`$5`）。具名字段让
/// "哪一个是标题"在类型上就说得清。
final class OccurrenceEditResult {
  const OccurrenceEditResult({
    required this.title,
    required this.notes,
    required this.startUtc,
    required this.endUtc,
    required this.scope,
  });

  final String title;
  final String notes;
  final DateTime startUtc;
  final DateTime endUtc;
  final EventEditScope scope;
}

final class _OccurrenceEditDialogState extends State<_OccurrenceEditDialog> {
  late final LocalDateRangeController _range;
  late final TextEditingController _title;
  late final TextEditingController _notes;
  String? _error;
  EventEditScope _scope = EventEditScope.singleOccurrence;

  @override
  void initState() {
    super.initState();
    final start = widget.zones.toLocal(
      widget.initialStartUtc,
      widget.timeZoneId,
    );
    final end = widget.zones.toLocal(widget.initialEndUtc, widget.timeZoneId);
    _range = LocalDateRangeController(
      startDate: start,
      startTime: TimeOfDay(hour: start.hour, minute: start.minute),
      endDate: end,
      endTime: TimeOfDay(hour: end.hour, minute: end.minute),
    )..addListener(_onRangeChanged);
    _title = TextEditingController(text: widget.title);
    _notes = TextEditingController(text: widget.initialNotes);
  }

  void _onRangeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _range
      ..removeListener(_onRangeChanged)
      ..dispose();
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    // **在对话框内校验**：结束不晚于开始时留在对话框里说明，而不是把非法区间交给
    // 下游、让用户在外面收到一个更含糊的错误（规范 §8.2：不做静默猜测）。
    if (_range.endsNotAfterStart) {
      setState(() {
        _error = _range.crossesMidnight
            ? '结束时间必须晚于开始时间'
            : '结束时间不晚于开始时间。若跨到次日，请把结束日期改到次日。';
      });
      return;
    }
    // **标题必填**：空标题会让卡片变成一片空白，用户分不清"这条没名字"与"渲染失败"。
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '标题不能为空');
      return;
    }
    final startUtc = widget.zones.localDateTimeToUtc(
      _range.startDate,
      _range.startTime.hour * 60 + _range.startTime.minute,
      widget.timeZoneId,
    );
    final endUtc = widget.zones.localDateTimeToUtc(
      _range.endDate,
      _range.endTime.hour * 60 + _range.endTime.minute,
      widget.timeZoneId,
    );
    Navigator.of(context).pop(
      OccurrenceEditResult(
        title: title,
        notes: _notes.text.trim(),
        startUtc: startUtc,
        endUtc: endUtc,
        scope: _scope,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('改「${widget.title}」的这一次'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题与备注在前：它们是"这次改了什么"里用户最先说得出的两件事。
          SizedBox(
            width: 320,
            child: TextField(
              key: const Key('occurrence-title'),
              controller: _title,
              decoration: const InputDecoration(labelText: '标题'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 320,
            child: TextField(
              key: const Key('occurrence-notes'),
              controller: _notes,
              decoration: const InputDecoration(labelText: '备注'),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 200,
                child: PlannerDateField(
                  key: const Key('occurrence-start-date'),
                  boxKey: const Key('occurrence-start-date-box'),
                  value: _range.startDate,
                  label: '开始日期',
                  onChanged: _range.setStartDate,
                ),
              ),
              SizedBox(
                width: 150,
                child: PlannerTimeField(
                  key: const Key('occurrence-start-time'),
                  boxKey: const Key('occurrence-start-time-box'),
                  value: _range.startTime,
                  label: '开始时间',
                  onChanged: _range.setStartTime,
                ),
              ),
              SizedBox(
                width: 200,
                child: PlannerDateField(
                  key: const Key('occurrence-end-date'),
                  boxKey: const Key('occurrence-end-date-box'),
                  value: _range.endDate,
                  label: '结束日期',
                  onChanged: _range.setEndDate,
                ),
              ),
              SizedBox(
                width: 150,
                child: PlannerTimeField(
                  key: const Key('occurrence-end-time'),
                  boxKey: const Key('occurrence-end-time-box'),
                  value: _range.endTime,
                  label: '结束时间',
                  onChanged: _range.setEndTime,
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              key: const Key('occurrence-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (widget.allowsFollowing || widget.allowsWholeSeries) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  key: const Key('occurrence-scope-single'),
                  label: const Text('仅本次'),
                  selected: _scope == EventEditScope.singleOccurrence,
                  onSelected: (_) =>
                      setState(() => _scope = EventEditScope.singleOccurrence),
                ),
                if (widget.allowsFollowing)
                  ChoiceChip(
                    key: const Key('occurrence-scope-following'),
                    label: const Text('本次及以后'),
                    selected: _scope == EventEditScope.followingOccurrences,
                    onSelected: (_) => setState(
                      () => _scope = EventEditScope.followingOccurrences,
                    ),
                  ),
                if (widget.allowsWholeSeries)
                  ChoiceChip(
                    key: const Key('occurrence-scope-series'),
                    label: const Text('整个系列'),
                    selected: _scope == EventEditScope.entireSeries,
                    onSelected: (_) =>
                        setState(() => _scope = EventEditScope.entireSeries),
                  ),
              ],
            ),
          ],
        ],
      ),
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
    // 与七日历、今日共用同一个派生器：同一事项在三个视图里必须逐值同色。
    final visual = scheduleCategoryCardStyle(item.categoryColor);
    return Semantics(
      key: Key('day-item-${item.id}'),
      container: true,
      excludeSemantics: true,
      label:
          '${item.title}，${_clock(start)}到${_clock(end)}，${item.categoryLabel}，${item.kind.label}'
          '${item.isCompleted ? '，已完成' : ''}',
      child: Card(
        key: Key('day-schedule-card-${item.id}'),
        color: visual.fill,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: visual.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListTile(
          leading: Icon(item.kind.icon, color: visual.accent),
          title: Text(item.title),
          subtitle: Text(
            [
              '${_clock(start)}–${_clock(end)}',
              item.categoryLabel,
              ?item.explanation,
            ].join(' · '),
          ),
          // 「已完成」标记：任务勾选完成、或固定日程时间已过。muted 色，不抢分类色。
          trailing: item.isCompleted
              ? Icon(
                  Icons.check_circle_outline,
                  key: Key('day-schedule-completed-${item.id}'),
                  color: PlannerPalette.textMuted,
                )
              : null,
        ),
      ),
    );
  }

  static String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}
