import 'package:flutter/material.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/workspace.dart';

/// 任务详情页（W3 登记缺失的"任务详情"路由）。
///
/// 它同时是另外两处登记缺口的落点：
/// - FR-TASK-05 的手动修正剩余时长此前只有服务层与数据层，没有界面入口（R9）；
/// - 通知 payload 里的 `route` 指向 `/tasks/{id}`（FR-NOTIFY-04 的快捷入口），
///   而该路由此前不存在，因此即便接上点击消费者也无处可去。
///
/// 页面只读任务事实并调用已有的两个服务方法，不自行判断业务规则：状态与逾期的口径
/// 来自 `PlannerTask.statusAt`，修正的校验来自 `TaskService.correctRemainingMinutes`。
final class TaskDetailPage extends StatefulWidget {
  const TaskDetailPage({
    required this.service,
    required this.taskId,
    required this.nowUtc,
    this.workspace,
    super.key,
  });

  final TaskService service;
  final String taskId;
  final DateTime nowUtc;

  /// 领域与项目服务。为空时不显示项目选择——其余部分照常可用。
  final WorkspaceService? workspace;

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

final class _TaskDetailPageState extends State<TaskDetailPage> {
  final _remaining = TextEditingController();
  PlannerTask? _task;
  List<PlannerProject> _projects = const [];
  bool _loading = true;
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _remaining.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final task = await widget.service.findById(widget.taskId);
    final workspace = widget.workspace;
    // 已归档项目不出现在可选项里：归档表示"不再往里放新任务"，但它不影响已有归属，
    // 因此当前任务的归属即使指向已归档项目也照旧显示。
    final projects = workspace == null
        ? const <PlannerProject>[]
        : (await workspace.listProjects())
              .where((item) => !item.isArchived)
              .toList(growable: false);
    if (!mounted) return;
    setState(() {
      _task = task;
      _projects = projects;
      _loading = false;
      if (task != null) _remaining.text = '${task.remainingMinutes}';
    });
  }

  /// 归属或取消归属项目。
  ///
  /// 这是任务通向领域的唯一路径：任务的领域与生活标记都经项目推导，因此用户不归属
  /// 项目时，两者对该任务都不适用——界面必须把这个因果说出来，否则"改了没反应"
  /// 会被当成缺陷。
  Future<void> _assign(String? projectId) async {
    setState(() {
      _saving = true;
      _message = null;
    });
    final assigned = await widget.service.assignProject(widget.taskId, projectId);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!assigned) {
        _message = '任务不存在，归属未变更';
        return;
      }
      _message = projectId == null
          ? '已取消项目归属'
          : '已归属到该项目，领域与生活标记随之生效';
    });
    if (assigned) await _load();
  }

  Future<void> _correct() async {
    final minutes = int.tryParse(_remaining.text.trim());
    if (minutes == null) {
      setState(() => _message = '请填写整数分钟');
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    final result = await widget.service.correctRemainingMinutes(
      widget.taskId,
      minutes,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _message = result.isSuccess
          // 明说"已记录历史"：FR-TASK-05 要求保留修正记录供统计，用户应当知道
          // 自己这次修正被记下来了，而不是以为只是改了个数字。
          ? '剩余时长已修正，并已记录修正历史'
          : result.fieldErrors.values.join('；');
    });
    if (result.isSuccess) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final task = _task;
    if (task == null) {
      return const Center(child: Text('任务不存在或已被永久删除'));
    }

    final overdue = task.statusAt(nowUtc: widget.nowUtc) == TaskStatus.overdue;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(task.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              Chip(label: Text(_statusLabel(task.status))),
              // `scheduled` 需要已确认计划，这里读不到，因此只展示能由事实判定的
              // 逾期，而不是把"未排程"误显示成状态。
              if (overdue) const Chip(label: Text('已逾期')),
              Chip(label: Text(_priorityLabel(task.priority))),
            ],
          ),
          const SizedBox(height: 20),
          _Fact(label: '预计时长', value: '${task.estimatedMinutes} 分钟'),
          _Fact(label: '剩余时长', value: '${task.remainingMinutes} 分钟'),
          _Fact(
            label: '截止时间',
            value: task.dueAtUtc == null
                ? '未设置'
                : _formatInstant(task.dueAtUtc!),
          ),
          _Fact(label: '精力要求', value: _energyLabel(task.energyLevel)),
          _Fact(label: '拆分方式', value: _splitLabel(task.splitMode)),
          _Fact(
            label: '片段长度',
            value: '${task.minChunkMinutes}–${task.maxChunkMinutes} 分钟',
          ),
          _Fact(label: '期望时段', value: _windowLabel(task.preferredWindow)),
          if (task.notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('备注', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(task.notes),
          ],
          if (widget.workspace != null) ...[
            const Divider(height: 40),
            Text('归属项目', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              '任务的领域与生活标记都经"项目 → 领域"推导；不归属项目时两者都不适用。',
            ),
            const SizedBox(height: 12),
            DropdownButton<String?>(
              value: _projects.any((item) => item.id == task.projectId)
                  ? task.projectId
                  : null,
              isExpanded: true,
              onChanged: _saving ? null : _assign,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('不归属项目'),
                ),
                for (final project in _projects)
                  DropdownMenuItem<String?>(
                    value: project.id,
                    child: Text(project.name),
                  ),
              ],
            ),
          ],
          const Divider(height: 40),
          Text('修正剩余时长', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            '只改剩余时长，不改预计时长；每次修正都会留下历史供统计使用。'
            '任务已完成请改用状态变更，而不是把剩余时长改成 0。',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _remaining,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '剩余分钟',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _saving ? null : _correct,
                child: Text(_saving ? '保存中…' : '保存'),
              ),
            ],
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_message!),
            ),
        ],
      ),
    );
  }
}

