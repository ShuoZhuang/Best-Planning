import 'package:flutter/material.dart';
import 'package:personal_planner/application/tag_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/domain/models/tag.dart';
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
    this.tags,
    super.key,
  });

  final TaskService service;
  final String taskId;
  final DateTime nowUtc;

  /// 领域与项目服务。为空时不显示项目选择——其余部分照常可用。
  final WorkspaceService? workspace;

  /// 标签服务。为空时不显示标签区——其余部分照常可用。
  ///
  /// FR-TASK-02 要求任务可"补充分类"，而标签是唯一不依赖领域／项目层次的分类方式。
  /// 在此之前标签只有两张表：没有任何界面能建立标签或把它打到任务上，因此统计侧
  /// 即便能按标签筛选也没有数据可筛（见 R1）。
  final TagService? tags;

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

final class _TaskDetailPageState extends State<TaskDetailPage> {
  final _remaining = TextEditingController();
  final _newProjectName = TextEditingController();
  final _window = TextEditingController();
  final _newTagName = TextEditingController();
  PlannerTask? _task;
  List<PlannerProject> _projects = const [];
  List<PlannerArea> _areas = const [];
  List<PlannerTag> _allTags = const [];
  Set<String> _taskTagNames = const {};
  String? _newProjectAreaId;
  bool _loading = true;
  bool _saving = false;
  bool _tagSaving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _remaining.dispose();
    _newProjectName.dispose();
    _window.dispose();
    _newTagName.dispose();
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
    final areas = workspace == null
        ? const <PlannerArea>[]
        : await workspace.listAreas();
    final tagService = widget.tags;
    final allTags = tagService == null
        ? const <PlannerTag>[]
        : await tagService.listTags();
    final taskTags = tagService == null || task == null
        ? const <PlannerTag>[]
        : await tagService.tagsForTask(task.id);
    if (!mounted) return;
    setState(() {
      _task = task;
      _projects = projects;
      _areas = areas;
      _allTags = allTags;
      _taskTagNames = {for (final tag in taskTags) tag.name};
      // 默认选中第一个领域，因为新建项目必须挂在某个领域下；领域为空时保持 null，
      // 此时新建入口会提示先建领域而不是提交一个必然失败的项目。
      _newProjectAreaId = areas.any((item) => item.id == _newProjectAreaId)
          ? _newProjectAreaId
          : (areas.isEmpty ? null : areas.first.id);
      _loading = false;
      if (task != null) _remaining.text = '${task.remainingMinutes}';
      _window.text = _editableWindow(task?.preferredWindow);
    });
  }

  /// 新建项目并立即把当前任务归属过去。
  ///
  /// 两件事放在一个动作里，是因为"选择器为空"本身不是可操作的状态：默认初始化只建
  /// 领域而不建项目（项目该由用户定义），因此若只给一个空列表，用户会以为功能坏了。
  Future<void> _createProjectAndAssign() async {
    final workspace = widget.workspace;
    final areaId = _newProjectAreaId;
    final name = _newProjectName.text.trim();
    if (workspace == null) return;
    if (areaId == null) {
      setState(() => _message = '请先建立领域，再新建项目');
      return;
    }
    if (name.isEmpty) {
      setState(() => _message = '请填写项目名称');
      return;
    }

    setState(() {
      _saving = true;
      _message = null;
    });
    final project = await workspace.createProject(name: name, areaId: areaId);
    final assigned = await widget.service.assignProject(
      widget.taskId,
      project.id,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _newProjectName.clear();
      _message = assigned
          ? '已新建项目"$name"并归属，领域与生活标记随之生效'
          : '项目已新建，但任务不存在，归属未变更';
    });
    await _load();
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

  /// 保存期望时段；留空即清除偏好。
  ///
  /// 页面只做格式解析与提示，区间是否合法交给服务层——两处各写一份规则必然会脱节。
  Future<void> _saveWindow() async {
    final parsed = _parseWindow(_window.text);
    if (parsed == null) {
      setState(() => _message = '期望时段格式应为 09:00-12:00，留空表示不设偏好');
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    final saved = await widget.service.setPreferredWindow(
      widget.taskId,
      startMinute: parsed.startMinute,
      endMinute: parsed.endMinute,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _message = saved
          // 明说它是软约束：用户才不会再问"为什么安排还是落在区间外"。
          ? '期望时段已保存。它是软约束，排程仍可能落在区间外，只是分数更低。'
          : '期望时段无效（需起点早于终点且在一日之内），未保存';
    });
    if (saved) await _load();
  }

  /// 切换某个已有标签在当前任务上的有无。
  Future<void> _toggleTag(String name) async {
    final next = {..._taskTagNames};
    if (!next.remove(name)) next.add(name);
    await _writeTags(next);
  }

  /// 建立一个新标签并打在当前任务上。
  ///
  /// "建立"与"打上"合成一个动作：只建不打的标签对用户没有意义，而分成两步会先在
  /// 列表里留下一个没人用的名字。名称是否存在由服务层判断——页面不重复这套规则。
  Future<void> _addTag() async {
    final name = _newTagName.text.trim();
    if (name.isEmpty) {
      setState(() => _message = '请填写标签名');
      return;
    }
    await _writeTags({..._taskTagNames, name});
    if (_taskTagNames.contains(name)) _newTagName.clear();
  }

  Future<void> _writeTags(Set<String> names) async {
    final tags = widget.tags;
    if (tags == null) return;
    setState(() {
      _tagSaving = true;
      _message = null;
    });
    // 服务层按差量更新，因此重复保存同一组标签不会产生多余写入。
    await tags.setTaskTags(widget.taskId, names);
    final allTags = await tags.listTags();
    final taskTags = await tags.tagsForTask(widget.taskId);
    if (!mounted) return;
    setState(() {
      _tagSaving = false;
      _allTags = allTags;
      _taskTagNames = {for (final tag in taskTags) tag.name};
      _message = taskTags.isEmpty
          ? '已清除本任务的标签'
          : '已更新标签：${taskTags.map((tag) => tag.name).join('、')}';
    });
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
            if (_projects.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  // 空列表要说明原因，否则看起来像功能失效。
                  _areas.isEmpty
                      ? '尚无项目，且没有领域可供挂靠——请先建立领域。'
                      : '尚无项目。项目由你定义，可在下面新建一个并直接归属本任务。',
                ),
              ),
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
            if (_areas.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('新建项目并归属', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 160,
                    child: DropdownButton<String>(
                      value: _newProjectAreaId,
                      isExpanded: true,
                      onChanged: _saving
                          ? null
                          : (value) =>
                                setState(() => _newProjectAreaId = value),
                      items: [
                        for (final area in _areas)
                          DropdownMenuItem<String>(
                            value: area.id,
                            child: Text(area.name),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 200,
                    child: TextField(
                      key: const Key('new-project-name'),
                      controller: _newProjectName,
                      decoration: const InputDecoration(
                        labelText: '项目名称',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _saving ? null : _createProjectAndAssign,
                    child: const Text('新建并归属'),
                  ),
                ],
              ),
            ],
          ],
          if (widget.tags != null) ...[
            const Divider(height: 40),
            Text('标签', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              '标签是跨领域的分类，一个任务可以有多个，彼此没有层次关系；'
              '统计页按标签筛选时是整词匹配。',
            ),
            const SizedBox(height: 12),
            if (_allTags.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('尚无标签。在下面填入名称即可建立并打在本任务上。'),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in _allTags)
                  FilterChip(
                    key: Key('tag-chip-${tag.name}'),
                    label: Text(tag.name),
                    selected: _taskTagNames.contains(tag.name),
                    onSelected: _tagSaving
                        ? null
                        : (_) => _toggleTag(tag.name),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 200,
                  child: TextField(
                    key: const Key('new-tag-name'),
                    controller: _newTagName,
                    decoration: const InputDecoration(
                      labelText: '新标签',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  key: const Key('add-tag'),
                  onPressed: _tagSaving ? null : _addTag,
                  child: Text(_tagSaving ? '保存中…' : '添加标签'),
                ),
              ],
            ),
          ],
          const Divider(height: 40),
          Text('期望时段', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            '偏好时段，格式 09:00-12:00，可跨午夜（如 22:00-02:00）；留空表示不设偏好。'
            '它是软约束：排程仍可能落在区间外，只是分数更低。',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 200,
                child: TextField(
                  key: const Key('preferred-window'),
                  controller: _window,
                  decoration: const InputDecoration(
                    labelText: '期望时段',
                    hintText: '09:00-12:00',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _saving ? null : _saveWindow,
                child: const Text('保存期望时段'),
              ),
            ],
          ),
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
                  key: const Key('remaining-minutes'),
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

/// 期望时段的可编辑写法：`09:00-12:00`；没有偏好时为空串。
///
/// 用连字符而不是中文破折号，因为这是要用户输入的文本，必须能用普通键盘打出来。
String _editableWindow(LocalTimeRange? window) => window == null
    ? ''
    : '${_minuteLabel(window.startMinute)}-${_minuteLabel(window.endMinute)}';

/// 解析上一种写法。空串返回一个"清除"标记，格式错误返回 `null`。
///
/// 这里只做格式解析，不判断区间是否合法——合法性由 `TaskService.setPreferredWindow`
/// 与 `LocalTimeRange` 负责，避免两处各写一份规则、日后互相脱节。
({int? startMinute, int? endMinute})? _parseWindow(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return (startMinute: null, endMinute: null);
  final parts = text.split('-');
  if (parts.length != 2) return null;
  final start = _parseMinuteLabel(parts[0]);
  final end = _parseMinuteLabel(parts[1]);
  if (start == null || end == null) return null;
  return (startMinute: start, endMinute: end);
}

int? _parseMinuteLabel(String raw) {
  final parts = raw.trim().split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 24 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
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
