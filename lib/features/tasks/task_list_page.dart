import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_pickers.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/features/tasks/task_list_filter.dart';
import 'package:personal_planner/features/tasks/task_list_time_format.dart';

final class TaskListPage extends StatefulWidget {
  const TaskListPage({
    required this.service,
    required this.nowUtc,
    this.plans,
    this.zones,
    this.timeZoneId,
    this.onSetDueDateForSelection,
    this.onGeneratePlan,
    super.key,
  });
  final TaskService service;

  /// 用于派生"已逾期"（R12）：该状态不落库，只取决于"截止已过且任务未结束"，
  /// 因此必须显式传入当前时刻，不能由页面各自读时钟决定。
  final DateTime nowUtc;

  /// **当前确认计划**的唯一来源，用来判断"是否已安排"（§10）。
  ///
  /// 可以为空：不带数据库的装配（例如只构造 `PlannerApp()` 的测试）下页面仍须可用，
  /// 此时所有未完成任务临时归入"待安排"——不崩溃、也不无限转圈。
  ///
  /// 刻意收 `PlanRepository` 而不是新建一套计划服务：`current()` 已经是"当前确认计划"
  /// 的既有出口，再开一个来源就等于给同一个事实建两个出口。
  final PlanRepository? plans;

  /// 用于把计划块与截止时间换算成用户读的本地钟点。为空时退回系统时区。
  ///
  /// 与今日页、周视图同一约定：**页面不认识时区**，换算由注入方（持有
  /// `TimeZoneDatabase` 的路由）负责。
  final TimeZoneDatabase? zones;
  final String? timeZoneId;

  /// 批量设置截止日期的入口（FR-TASK-03 的"批量调整"最后一环）。为空时不显示该控件。
  ///
  /// 签名收的是**一组任务 id 加一个本地日期与分钟**，而不是逐条回调：整批共用同一天，
  /// 换算因此只需做一次。与"设置截止时间"同理，**页面不认识时区**——本地日期到 UTC 的
  /// 换算由注入方（持有 `TimeZoneDatabase` 的路由）完成。
  final Future<bool> Function(
    List<String> taskIds,
    DateTime localDate,
    int minute,
  )?
  onSetDueDateForSelection;

  /// "已安排为空"空状态里的**生成计划**入口（§7）。为空时不显示该按钮。
  final VoidCallback? onGeneratePlan;

  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

final class _TaskListPageState extends State<TaskListPage> {
  String _query = '';

  /// 批量操作（FR-TASK-03 要求支持"批量调整和状态变更"）。
  ///
  /// 进入多选后，点整行是"选中／取消选中"而不是"完成"——两者都是"点一行"的自然含义，
  /// 同时生效会让用户无法预料点击结果，因此进入多选就明确切换语义，并在退出时清空选择。
  bool _selecting = false;
  final Set<String> _selected = {};
  String? _batchMessage;

  TaskSort _sort = TaskSort.none;

  /// 当前筛选项。默认"全部"（§3）。
  TaskListFilter _filter = TaskListFilter.all;

  /// 当前确认计划里尚未结束的时间块。**异步**，因此加载完成前先用空视图：
  /// 空视图的含义正是"所有未完成任务都归入待安排"，与"还没有计划"是同一件事。
  TaskScheduleWindow _schedule = TaskScheduleWindow.empty();

  @override
  void initState() {
    super.initState();
    _reloadPlan();
  }

  @override
  void didUpdateWidget(covariant TaskListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // §11：`plans` 或 `nowUtc` 变化时必须重算。`nowUtc` 参与"块是否尚未结束"，
    // 因此时刻推进本身就能让一个"已安排"的任务变成"待安排"。
    if (oldWidget.plans != widget.plans || oldWidget.nowUtc != widget.nowUtc) {
      _reloadPlan();
    }
  }