final class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(label, style: const TextStyle(color: Colors.black54)),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

/// 状态名。
///
/// 刻意写全八个值、不留 `_` 默认分支：将来给 `TaskStatus` 增删取值时，这里会**编译
/// 失败**，迫使新增状态得到明确的中文名，而不是悄悄显示成枚举英文名或空白。
String _statusLabel(TaskStatus status) => switch (status) {
  TaskStatus.inbox => '收集箱',
  TaskStatus.open => '待安排',
  TaskStatus.scheduled => '已安排',
  TaskStatus.inProgress => '进行中',
  TaskStatus.completed => '已完成',
  TaskStatus.skipped => '已跳过',
  TaskStatus.cancelled => '已取消',
  TaskStatus.overdue => '已逾期',
};

String _priorityLabel(TaskPriority priority) => switch (priority) {
  TaskPriority.low => '低优先级',
  TaskPriority.medium => '中优先级',
  TaskPriority.high => '高优先级',
  TaskPriority.urgent => '紧急',
};

String _energyLabel(TaskEnergyLevel level) => switch (level) {
  TaskEnergyLevel.low => '低精力',
  TaskEnergyLevel.medium => '中等精力',
  TaskEnergyLevel.high => '高精力',
};

String _splitLabel(TaskSplitMode mode) => switch (mode) {
  TaskSplitMode.splittable => '可拆分',
  TaskSplitMode.continuous => '需连续',
};

String _windowLabel(LocalTimeRange? window) {
  if (window == null) return '未设置';
  return '${_minuteLabel(window.startMinute)}–${_minuteLabel(window.endMinute)}';
}

String _minuteLabel(int minute) {
  final hours = (minute ~/ 60).toString().padLeft(2, '0');
  final minutes = (minute % 60).toString().padLeft(2, '0');
  return '$hours:$minutes';
}

/// 按本机时区展示时刻：排程与存储都用 UTC，但用户读的是本地钟点。
String _formatInstant(DateTime instantUtc) {
  final local = instantUtc.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
