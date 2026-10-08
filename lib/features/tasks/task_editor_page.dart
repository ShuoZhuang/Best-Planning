import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_pickers.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/workspace.dart';

/// 新建与编辑共用完整表单，直到保存才写入任务。
final class TaskEditorPage extends StatefulWidget {
  const TaskEditorPage({
    required this.service,
    required this.settings,
    required this.zones,
    required this.timeZoneId,
    required this.nowUtc,
    required this.onSaved,
    required this.onCancel,
    this.workspace,
    this.taskId,
    super.key,
  });
  final TaskService service;
  final SettingsService settings;
  final WorkspaceService? workspace;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final DateTime nowUtc;
  final String? taskId;
  final ValueChanged<PlannerTask> onSaved;
  final VoidCallback onCancel;

  @override
  State<TaskEditorPage> createState() => _TaskEditorPageState();
}

final class _TaskEditorPageState extends State<TaskEditorPage> {
  final _title = TextEditingController();
  final _minutes = TextEditingController();
  final _notes = TextEditingController();
  final _minChunk = TextEditingController();
  final _maxChunk = TextEditingController();
  final _window = TextEditingController();
  final _newProjectName = TextEditingController();
  TaskPriority _priority = TaskPriority.medium;
  TaskEnergyLevel _energy = TaskEnergyLevel.medium;
  TaskSplitMode _split = TaskSplitMode.splittable;
  String? _areaId;
  String? _projectId;
  DateTime? _dueLocal;
  DateTime? _availableFromLocal;
  PlannerTask? _existing;
  List<PlannerArea> _areas = const [];
  List<PlannerProject> _projects = const [];
  Map<String, String> _errors = const {};
  String? _failure;
  String? _projectCreationError;