  Future<void> _reloadPlan() async {
    final plans = widget.plans;
    if (plans == null) {
      if (_schedule.taskIds.isEmpty) return;
      setState(() => _schedule = TaskScheduleWindow.empty());
      return;
    }
    final ConfirmedPlan? plan;
    try {
      plan = await plans.current();
    } catch (_) {
      // 计划读不出来不该让整个清单页变成错误页：任务本身仍然可看、可完成、可恢复。
      // 此时按"没有已安排任务"处理，而不是把异常吞成"全是已安排"。
      if (!mounted) return;
      setState(() => _schedule = TaskScheduleWindow.empty());
      return;
    }
    if (!mounted) return;
    setState(() {
      _schedule = plan == null
          ? TaskScheduleWindow.empty()
          : TaskScheduleWindow.fromBlocks([
              for (final block in plan.blocks)
                (
                  taskId: block.taskId,
                  startUtc: block.startUtc,
                  endUtc: block.endUtc,
                ),
            ], nowUtc: widget.nowUtc);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('任务清单', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('new-task'),
              onPressed: () => context.go('/tasks/new'),
              icon: const Icon(Icons.add_rounded),
              label: const Text('新建任务'),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SearchBar(
                  hintText: '搜索任务',
                  leading: const Icon(Icons.search),
                  onChanged: (value) => setState(() => _query = value.trim()),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<TaskSort>(
                key: const Key('task-sort'),
                value: _sort,
                onChanged: (value) =>
                    setState(() => _sort = value ?? TaskSort.none),
                items: const [
                  DropdownMenuItem(value: TaskSort.none, child: Text('默认顺序')),
                  DropdownMenuItem(
                    value: TaskSort.dueDate,
                    child: Text('按截止时间'),
                  ),
                  DropdownMenuItem(
                    value: TaskSort.priority,
                    child: Text('按优先级'),
                  ),
                  DropdownMenuItem(
                    value: TaskSort.estimatedMinutes,
                    child: Text('按预计时长'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildFilterBar(),
          const SizedBox(height: 12),
          _buildBatchBar(),
          if (_batchMessage != null) ...[
            const SizedBox(height: 8),
            Text(_batchMessage!),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: StreamBuilder<List<PlannerTask>>(
              stream: widget.service.watchAllTasks(),
              builder: (context, snapshot) {
                // 仍是 null 表示**首帧尚未到达**。此前只有"有数据"与"空"两种结果，
                // 因此"还没加载出来"与"真的没有任务"被显示成同一句话（§7）。
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final allTasks = snapshot.data!;
                // 数量**必须**在文字搜索之前算（§5）：搜到一个任务时，筛选栏仍然要显示
                // "全部 8　待安排 2　已安排 4　已完成 2"。
                final counts = countTaskListBuckets(
                  allTasks,
                  schedule: _schedule,
                );
                final visible = filterTaskList(
                  allTasks,
                  filter: _filter,
                  schedule: _schedule,
                  query: _query,
                  sort: _sort,
                );
                if (visible.isEmpty) {
                  return _buildEmptyState(counts[TaskListFilter.all] ?? 0);
                }
                return ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final task = visible[index];
                    return _buildTile(task);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 筛选栏（§3）：搜索框下方、任务列表上方。
  ///
  /// **为什么不用 `SegmentedButton`**（专项计划 §3 曾建议它）：实测它的语义树里**每个分段
  /// 各有两个同名 button 节点**——`segmented_button.dart` 对每个分段同时做了
  /// `MergeSemantics(Semantics(selected: …))` **和**一个 `TextButton`（自身也产生 button
  /// 角色与同一个名称），于是屏幕阅读器把每个筛选项念两遍，自动化工具里同一控件出现两次。
  ///
  /// 改用一个 `ChoiceChip` 一行：实测它的语义形状是**一段一个节点**，同时带
  /// `isButton` 与 `isSelected`，因此"名称 + 角色 + 选中状态"三项都由同一个节点给出。
  /// 选择语义仍然成立（单选、互斥），键盘焦点与 Enter/Space 激活由 `ChoiceChip` 自带。
  ///
  /// 颜色仍然只由主题给：选中态用主色填充，**不为四个筛选项发明四种高饱和颜色**（§3 末两条）。
  Widget _buildFilterBar() {
    // 窄窗口下横向滚动而不是把文字压重叠：每个 chip 都不换行，
    // 给它一个可滚动容器比允许它被挤压更安全。
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: StreamBuilder<List<PlannerTask>>(
        stream: widget.service.watchAllTasks(),
        builder: (context, snapshot) {
          final counts = countTaskListBuckets(
            snapshot.data ?? const <PlannerTask>[],
            schedule: _schedule,
          );
          return Row(
            key: const Key('task-filter'),
            children: [
              for (final filter in TaskListFilter.values) ...[
                if (filter != TaskListFilter.values.first)
                  const SizedBox(width: 8),
                ChoiceChip(
                  key: Key('task-filter-${filter.name}'),
                  label: Text(
                    '${_filterLabel(filter)} ${counts[filter] ?? 0}',
                    key: Key('task-filter-${filter.name}-label'),
                  ),
                  selected: _filter == filter,
                  onSelected: (_) => _changeFilter(filter),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 切换筛选项（§6）：**必须退出多选并清空已选择任务**。
  ///
  /// 不清空的后果是具体的：在"待安排"里选了两条，切到"已完成"后那两条不在列表中，
  /// 但批量按钮仍然显示"已选 2"并会真的作用于它们——用户看不到自己正在改什么。
  void _changeFilter(TaskListFilter filter) {
    if (filter == _filter) return;
    setState(() {
      _filter = filter;
      _selecting = false;
      _selected.clear();
      _batchMessage = null;
    });
  }

  Widget _buildBatchBar() {
    // "已完成"筛选中隐藏"多选"按钮（§6）：那一页只有已完成任务，
    // 而多选在"全部"里本来就拒绝勾选已完成任务，因此留在那里只会是一个永远勾不上的入口。
    if (_filter == TaskListFilter.completed) return const SizedBox.shrink();
    return Row(
      children: [
        TextButton.icon(
          key: const Key('toggle-batch-mode'),
          onPressed: () => setState(() {
            _selecting = !_selecting;
            _selected.clear();
            _batchMessage = null;
          }),
          icon: Icon(_selecting ? Icons.close : Icons.checklist),
          label: Text(_selecting ? '退出多选' : '多选'),
        ),
        if (_selecting) ...[
          const SizedBox(width: 8),
          Text('已选 ${_selected.length}'),
          const Spacer(),
          // FR-TASK-03 的"批量调整"里的**字段改写**：状态变更在右侧，这里改优先级。
          // 文案用内联 switch 生成，避免为一个控件新增一个只有 4 个分支的辅助函数。
          DropdownButton<TaskPriority>(
            key: const Key('batch-priority'),
            hint: const Text('设为优先级'),
            onChanged: _selected.isEmpty
                ? null
                : (value) {
                    if (value != null) _setPriorityForSelected(value);
                  },
            items: [
              for (final priority in TaskPriority.values)
                DropdownMenuItem(
                  value: priority,
                  child: Text(switch (priority) {
                    TaskPriority.low => '低',
                    TaskPriority.medium => '中',
                    TaskPriority.high => '高',
                    TaskPriority.urgent => '紧急',
                  }),
                ),
            ],
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            key: const Key('batch-due-date'),
            onPressed:
                widget.onSetDueDateForSelection == null || _selected.isEmpty
                ? null
                : () async {
                    // 页面只交出本地日期与"当天第几分钟"；换算与写入都在注入方那边，
                    // 且整批只换算一次（见字段说明）。
                    final picked = await showDatePicker(
                      builder: plannerPickerBuilder,
                      context: context,
                      initialDate: widget.nowUtc,
                      firstDate: DateTime(widget.nowUtc.year - 1),
                      lastDate: DateTime(widget.nowUtc.year + 5),
                    );
                    if (picked == null) return;
                    final ids = [..._selected];
                    final allSaved = await widget.onSetDueDateForSelection!(
                      ids,
                      picked,
                      1439,
                    );
                    if (!mounted) return;
                    setState(() {
                      _selected.clear();
                      _batchMessage = allSaved
                          ? '已把 ${ids.length} 项设为该截止日期'
                          : '部分任务设置失败';
                    });
                  },
            icon: const Icon(Icons.event_available_outlined),
            label: const Text('统一设为截止日期'),
          ),
          const SizedBox(width: 12),
          FilledButton.tonal(
            key: const Key('batch-cancel'),
            // 空集合时禁用：给出一个作用不到任何对象的按钮只会让人怀疑它坏了。
            onPressed: _selected.isEmpty ? null : _cancelSelected,
            child: const Text('取消所选项'),
          ),
        ],
      ],
    );
  }

  Widget _buildTile(PlannerTask task) {
    // "全部"里已完成任务不可勾选（§6）：勾选框表达的是"完成／恢复"，
    // 而"全部"这一栏同时承载待安排与已安排，把已完成也做成可点会让用户误以为
    // 点一下就能改掉什么。恢复入口在"已完成"筛选与详情页里。
    final lockedInAll =
        _filter == TaskListFilter.all && task.status == TaskStatus.completed;
    final checked = _selecting
        ? _selected.contains(task.id)
        : task.status == TaskStatus.completed;
    final enabled = _selecting || !lockedInAll;

    void toggle() {
      if (!enabled) return;
      if (_selecting) {
        setState(() {
          if (checked) {
            _selected.remove(task.id);
          } else {
            _selected.add(task.id);
          }
        });
        return;
      }
      widget.service.changeStatus(
        task.id,
        checked ? TaskStatus.open : TaskStatus.completed,
      );
    }

    // **为什么从 `CheckboxListTile` 改成 `ListTile` + 独立 `Checkbox`**（M2 缺陷 A2-1）：
    // `CheckboxListTile` 会把 `secondary` 槽里的东西**并进它自己的语义节点**，于是
    // "详情"入口不可能成为一个独立控件——实测结果是它被并进整行的 label，剩下的按钮
    // 是个**没有名称**的节点，屏幕阅读器只读得出"按钮"。
    //
    // `ListTile` + `leading: Checkbox` + `trailing: 详情按钮` 实测得到**两个各自完整的
    // 控件**：一行是带标题与副标题的可勾选控件，另一行是名称里带任务标题的按钮。
    // 顺带修掉一个更早的毛病：此前详情按钮**嵌在整行可勾选区域里面**，键盘用户在一个
    // "会改变任务状态"的区域内部按回车，落点取决于嵌套顺序。
    return ListTile(
      leading: Checkbox(
        value: checked,
        onChanged: enabled ? (_) => toggle() : null,
      ),
      title: Text(task.title),
      subtitle: Text(
        taskListSubtitle(
          task,
          schedule: _schedule,
          nowUtc: widget.nowUtc,
          formatRange: (startUtc, endUtc) => formatPlannedRange(
            startUtc,
            endUtc,
            zones: widget.zones,
            timeZoneId: widget.timeZoneId,
          ),
          formatDue: (dueAtUtc) => formatTaskDue(
            dueAtUtc,
            zones: widget.zones,
            timeZoneId: widget.timeZoneId,
          ),
        ),
      ),
      onTap: enabled ? toggle : null,
      trailing: _TileActionButton(
        label: '查看「${task.title}」详情',
        actionKey: Key('task-detail-${task.id}'),
        onPressed: () => context.go('/tasks/${task.id}'),
      ),
    );
  }

  /// 空状态（§7）：四种筛选各自说清"为什么这里是空的"，而不是一律"暂无匹配任务"。
  ///
  /// [allCount] 用来区分"一个任务都没有"与"这一类是空的"。
  Widget _buildEmptyState(int allCount) {
    final String message;
    String? hint;
    Widget? action;

    if (allCount == 0 && _query.isEmpty) {
      // 只有"一个任务都没有且用户没在搜索"才说"还没有任务"。
      // 若用户正在搜索，下面那条"没有找到…"才是他该看到的回答。
      message = '还没有任务';
      hint = '用上面的"新建任务"添加第一项';
      action = FilledButton.icon(
        key: const Key('empty-new-task'),
        onPressed: () => context.go('/tasks/new'),
        icon: const Icon(Icons.add_rounded),
        label: const Text('新建任务'),
      );
    } else if (_query.isNotEmpty) {
      // 搜索无结果优先于"某一类为空"：用户刚输入了关键词，
      // 此时"没有待安排任务"是误导（他筛的那一类里其实有任务，只是都不匹配）。
      message = '没有找到"$_query"';
      action = TextButton(
        key: const Key('clear-search'),
        onPressed: () => setState(() => _query = ''),
        child: const Text('清除搜索条件'),
      );
    } else {
      switch (_filter) {
        case TaskListFilter.all:
          // "全部"是三个可见分组的并集，因此它为空只有一种原因：所有任务都被排除
          // （跳过／取消）。这与"还没有任务"是不同的事实，不该混为一谈——前者是
          // "都被归档了"，后者是"还没建过"。
          //
          // **这句提示的措辞改进（点明"记录仍然保留"＋补一条针对"最后一条未完成任务被
          // 完成掉"这个更常见的路径的断言）留给下一批**：`1.6.1+36` 的安装包已经构建、
          // 安装并启动验证过，为一个文案再重打一次包会让"包与源码一致"这条追溯链变松。
          message = '暂时没有可显示的任务';
          hint = '跳过和取消的任务不会出现在这四个筛选中';
        case TaskListFilter.unscheduled:
          message = '没有待安排任务';
          hint = '当前所有进行中的任务都已经进入计划';
        case TaskListFilter.scheduled:
          message = '没有已安排任务';
          if (widget.onGeneratePlan != null) {
            action = FilledButton.icon(
              key: const Key('empty-generate-plan'),
              onPressed: widget.onGeneratePlan,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('生成计划'),
            );
          }
        case TaskListFilter.completed:
          message = '还没有已完成任务';
      }
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, key: const Key('task-list-empty-message')),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(hint, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (action != null) ...[const SizedBox(height: 16), action],
        ],
      ),
    );
  }

  /// 批量把选中的任务设为同一优先级（FR-TASK-03 的"批量调整"里改字段的那一半）。
  ///
  /// 与批量取消同样串行：仓储写入是串行的，中途失败时前面的结果仍然有效。
  Future<void> _setPriorityForSelected(TaskPriority priority) async {
    final ids = [..._selected];
    for (final id in ids) {
      await widget.service.setPriority(id, priority);
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _batchMessage = '已把 ${ids.length} 项设为该优先级';
    });
  }

  /// 批量把选中的任务置为**已取消**（FR-TASK-03 的"状态变更"）。
  ///
  /// 只改状态、不删除：取消是用户能看见、也能再改回来的一个状态，而删除不可逆。
  Future<void> _cancelSelected() async {
    final ids = [..._selected];
    for (final id in ids) {
      // 逐条串行：仓储写入是串行的，且这样失败时前面的结果仍然有效。
      await widget.service.changeStatus(id, TaskStatus.cancelled);
    }
    if (!mounted) return;
    setState(() {
      // 取消之后这些任务落选，已不在任何筛选结果里；继续留着选择状态只会显示一个
      // 指向不存在对象的多选。
      _selected.clear();
      _batchMessage = '已取消 ${ids.length} 项';
    });
  }
}

/// 任务卡片右端的"查看详情"入口。
///
/// **为什么不是 `IconButton`**（M2 缺陷 A2-1）：`IconButton` 自己会写
/// `Semantics(button: true, …)`，而它**不提供名称**（`tooltip` 只落到 `hint`）。在
/// `CheckboxListTile.secondary` 里这更糟——那一段会被并进整行的语义节点，于是"详情"
/// 入口根本不是一个独立控件。
///
/// 实测三件事之后定型为现在这样：
/// 1. `CheckboxListTile.secondary` 会把它并进本行的 label，**不可能**做成独立控件；
///    因此卡片改用 `ListTile` + 独立 `Checkbox`（见 `_buildTile`）。
/// 2. `IconButton` 无论外面套不套 `Semantics`，都会在树里**再留一个没有名称的 button
///    节点**（`icon_button.dart` 里那句 `return Semantics(button: true, …)`）。
/// 3. `InkResponse` **不自己产生语义节点**。把它套进带名称的 `Semantics(button: true)`
///    并把图标排除掉之后，树里就是**恰好一个** `button=true` 且名称完整的节点，
///    与"一行一个可勾选控件"并列，互不吞并。
///
/// 副作用是失去了 `IconButton` 的默认尺寸与 tooltip；指针用户仍然有涟漪反馈，
/// 而视觉尺寸由下面的内边距补回（约 44×44，与主题的最小可点尺寸一致）。
final class _TileActionButton extends StatelessWidget {
  const _TileActionButton({
    required this.label,
    required this.onPressed,
    this.actionKey,
  });

  /// 语义名称：屏幕阅读器读到的就是它。
  final String label;

  /// 一个**稳定的测试锚点**。此前详情入口靠 `tooltip` 找，而 `tooltip` 会阻止语义合并
  /// （见下），因此换成 key——顺便让测试不再依赖一个会变的人文案。
  final Key? actionKey;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    key: actionKey,
    label: label,
    button: true,
    // **必须自己成为边界**（`container: true`）：`ListTile` 在**可点击**时会把后代
    // 语义合并进自己那一行（实测：已完成行的节点 label 变成
    // "竞赛报名⏎已完成 · 实际投入 0 分钟⏎查看「竞赛报名」详情"，详情入口不再是独立
    // 控件；而不可点击的行上它反而是独立的）。同一屏出现两种形状本身就是缺陷，
    // 因此显式划边界，让"详情"入口在任何状态下都是一个独立、有名称的按钮。
    container: true,
    child: InkResponse(
      radius: 22,
      onTap: onPressed,
      child: const Padding(
        padding: EdgeInsets.all(12),
        // 图标本身没有信息量，名称已经由外层给出；不排除就会多一个空名称节点。
        child: ExcludeSemantics(child: Icon(Icons.chevron_right)),
      ),
    ),
  );
}

String _filterLabel(TaskListFilter filter) => switch (filter) {
  TaskListFilter.all => '全部',
  TaskListFilter.unscheduled => '待安排',
  TaskListFilter.scheduled => '已安排',
  TaskListFilter.completed => '已完成',
};
