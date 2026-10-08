import 'package:flutter/material.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/workspace.dart';

/// 周期目标的模板编辑器（路线图 §3.3、§11 Task 7 Step 2／4）。
///
/// **默认值就是路线图写的那三条**：周一至周日、均匀分布、不结转。它们不是随便挑的——
/// 「周一至周日」是周界的定义（Global Constraints），「均匀分布」是避免把 180 分钟全堆到
/// 周日的唯一节奏（§3.4），「不结转」是默认口径（不结转时下周按原目标重新开始）。
///
/// **只放本类型用得到的字段**：普通任务表单里的"截止时间""最早开始"对周期目标没有意义
/// （它的截止时间就是这一周的结束，由系统算），因此这里不出现；反过来"安排节奏""允许星期"
/// 只属于周期目标。把两套字段混在一张表单里，用户就得自己判断哪些格子该填。
final class RecurringTaskEditorPage extends StatefulWidget {
  const RecurringTaskEditorPage({
    required this.service,
    required this.zones,
    required this.timeZoneId,
    required this.nowUtc,
    required this.onSaved,
    required this.onCancel,
    this.workspace,
    this.templateId,
    super.key,
  });

  final RecurringTaskService service;
  final WorkspaceService? workspace;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final DateTime nowUtc;

  /// 为空即新建。
  final String? templateId;

  final ValueChanged<RecurringTaskTemplate> onSaved;
  final VoidCallback onCancel;

  @override
  State<RecurringTaskEditorPage> createState() =>
      _RecurringTaskEditorPageState();
}

