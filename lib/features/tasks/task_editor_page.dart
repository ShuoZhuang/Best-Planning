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
      _areaId = areaId;
      if (!_projects.any(
        (project) => project.id == _projectId && project.areaId == areaId,
      )) {
        _projectId = null;
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
    return SingleChildScrollView(
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
                widget.taskId == null ? '已填入当前默认值，可按这件事修改后保存。' : '修改本任务的安排方式。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              _section(
                context,
                title: '基本信息',
                subtitle: '先说清楚要做什么，以及需要多少时间与精力。',
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
                  _field(_notes, '备注（可选）', 'task-notes', lines: 3),
                ],
              ),
              const SizedBox(height: 20),
              _section(
                context,
                title: '分类归属',
                subtitle: '领域是长期方向；项目是该领域下可选的阶段性工作。',
                children: [
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
                        DropdownMenuItem(
                          value: area.id,
                          child: Text(area.name),
                        ),
                    ],
                    onChanged: _saving ? null : _selectArea,
                  ),
                  const SizedBox(height: 20),
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
                        const DropdownMenuItem(
                          value: null,
                          child: Text('暂不归属项目'),
                        ),
                        for (final project in _visibleProjects)
                          DropdownMenuItem(
                            value: project.id,
                            child: Text(project.name),
                          ),
                      ],
                      onChanged: _saving || _areaId == null
                          ? null
                          : (value) => setState(() => _projectId = value),
                    ),
                  ),
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
                  const SizedBox(height: 20),
                  if (_split == TaskSplitMode.splittable) ...[
                    _field(
                      _minChunk,
                      '每段最短（分钟）',
                      'task-min-chunk',
                      number: true,
                      error: _errors['chunks'],
                    ),
                    _field(
                      _maxChunk,
                      '每段最长（分钟）',
                      'task-max-chunk',
                      number: true,
                    ),
                  ],
                  _field(
                    _window,
                    '期望时段（可选）',
                    'task-preferred-window',
                    error: _errors['window'],
                    helper: '例如 09:00-12:00；系统会优先考虑，留空表示不限',
                  ),
                ],
              ),
              if (_failure != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _failure!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                children: [
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
                  TextButton(
                    onPressed: _saving ? null : widget.onCancel,
                    child: const Text('取消'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
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
        Text(
          _projectCreationError!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
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