  /// 切换领域时被清空的项目名（§7 要求"给出明确说明"）。
  String? _clearedProjectName;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final date = widget.zones.toLocal(widget.nowUtc, widget.timeZoneId);
      final defaults = (await widget.settings.resolveForDate(date)).rules;
      final areas = await widget.workspace?.listAreas() ?? <PlannerArea>[];
      final projects =
          await widget.workspace?.listProjects() ?? <PlannerProject>[];
      final task = widget.taskId == null
          ? null
          : await widget.service.findById(widget.taskId!);
      if (!mounted) return;
      if (widget.taskId != null && task == null) throw StateError('任务不存在');
      setState(() {
        _existing = task;
        _areas = areas;
        _projects = projects
            .where(
              (project) => !project.isArchived || project.id == task?.projectId,
            )
            .toList();
        _title.text = task?.title ?? '';
        _minutes.text =
            '${task?.estimatedMinutes ?? defaults.defaultFocusMinutes}';
        _notes.text = task?.notes ?? '';
        _minChunk.text = '${task?.minChunkMinutes ?? defaults.minChunkMinutes}';
        _maxChunk.text = '${task?.maxChunkMinutes ?? defaults.maxChunkMinutes}';
        _priority = task?.priority ?? TaskPriority.medium;
        _energy = task?.energyLevel ?? TaskEnergyLevel.medium;
        _split = task?.splitMode ?? TaskSplitMode.splittable;
        _areaId =
            task?.areaId ??
            (task == null
                ? areas
                          .where((area) => area.name == '学业')
                          .map((area) => area.id)
                          .firstOrNull ??
                      areas.firstOrNull?.id
                : null);
        _projectId = task?.projectId;
        _dueLocal = task?.dueAtUtc == null
            ? null
            : widget.zones.toLocal(task!.dueAtUtc!, widget.timeZoneId);
        _availableFromLocal = task?.availableFromUtc == null
            ? null
            : widget.zones.toLocal(task!.availableFromUtc!, widget.timeZoneId);
        final window = task?.preferredWindow;
        _window.text = window == null
            ? ''
            : '${_minute(window.startMinute)}-${_minute(window.endMinute)}';
        _loading = false;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failure = '加载失败：$error';
        });
      }
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _title,
      _minutes,
      _notes,
      _minChunk,
      _maxChunk,
      _window,
      _newProjectName,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = widget.zones.toLocal(widget.nowUtc, widget.timeZoneId);
    final date = await showDatePicker(
      builder: plannerPickerBuilder,
      context: context,
      initialDate: _dueLocal ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 20),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      builder: plannerPickerBuilder,
      context: context,
      initialTime: _dueLocal == null
          ? const TimeOfDay(hour: 23, minute: 59)
          : TimeOfDay.fromDateTime(_dueLocal!),
    );
    if (time != null && mounted) {
      setState(
        () => _dueLocal = DateTime(
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        ),
      );
    }
  }

  Future<void> _pickAvailableFrom() async {
    final value = await _pickLocalDateTime(
      current: _availableFromLocal,
      fallbackTime: const TimeOfDay(hour: 8, minute: 0),
    );
    if (value != null && mounted) {
      setState(() => _availableFromLocal = value);
    }
  }

  Future<DateTime?> _pickLocalDateTime({
    required DateTime? current,
    required TimeOfDay fallbackTime,
  }) async {
    final now = widget.zones.toLocal(widget.nowUtc, widget.timeZoneId);
    final date = await showDatePicker(
      builder: plannerPickerBuilder,
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 20),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      builder: plannerPickerBuilder,
      context: context,
      initialTime: current == null
          ? fallbackTime
          : TimeOfDay.fromDateTime(current),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  List<PlannerProject> get _visibleProjects => _projects
      .where(
        (project) =>
            project.areaId == _areaId &&
            (!project.isArchived || project.id == _projectId),
      )
      .toList(growable: false);

  void _selectArea(String? areaId) {
    setState(() {
      // §7：「切换领域后，如果原项目不属于新领域，清空项目并给出明确说明。」
      // 清空本身原来是静默的——用户选了「算法课」再换领域，项目就悄悄没了。
      // 这里在清空前把**被丢掉的项目名**记下来，交给界面说出来。
      final dropped = _projects
          .where((project) => project.id == _projectId)
          .firstOrNull;
      _areaId = areaId;
      if (dropped != null && dropped.areaId != areaId) {
        _projectId = null;
        _clearedProjectName = dropped.name;
      } else {
        _clearedProjectName = null;
      }
      _projectCreationError = null;
    });
  }

  Future<void> _createProject() async {
    final workspace = widget.workspace;
    final areaId = _areaId;
    final name = _newProjectName.text.trim();
    if (workspace == null || areaId == null) {
      setState(() => _projectCreationError = '请先选择领域');
      return;
    }
    if (name.isEmpty) {
      setState(() => _projectCreationError = '请填写项目名称');
      return;
    }
    final created = await workspace.createProject(name: name, areaId: areaId);
    final projects = await workspace.listProjects();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _projectId = created.id;
      _newProjectName.clear();
      _projectCreationError = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    LocalTimeRange? window;
    final raw = _window.text.trim();
    if (raw.isNotEmpty) {
      final match = RegExp(r'^(\d{1,2}):(\d{2})\s*[-–]\s*(\d{1,2}):(\d{2})$')
          .firstMatch(raw);
      if (match == null) {
        setState(() => _errors = {'window': '请填写 09:00-12:00，或留空'});
        return;
      }
      final sh = int.parse(match[1]!);
      final sm = int.parse(match[2]!);
      final eh = int.parse(match[3]!);
      final em = int.parse(match[4]!);
      final start = sh * 60 + sm;
      final end = eh * 60 + em;
      if (sh > 23 ||
          eh > 24 ||
          sm > 59 ||
          em > 59 ||
          end > 1440 ||
          start >= end) {
        setState(() => _errors = {'window': '期望时段需在同一天内，结束晚于开始'});
        return;
      }
      window = LocalTimeRange(startMinute: start, endMinute: end);
    }
    setState(() {
      _saving = true;
      _failure = null;
      _errors = {};
    });
    try {
      final minutes = int.tryParse(_minutes.text.trim()) ?? 0;
      final due = _dueLocal;
      final continuousMinutes = (_existing?.remainingMinutes ?? minutes) <= 0
          ? 1
          : (_existing?.remainingMinutes ?? minutes);
      final draft = TaskDraft(
        title: _title.text,
        estimatedMinutes: minutes,
        areaId: _areaId ?? '',
        notes: _notes.text,
        projectId: _projectId,
        priority: _priority,
        energyLevel: _energy,
        dueAtUtc: due == null
            ? null
            : widget.zones.localDateTimeToUtc(
                due,
                due.hour * 60 + due.minute,
                widget.timeZoneId,
              ),
        availableFromUtc: _availableFromLocal == null
            ? null
            : widget.zones.localDateTimeToUtc(
                _availableFromLocal!,
                _availableFromLocal!.hour * 60 + _availableFromLocal!.minute,
                widget.timeZoneId,
              ),
        splitMode: _split,
        minChunkMinutes: _split == TaskSplitMode.continuous
            ? continuousMinutes
            : int.tryParse(_minChunk.text.trim()) ?? 0,
        maxChunkMinutes: _split == TaskSplitMode.continuous
            ? continuousMinutes
            : int.tryParse(_maxChunk.text.trim()) ?? 0,
        preferredWindow: window,
        status: _existing?.status ?? TaskStatus.open,
      );
      final result = widget.taskId == null
          ? await widget.service.saveDraft(draft)
          : await widget.service.updateDraft(widget.taskId!, draft);
      if (!mounted) return;
      if (result.task case final task?) {
        widget.onSaved(task);
      } else {
        setState(() => _errors = result.fieldErrors);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _failure = '保存失败，请重试：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    // **M3（路线图 §7）信息层级**：滚动区只放表单本体，保存区挪到固定底栏。
    // 这样做的直接原因是 §7 的退出条件之一——"保存按钮在 100% 和 150% 缩放下始终可见"。
    // 保存按钮原本是滚动树的最后一个 `Wrap`，用户滚到"期望时段"一带就看不到它了，
    // 而在 150% 缩放下这一点更容易发生。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.taskId == null ? '新建任务' : '编辑任务',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.taskId == null
                          ? '已填入当前默认值，可按这件事修改后保存。'
                          : '修改本任务的安排方式。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    ..._firstScreenSections(context),
                    const SizedBox(height: 20),
                    _moreOptionsSection(context),
                    if (_failure != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        // **必须播报**（M2 路线图 §6："表单错误既显示文字，也进入语义播报；
                        // 不能只通过红色表达错误"）：`Text` 只是画出来，屏幕阅读器不会主动念它，
                        // 用户得自己逛到这一行才知道保存失败了。`liveRegion: true` 才会在它出现时
                        // 播报。红色只是辅助，不是唯一的表达方式。
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _failure!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
        _saveBar(context),
      ],
    );
  }

  /// §7「表单结构」首屏固定显示的七项，按"先说要做什么、再说归属、最后说时间"排列。
  ///
  /// **为什么把领域/项目提到这一屏**：§7 要求"项目分区必须在首屏可见"，
  /// 而领域与项目是有依赖关系的两项（项目按领域过滤），分开两屏会让用户以为它们无关。
  List<Widget> _firstScreenSections(BuildContext context) => [
    _section(
      context,
      title: '基本信息',
      subtitle: '先说清楚要做什么，以及需要多少时间。',
      children: [
        _field(
          _title,
          '任务标题',
          'task-title',
          error: _errors['title'],
          autofocus: widget.taskId == null,
        ),
        _field(
          _minutes,
          '预计时长（分钟）',
          'task-estimated-minutes',
          number: true,
          error: _errors['estimatedMinutes'],
          enabled: widget.taskId == null,
          helper: widget.taskId == null
              ? '默认采用你的专注时长，可自行修改'
              : '初始估算用于统计；剩余时长可在任务详情中修正',
        ),
      ],
    ),
    const SizedBox(height: 20),
    _section(
      context,
      title: '分类归属',
      subtitle: '领域是长期方向；项目是该领域下可选的阶段性工作。',
      // §7：「领域」表达长期责任范围；「项目」表达有边界的阶段性成果。
      // 界面用一行短说明和实例解释，不使用长段落。
      children: [
        Text(
          '领域：长期要负责的方向，例如「学业」。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const Key('task-area'),
          initialValue: _areaId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: '所属领域',
            errorText: _errors['areaId'],
          ),
          items: [
            for (final area in _areas)
              DropdownMenuItem(value: area.id, child: Text(area.name)),
          ],
          onChanged: _saving ? null : _selectArea,
        ),
        const SizedBox(height: 12),
        Text(
          '项目：有边界的阶段性成果，例如「算法课」。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        KeyedSubtree(
          key: const Key('task-project'),
          child: DropdownButtonFormField<String>(
            key: ValueKey('project-$_areaId-$_projectId'),
            initialValue: _projectId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: '所属项目（可选）',
              hintText: '暂不归属项目',
              errorText: _errors['projectId'],
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('暂不归属项目')),
              for (final project in _visibleProjects)
                DropdownMenuItem(value: project.id, child: Text(project.name)),
            ],
            onChanged: _saving || _areaId == null
                ? null
                : (value) => setState(() => _projectId = value),
          ),
        ),
        if (_clearedProjectName != null) ...[
          const SizedBox(height: 10),
          // §7：「切换领域后，如果原项目不属于新领域，清空项目并给出明确说明。」
          // 静默清空会让用户以为自己的选择被吞掉了，所以这里必须说出**是哪个项目**。
          Semantics(
            liveRegion: true,
            child: Text(
              key: const Key('task-project-cleared-notice'),
              '原项目「$_clearedProjectName」不属于当前领域，已清空。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _newProjectControls(),
      ],
    ),
    const SizedBox(height: 20),
    _section(
      context,
      title: '时间与拆分',
      subtitle: '最早开始是硬限制；期望时段只是系统优先考虑的偏好。',
      children: [
        _dateTimeField(
          label: '最早开始时间（可选）',
          value: _availableFromLocal,
          emptyText: '现在起即可安排',
          fieldKey: 'task-available-from',
          buttonKey: 'task-available-from-button',
          error: _errors['availableFromUtc'],
          onPick: _pickAvailableFrom,
          onClear: () => setState(() => _availableFromLocal = null),
        ),
        const SizedBox(height: 20),
        _dateTimeField(
          label: '截止时间（可选）',
          value: _dueLocal,
          emptyText: '不设置截止时间',
          fieldKey: 'task-due-at',
          buttonKey: 'task-due-at-button',
          error: _errors['dueAtUtc'],
          onPick: _pickDue,
          onClear: () => setState(() => _dueLocal = null),
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<TaskSplitMode>(
          key: const Key('task-split-mode'),
          initialValue: _split,
          decoration: const InputDecoration(labelText: '安排方式'),
          items: const [
            DropdownMenuItem(
              value: TaskSplitMode.splittable,
              child: Text('可拆分'),
            ),
            DropdownMenuItem(
              value: TaskSplitMode.continuous,
              child: Text('必须连续'),
            ),
          ],
          onChanged: _saving
              ? null
              : (value) => setState(() => _split = value!),
        ),
        const SizedBox(height: 10),
        Text(
          _split == TaskSplitMode.splittable
              ? '允许分成多段，可分配到不同日期。'
              : '整个剩余任务需放在一段连续空闲时间内。',
        ),
      ],
    ),
  ];

  /// §7「更多设置」展开区：优先级、精力、片段长度、期望时段、标签与备注。
  ///
  /// 用 `ExpansionTile` 而不是 `Visibility`：收起时**不构建**子树，
  /// 这样"默认收起"才是可断言的事实（`maintainState: true` 会把控件留在树里，
  /// 屏幕阅读器仍能逛到，等于没收起）。
  Widget _moreOptionsSection(BuildContext context) => Card(
    child: ExpansionTile(
      key: const Key('task-more-options'),
      // 显式写 `false`：§7 要求这一区**默认收起**。不写虽然也是默认值，
      // 但那样"默认收起"就是一个隐含行为，改的人不会知道自己破坏了规格。
      initiallyExpanded: false,
      title: Text('更多设置', style: Theme.of(context).textTheme.titleMedium),
      subtitle: const Text('优先级、精力、拆分片段、期望时段、备注'),
      childrenPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        DropdownButtonFormField<TaskPriority>(
          key: const Key('task-editor-priority'),
          initialValue: _priority,
          decoration: const InputDecoration(labelText: '优先级'),
          items: [
            for (final value in TaskPriority.values)
              DropdownMenuItem(
                value: value,
                child: Text(['低', '中', '高', '紧急'][value.index]),
              ),
          ],
          onChanged: _saving
              ? null
              : (value) => setState(() => _priority = value!),
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<TaskEnergyLevel>(
          key: const Key('task-energy-level'),
          initialValue: _energy,
          decoration: const InputDecoration(labelText: '精力要求'),
          items: [
            for (final value in TaskEnergyLevel.values)
              DropdownMenuItem(
                value: value,
                child: Text(['低', '中', '高'][value.index]),
              ),
          ],
          onChanged: _saving
              ? null
              : (value) => setState(() => _energy = value!),
        ),
        const SizedBox(height: 20),
        if (_split == TaskSplitMode.splittable) ...[
          _field(
            _minChunk,
            '每段最短（分钟）',
            'task-min-chunk',
            number: true,
            error: _errors['chunks'],
          ),
          _field(_maxChunk, '每段最长（分钟）', 'task-max-chunk', number: true),
        ],
        _field(
          _window,
          '期望时段（可选）',
          'task-preferred-window',
          error: _errors['window'],
          helper: '例如 09:00-12:00；系统会优先考虑，留空表示不限',
        ),
        _field(_notes, '备注（可选）', 'task-notes', lines: 3),
      ],
    ),
  );

  /// §7「保存区使用固定底栏，同时显示缺失字段和当前关键约束摘要」。
  Widget _saveBar(BuildContext context) {
    final missing = _missingFieldLabels();
    return Material(
      key: const Key('task-save-bar'),
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (missing.isNotEmpty)
                      // 与 M2 的错误播报同一套做法：`liveRegion` 才会主动念，
                      // 而且它同时解决了"字段被收进「更多设置」后错误看不见"的问题。
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          key: const Key('task-missing-fields'),
                          '还缺：${missing.join('、')}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Text(
                      key: const Key('task-constraint-summary'),
                      _constraintSummary(),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                key: const Key('save-task'),
                onPressed:
                    _saving || (widget.taskId != null && _existing == null)
                    ? null
                    : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_saving ? '保存中…' : '保存任务'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _saving ? null : widget.onCancel,
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 底栏左上的"还缺什么"。
  ///
  /// 刻意**不只看** `_errors`：用户还没点保存时 `_errors` 是空的，
  /// 而"标题为空"这件事当下就已经成立。两者合起来才既能事前提示、又能事后报错。
  List<String> _missingFieldLabels() {
    final labels = <String>[];
    if (_title.text.trim().isEmpty) labels.add('标题');
    if (int.tryParse(_minutes.text.trim()) == null) labels.add('预计时长');
    for (final entry in _errors.entries) {
      final label = switch (entry.key) {
        'title' => '标题',
        'estimatedMinutes' => '预计时长',
        'areaId' => '所属领域',
        'projectId' => '所属项目',
        'availableFromUtc' => '最早开始时间',
        'dueAtUtc' => '截止时间',
        'chunks' => '拆分片段',
        'window' => '期望时段',
        _ => null,
      };
      if (label != null && !labels.contains(label)) labels.add(label);
    }
    return labels;
  }

  /// 底栏左下的"当前关键约束摘要"（§7）。
  String _constraintSummary() {
    final parts = <String>[];
    final area = _areas.where((item) => item.id == _areaId).firstOrNull;
    if (area != null) parts.add('领域：${area.name}');
    final project = _visibleProjects
        .where((item) => item.id == _projectId)
        .firstOrNull;
    if (project != null) parts.add('项目：${project.name}');
    parts.add(_split == TaskSplitMode.splittable ? '可拆分' : '必须连续');
    parts.add(
      _availableFromLocal == null
          ? '最早开始：不限'
          : '最早开始：${_formatLocal(_availableFromLocal!)}',
    );
    parts.add(_dueLocal == null ? '截止：不限' : '截止：${_formatLocal(_dueLocal!)}');
    return parts.join('　·　');
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    ),
  );

  Widget _newProjectControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('当前领域没有合适项目时，可直接新建并选中。'),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final field = TextField(
            key: const Key('task-new-project-name'),
            controller: _newProjectName,
            enabled: !_saving && _areaId != null,
            decoration: const InputDecoration(labelText: '新项目名称'),
          );
          final button = FilledButton.tonalIcon(
            key: const Key('task-create-project'),
            onPressed: _saving || _areaId == null ? null : _createProject,
            icon: const Icon(Icons.add_rounded),
            label: const Text('新建该领域项目'),
          );
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [field, const SizedBox(height: 12), button],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: field),
              const SizedBox(width: 12),
              Padding(padding: const EdgeInsets.only(top: 4), child: button),
            ],
          );
        },
      ),
      if (_projectCreationError != null) ...[
        const SizedBox(height: 8),
        // 与 `_failure` 同理：新建项目失败也必须被播报，而不是只染成红色。
        Semantics(
          liveRegion: true,
          child: Text(
            _projectCreationError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    ],
  );

  Widget _dateTimeField({
    required String label,
    required DateTime? value,
    required String emptyText,
    required String fieldKey,
    required String buttonKey,
    required String? error,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) => InputDecorator(
    key: Key(fieldKey),
    decoration: InputDecoration(labelText: label, errorText: error),
    child: Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(value == null ? emptyText : _formatLocal(value)),
        TextButton(
          key: Key(buttonKey),
          onPressed: _saving ? null : onPick,
          child: const Text('选择日期和时间'),
        ),
        if (value != null)
          IconButton(
            tooltip: '清除$label',
            onPressed: _saving ? null : onClear,
            icon: const Icon(Icons.close_rounded),
          ),
      ],
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label,
    String key, {
    bool number = false,
    bool enabled = true,
    bool autofocus = false,
    int lines = 1,
    String? error,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: TextField(
      key: Key(key),
      controller: controller,
      enabled: enabled && !_saving,
      autofocus: autofocus,
      keyboardType: number ? TextInputType.number : null,
      maxLines: lines,
      decoration: InputDecoration(
        labelText: label,
        errorText: error,
        helperText: helper,
        helperMaxLines: 3,
      ),
    ),
  );
}

String _minute(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

String _formatLocal(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
    '${_minute(value.hour * 60 + value.minute)}';