final class _RecurringTaskEditorPageState
    extends State<RecurringTaskEditorPage> {
  final _title = TextEditingController();
  final _minutes = TextEditingController();
  final _notes = TextEditingController();
  final _minChunk = TextEditingController();
  final _maxChunk = TextEditingController();
  final _window = TextEditingController();

  TaskPriority _priority = TaskPriority.medium;
  TaskEnergyLevel _energy = TaskEnergyLevel.medium;
  TaskSplitMode _split = TaskSplitMode.splittable;
  RecurringPace _pace = RecurringPace.even;
  int _weekdaysMask = recurringAllWeekdaysMask;
  bool _carryOver = false;
  String? _areaId;
  String? _projectId;
  DateTime? _endsOn;
  RecurringTaskTemplate? _existing;
  List<PlannerArea> _areas = const [];
  List<PlannerProject> _projects = const [];
  Map<String, String> _errors = const {};
  String? _failure;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
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
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final areas = await widget.workspace?.listAreas() ?? <PlannerArea>[];
      final projects =
          await widget.workspace?.listProjects() ?? <PlannerProject>[];
      final template = widget.templateId == null
          ? null
          : await widget.service.repository.findTemplate(widget.templateId!);
      if (!mounted) return;
      if (widget.templateId != null && template == null) {
        throw StateError('周期目标不存在');
      }
      setState(() {
        _existing = template;
        _areas = areas;
        _projects = projects
            .where(
              (project) =>
                  !project.isArchived || project.id == template?.projectId,
            )
            .toList();
        _title.text = template?.title ?? '';
        _minutes.text = '${template?.targetMinutes ?? 180}';
        _notes.text = template?.notes ?? '';
        _minChunk.text = '${template?.minChunkMinutes ?? 25}';
        _maxChunk.text = '${template?.maxChunkMinutes ?? 90}';
        _priority = template?.priority ?? TaskPriority.medium;
        _energy = template?.energyLevel ?? TaskEnergyLevel.medium;
        _split = template?.splitMode ?? TaskSplitMode.splittable;
        _pace = template?.pace ?? RecurringPace.even;
        _weekdaysMask =
            template?.allowedWeekdaysMask ?? recurringAllWeekdaysMask;
        _carryOver = template?.carryOverUnfinished ?? false;
        _areaId =
            template?.areaId ??
            areas
                .where((area) => area.name == '学业')
                .map((area) => area.id)
                .firstOrNull ??
            areas.firstOrNull?.id;
        _projectId = template?.projectId;
        _endsOn = template?.endsOnLocalDate;
        final window = template?.preferredWindow;
        _window.text = window == null
            ? ''
            : '${_minuteLabel(window.startMinute)}-'
                  '${_minuteLabel(window.endMinute)}';
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

  /// 项目按领域过滤：这是 §7"项目必须属于所选领域"在界面上的唯一落点。
  List<PlannerProject> get _projectsOfArea => [
    for (final project in _projects)
      if (project.areaId == _areaId) project,
  ];

  /// 允许星期只在"仅指定星期"这一节奏下才有意义（§3.3）。
  ///
  /// 其余三种节奏是**分布策略**，与允许星期正交，但它们同时生效会让"尽早完成"被星期掩码
  /// 挡住而看不出原因。因此界面上只在 selectedWeekdays 时显示星期选择——**但这不等于
  /// 丢弃已存的掩码**：切换节奏不会清空它，切回来还在。
  bool get _needsWeekdays => _pace == RecurringPace.selectedWeekdays;

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
      final start = int.parse(match[1]!) * 60 + int.parse(match[2]!);
      final end = int.parse(match[3]!) * 60 + int.parse(match[4]!);
      if (int.parse(match[1]!) > 23 ||
          int.parse(match[3]!) > 24 ||
          int.parse(match[2]!) > 59 ||
          int.parse(match[4]!) > 59 ||
          end > LocalTimeRange.minutesPerDay ||
          start >= end) {
        setState(() => _errors = {'window': '期望时段需在同一天内，结束晚于开始'});
        return;
      }
      window = LocalTimeRange(startMinute: start, endMinute: end);
    }

    if (_needsWeekdays && _weekdaysMask == 0) {
      setState(() => _errors = {'weekdays': '请至少选择一天'});
      return;
    }

    setState(() {
      _saving = true;
      _failure = null;
      _errors = {};
    });
    try {
      final minutes = int.tryParse(_minutes.text.trim()) ?? 0;
      final minChunk = int.tryParse(_minChunk.text.trim()) ?? 0;
      final maxChunk = int.tryParse(_maxChunk.text.trim()) ?? 0;
      RecurringTaskTemplate? saved;
      if (_existing == null) {
        saved = await widget.service.createTemplate(
          title: _title.text,
          targetMinutes: minutes,
          areaId: _areaId,
          projectId: _projectId,
          notes: _notes.text,
          priority: _priority,
          energyLevel: _energy,
          splitMode: _split,
          minChunkMinutes: minChunk,
          maxChunkMinutes: maxChunk,
          preferredStartMinute: window?.startMinute,
          preferredEndMinute: window?.endMinute,
          pace: _pace,
          allowedWeekdaysMask: _weekdaysMask,
          carryOverUnfinished: _carryOver,
          endsOnLocalDate: _endsOn,
          nowUtc: widget.nowUtc,
        );
      } else {
        saved = await widget.service.updateTemplate(
          _existing!.id,
          (current) => current.copyWith(
            title: _title.text,
            notes: _notes.text,
            areaId: _areaId,
            projectId: _projectId,
            targetMinutes: minutes,
            priority: _priority,
            energyLevel: _energy,
            splitMode: _split,
            minChunkMinutes: minChunk,
            maxChunkMinutes: maxChunk,
            preferredStartMinute: window?.startMinute,
            preferredEndMinute: window?.endMinute,
            pace: _pace,
            allowedWeekdaysMask: _weekdaysMask,
            carryOverUnfinished: _carryOver,
            endsOnLocalDate: _endsOn,
          ),
          nowUtc: widget.nowUtc,
        );
      }
      if (!mounted) return;
      widget.onSaved(saved);
    } on ArgumentError catch (error) {
      // 领域模型自己会拒绝非法组合（目标为 0、片段范围倒挂、期望时段只给一端…）。
      // **把它的理由翻译成界面文案**，而不是另写一份重复的校验——两份校验必然漂移。
      if (mounted) setState(() => _errors = _fieldErrorFor(error));
    } on Object catch (error) {
      if (mounted) setState(() => _failure = '保存失败，请重试：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Map<String, String> _fieldErrorFor(ArgumentError error) {
    final name = error.name ?? '';
    final message = '${error.message ?? error.invalidValue ?? ''}';
    if (name.contains('targetMinutes')) {
      return {'targetMinutes': '每周目标必须大于 0 分钟'};
    }
    if (name.contains('ChunkMinutes')) {
      return {'chunks': '片段范围无效：最小必须大于 0，且不大于最大片段'};
    }
    if (name.contains('preferred')) {
      return {'window': '期望时段必须成对填写'};
    }
    if (name.contains('title')) return {'title': '请输入目标名称'};
    return {'form': '无法保存：$message'};
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
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
                      _existing == null ? '新建周期目标' : '编辑周期目标',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '每周完成固定时长，具体做在哪天由排程决定。'
                      '周界是周一至周日，每周独立结算。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    _section(
                      context,
                      title: '目标',
                      subtitle: '这一周要做多少，以及它属于哪里。',
                      children: [
                        _field(
                          _title,
                          '目标名称',
                          'recurring-title',
                          error: _errors['title'],
                          autofocus: _existing == null,
                        ),
                        _field(
                          _minutes,
                          '每周目标（分钟）',
                          'recurring-target-minutes',
                          number: true,
                          error: _errors['targetMinutes'],
                          helper: '例如 180 表示每周三小时。',
                        ),
                        _areaPicker(context),
                        _projectPicker(context),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _section(
                      context,
                      title: '安排节奏',
                      subtitle: '决定这一周的片段怎么摊开。默认均匀分布，不会全堆到周日。',
                      children: [
                        DropdownButtonFormField<RecurringPace>(
                          key: const Key('recurring-pace'),
                          initialValue: _pace,
                          decoration: const InputDecoration(labelText: '节奏'),
                          onChanged: _saving
                              ? null
                              : (value) => setState(
                                  () => _pace = value ?? RecurringPace.even,
                                ),
                          items: const [
                            DropdownMenuItem(
                              value: RecurringPace.even,
                              child: Text('均匀分布（默认）'),
                            ),
                            DropdownMenuItem(
                              value: RecurringPace.early,
                              child: Text('尽早完成'),
                            ),
                            DropdownMenuItem(
                              value: RecurringPace.deadlineWeighted,
                              child: Text('临近截止'),
                            ),
                            DropdownMenuItem(
                              value: RecurringPace.selectedWeekdays,
                              child: Text('仅指定星期'),
                            ),
                          ],
                        ),
                        if (_needsWeekdays) ...[
                          const SizedBox(height: 16),
                          _weekdayPicker(context),
                        ],
                        const SizedBox(height: 8),
                        SwitchListTile(
                          key: const Key('recurring-carry-over'),
                          contentPadding: EdgeInsets.zero,
                          value: _carryOver,
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _carryOver = value),
                          title: const Text('结转未完成分钟'),
                          subtitle: const Text('默认关闭：新的一周按原目标重新开始，上周的未达标记录保留。'),
                        ),
                        _dateField(
                          context,
                          label: '结束日期',
                          value: _endsOn,
                          emptyText: '长期有效',
                          fieldKey: 'recurring-ends-on',
                          buttonKey: 'recurring-pick-ends-on',
                          onPick: _pickEndsOn,
                          onClear: () => setState(() => _endsOn = null),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _section(
                      context,
                      title: '片段与偏好',
                      subtitle: '一次做多久、什么时段做更合适。这些是软约束，排程会尽量满足。',
                      children: [
                        _field(
                          _minChunk,
                          '最小片段（分钟）',
                          'recurring-min-chunk',
                          number: true,
                          error: _errors['chunks'],
                        ),
                        _field(
                          _maxChunk,
                          '最大片段（分钟）',
                          'recurring-max-chunk',
                          number: true,
                        ),
                        DropdownButtonFormField<TaskSplitMode>(
                          key: const Key('recurring-split-mode'),
                          initialValue: _split,
                          decoration: const InputDecoration(labelText: '拆分方式'),
                          onChanged: _saving
                              ? null
                              : (value) => setState(
                                  () => _split =
                                      value ?? TaskSplitMode.splittable,
                                ),
                          items: const [
                            DropdownMenuItem(
                              value: TaskSplitMode.splittable,
                              child: Text('可拆分'),
                            ),
                            DropdownMenuItem(
                              value: TaskSplitMode.continuous,
                              child: Text('连续完成'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        DropdownButtonFormField<TaskPriority>(
                          key: const Key('recurring-priority'),
                          initialValue: _priority,
                          decoration: const InputDecoration(labelText: '优先级'),
                          onChanged: _saving
                              ? null
                              : (value) => setState(
                                  () =>
                                      _priority = value ?? TaskPriority.medium,
                                ),
                          items: const [
                            DropdownMenuItem(
                              value: TaskPriority.low,
                              child: Text('低'),
                            ),
                            DropdownMenuItem(
                              value: TaskPriority.medium,
                              child: Text('中'),
                            ),
                            DropdownMenuItem(
                              value: TaskPriority.high,
                              child: Text('高'),
                            ),
                            DropdownMenuItem(
                              value: TaskPriority.urgent,
                              child: Text('紧急'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        DropdownButtonFormField<TaskEnergyLevel>(
                          key: const Key('recurring-energy-level'),
                          initialValue: _energy,
                          decoration: const InputDecoration(labelText: '精力要求'),
                          onChanged: _saving
                              ? null
                              : (value) => setState(
                                  () =>
                                      _energy = value ?? TaskEnergyLevel.medium,
                                ),
                          items: const [
                            DropdownMenuItem(
                              value: TaskEnergyLevel.low,
                              child: Text('低'),
                            ),
                            DropdownMenuItem(
                              value: TaskEnergyLevel.medium,
                              child: Text('中'),
                            ),
                            DropdownMenuItem(
                              value: TaskEnergyLevel.high,
                              child: Text('高'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          key: const Key('recurring-preferred-window'),
                          controller: _window,
                          enabled: !_saving,
                          decoration: InputDecoration(
                            labelText: '期望时段（可选）',
                            hintText: '例如 20:00-22:00',
                            helperText: '留空表示不限制。只影响排程偏好，不是硬约束。',
                            errorText: _errors['window'],
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          key: const Key('recurring-notes'),
                          controller: _notes,
                          enabled: !_saving,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: '备注（可选）',
                          ),
                        ),
                      ],
                    ),
                    if (_failure != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
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

  Widget _areaPicker(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: DropdownButtonFormField<String>(
      key: const Key('recurring-area'),
      initialValue: _areaId,
      decoration: InputDecoration(
        labelText: '领域',
        errorText: _errors['areaId'],
      ),
      onChanged: _saving
          ? null
          : (value) => setState(() {
              _areaId = value;
              // 领域先于项目：换领域时旧项目未必属于新领域，留着会让保存被
              // "所选项目不属于当前领域"拒绝，而用户看不出为什么。
              _projectId = null;
            }),
      items: [
        for (final area in _areas)
          DropdownMenuItem(value: area.id, child: Text(area.name)),
      ],
    ),
  );

  Widget _projectPicker(BuildContext context) =>
      DropdownButtonFormField<String>(
        key: ValueKey('recurring-project-$_areaId-$_projectId'),
        initialValue: _projectId,
        decoration: InputDecoration(
          labelText: '项目（可选）',
          errorText: _errors['projectId'],
          helperText: '只显示当前领域下的项目。',
        ),
        onChanged: _saving
            ? null
            : (value) => setState(() => _projectId = value),
        items: [
          const DropdownMenuItem(value: null, child: Text('不归属项目')),
          for (final project in _projectsOfArea)
            DropdownMenuItem(value: project.id, child: Text(project.name)),
        ],
      );

  Widget _weekdayPicker(BuildContext context) => InputDecorator(
    key: const Key('recurring-weekdays'),
    decoration: InputDecoration(
      labelText: '允许星期',
      errorText: _errors['weekdays'],
    ),
    child: Wrap(
      spacing: 8,
      children: [
        for (
          var weekday = DateTime.monday;
          weekday <= DateTime.sunday;
          weekday++
        )
          FilterChip(
            key: Key('recurring-weekday-$weekday'),
            label: Text(_weekdayLabel(weekday)),
            selected: isWeekdayAllowed(_weekdaysMask, weekday),
            onSelected: _saving
                ? null
                : (selected) => setState(() {
                    _weekdaysMask = selected
                        ? _weekdaysMask | (1 << (weekday - 1))
                        : _weekdaysMask & ~(1 << (weekday - 1));
                  }),
          ),
      ],
    ),
  );

  Future<void> _pickEndsOn() async {
    final now = widget.zones.toLocal(widget.nowUtc, widget.timeZoneId);
    final picked = await showDatePicker(
      context: context,
      initialDate: _endsOn ?? DateTime(now.year, now.month, now.day),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null || !mounted) return;
    setState(() => _endsOn = picked);
  }

  Widget _dateField(
    BuildContext context, {
    required String label,
    required DateTime? value,
    required String emptyText,
    required String fieldKey,
    required String buttonKey,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) => InputDecorator(
    key: Key(fieldKey),
    decoration: InputDecoration(labelText: label),
    child: Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(value == null ? emptyText : formatLocalDate(value)),
        TextButton(
          key: Key(buttonKey),
          onPressed: _saving ? null : onPick,
          child: const Text('选择日期'),
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

  Widget _saveBar(BuildContext context) => Material(
    key: const Key('recurring-save-bar'),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton(
            key: const Key('save-recurring'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存周期目标'),
          ),
          TextButton(
            key: const Key('cancel-recurring'),
            onPressed: _saving ? null : widget.onCancel,
            child: const Text('取消'),
          ),
          if (_errors.isNotEmpty)
            Text(
              '还有字段需要修正',
              key: const Key('recurring-missing-fields'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );

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

  Widget _field(
    TextEditingController controller,
    String label,
    String key, {
    bool number = false,
    bool autofocus = false,
    String? error,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: TextField(
      key: Key(key),
      controller: controller,
      enabled: !_saving,
      autofocus: autofocus,
      keyboardType: number ? TextInputType.number : null,
      decoration: InputDecoration(
        labelText: label,
        errorText: error,
        helperText: helper,
        helperMaxLines: 3,
      ),
    ),
  );
}

String _minuteLabel(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:'
    '${(minute % 60).toString().padLeft(2, '0')}';

String _weekdayLabel(int weekday) => switch (weekday) {
  DateTime.monday => '周一',
  DateTime.tuesday => '周二',
  DateTime.wednesday => '周三',
  DateTime.thursday => '周四',
  DateTime.friday => '周五',
  DateTime.saturday => '周六',
  _ => '周日',
};
