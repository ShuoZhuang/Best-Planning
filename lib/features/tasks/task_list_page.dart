import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/domain/models/task.dart';

/// 清单的排序方式（FR-TASK-03 要求支持排序）。
///
/// `none` 表示**保持仓储给出的顺序**（即录入顺序）：排序是用户显式选择的结果，不该在
/// 用户没要求时改变他熟悉的顺序。
enum _TaskSort { none, dueDate, priority, estimatedMinutes }

final class TaskListPage extends StatefulWidget {
  const TaskListPage({
    required this.service,
    required this.nowUtc,
    this.onSetDueDateForSelection,
    super.key,
  });
  final TaskService service;

  /// 用于派生"已逾期"（R12）：该状态不落库，只取决于"截止已过且任务未结束"，
  /// 因此必须显式传入当前时刻，不能由页面各自读时钟决定。
  final DateTime nowUtc;

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

  _TaskSort _sort = _TaskSort.none;

  /// 排序在**筛选之后**执行：顺序只影响呈现，不应改变"哪些任务入选"。
  int _compare(PlannerTask a, PlannerTask b) => switch (_sort) {
    _TaskSort.none => 0,
    // 没有截止时间的排最后：它们不是"最早到期"，但也不该因为缺少字段而挤到最前。
    _TaskSort.dueDate => _dueKey(a).compareTo(_dueKey(b)),
    // 高优先级在前：枚举顺序是 low→urgent，因此取反。
    _TaskSort.priority => b.priority.index.compareTo(a.priority.index),
    _TaskSort.estimatedMinutes => a.estimatedMinutes.compareTo(
      b.estimatedMinutes,
    ),
  };

  static DateTime _dueKey(PlannerTask task) =>
      task.dueAtUtc ?? DateTime.utc(9999);

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
              DropdownButton<_TaskSort>(
                key: const Key('task-sort'),
                value: _sort,
                onChanged: (value) =>
                    setState(() => _sort = value ?? _TaskSort.none),
                items: const [
                  DropdownMenuItem(value: _TaskSort.none, child: Text('默认顺序')),
                  DropdownMenuItem(
                    value: _TaskSort.dueDate,
                    child: Text('按截止时间'),
                  ),
                  DropdownMenuItem(
                    value: _TaskSort.priority,
                    child: Text('按优先级'),
                  ),
                  DropdownMenuItem(
                    value: _TaskSort.estimatedMinutes,
                    child: Text('按预计时长'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
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
                      widget.onSetDueDateForSelection == null ||
                          _selected.isEmpty
                      ? null
                      : () async {
                          // 页面只交出本地日期与"当天第几分钟"；换算与写入都在注入方那边，
                          // 且整批只换算一次（见字段说明）。
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: widget.nowUtc,
                            firstDate: DateTime(widget.nowUtc.year - 1),
                            lastDate: DateTime(widget.nowUtc.year + 5),
                          );
                          if (picked == null) return;
                          final ids = [..._selected];
                          final allSaved = await widget
                              .onSetDueDateForSelection!(ids, picked, 1439);
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
          ),
          if (_batchMessage != null) ...[
            const SizedBox(height: 8),
            Text(_batchMessage!),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: StreamBuilder<List<PlannerTask>>(
              stream: widget.service.watchOpenTasks(),
              builder: (context, snapshot) {
                final tasks = (snapshot.data ?? const <PlannerTask>[])
                    .where(
                      (task) => task.title.toLowerCase().contains(
                        _query.toLowerCase(),
                      ),
                    )
                    .toList();
                // 只有用户真的选了排序才调用 `sort`：Dart 的 `List.sort` **不保证稳定**，
                // 用"全部返回 0"的比较器去"保持原顺序"是不可靠的，因此默认顺序干脆不排。
                if (_sort != _TaskSort.none) tasks.sort(_compare);
                if (tasks.isEmpty) return const Center(child: Text('暂无匹配任务'));
                return ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    return CheckboxListTile(
                      value: _selecting
                          ? _selected.contains(task.id)
                          : task.status == TaskStatus.completed,
                      title: Text(task.title),
                      subtitle: Text(
                        // 派生状态此前只在详情页展示，列表里看不到，因此"哪些任务
                        // 已经逾期"在清单上无从判断（R12）。
                        task.statusAt(nowUtc: widget.nowUtc) ==
                                TaskStatus.overdue
                            ? '已逾期 · 预计 ${task.estimatedMinutes} 分钟'
                            : '预计 ${task.estimatedMinutes} 分钟',
                      ),
                      // 用 `secondary` 而不是 `trailing`：`CheckboxListTile` 没有
                      // `trailing` 参数，勾选框本身就占着那一侧；把入口放在对侧既不
                      // 与勾选冲突，也不必改掉"点整行即完成"的既有行为。
                      secondary: IconButton(
                        icon: const Icon(Icons.chevron_right),
                        tooltip: '查看详情',
                        onPressed: () => context.go('/tasks/${task.id}'),
                      ),
                      onChanged: (checked) {
                        if (_selecting) {
                          setState(() {
                            if (checked == true) {
                              _selected.add(task.id);
                            } else {
                              _selected.remove(task.id);
                            }
                          });
                          return;
                        }
                        widget.service.changeStatus(
                          task.id,
                          checked == true
                              ? TaskStatus.completed
                              : TaskStatus.open,
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
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
      // 选中的任务已不在"未结束"列表里，继续留着选择状态只会显示一个空的多选。
      _selected.clear();
      _batchMessage = '已取消 ${ids.length} 项';
    });
  }
}
