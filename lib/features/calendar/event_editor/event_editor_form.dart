import 'package:flutter/material.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_date_time_fields.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/update/update_safety.dart';

final class EventEditorForm extends StatefulWidget {
  const EventEditorForm({
    required this.service,
    required this.initialStartUtc,
    required this.initialEndUtc,
    required this.timeZoneId,
    required this.zones,
    this.recurrenceRuleId,
    this.initialTitle = '',
    this.workspace,
    this.initialAreaId,
    this.initialProjectId,
    this.onSaved,
    this.updateSafety,
    super.key,
  });

  final CalendarService service;
  final DateTime initialStartUtc;
  final DateTime initialEndUtc;

  /// 保存本次日程时记录的 IANA 时区标识，必须由调用方给出。
  ///
  /// 必填而不是带默认值：此前的默认值让这个表单**静默**把所有日程记成东八区，
  /// 而需求 §13 要求以本机当前时区保存（R11）。
  final String timeZoneId;
  final TimeZoneDatabase zones;

  final String? recurrenceRuleId;

  /// 打开表单时预填的标题（FR-TASK-04 的"任务转固定日程"）。
  ///
  /// 只预填标题：领域与项目在表单里**可以自己选**了（见 [workspace]），但调用方目前只传标题，
  /// 因此从任务转过来时领域不会自动带过来，用户在表单里选一次即可。
  final String initialTitle;

  /// 领域与项目的来源。
  ///
  /// 为空时不显示"分类归属"：给一个没有任何可选项的下拉框，比不显示更让人困惑。
  final WorkspaceService? workspace;

  /// 打开表单时预填的领域（编辑已有日程时用）。
  final String? initialAreaId;

  /// 打开表单时预填的项目。
  final String? initialProjectId;

  final VoidCallback? onSaved;

  /// 未保存编辑的汇报端口（2026-10-18 自更新规格 §11.4）。为空时不汇报。
  final UpdateSafetyCoordinator? updateSafety;

  @override
  State<EventEditorForm> createState() => _EventEditorFormState();
}

final class _EventEditorFormState extends State<EventEditorForm> {
  final _titleController = TextEditingController();
  late final LocalDateRangeController _range;
  DateTime? _recurrenceEnd;
  late final TextEditingController _intervalController;
  Map<String, String> _errors = const {};
  String? _status;
  EventEditScope _scope = EventEditScope.singleOccurrence;
  bool _weekly = false;
  late Set<int> _weekdays;
  String _recurrencePreset = 'weekly';
  List<PlannerArea> _areas = const [];
  List<PlannerProject> _projects = const [];
  String? _areaId;
  String? _projectId;
  bool _dirty = false;

  void _markDirty() {
    if (!mounted) return;
    setState(() => _dirty = true);
  }

  /// 当前领域下可选的项目。
  ///
  /// 项目按领域过滤：领域是长期方向，项目是它下面的一段工作，跨领域选项目会让"归属"失去意义。
  List<PlannerProject> get _visibleProjects => _areaId == null
      ? const <PlannerProject>[]
      : _projects
            .where((project) => project.areaId == _areaId)
            .toList(growable: false);

  Future<void> _loadWorkspace() async {
    final workspace = widget.workspace;
    if (workspace == null) return;
    final areas = await workspace.listAreas();
    final projects = await workspace.listProjects();
    if (!mounted) return;
    setState(() {
      _areas = areas;
      _projects = projects;
    });
  }

  void _selectArea(String? areaId) {
    setState(() {
      _areaId = areaId;
      // 换领域后原项目可能不再属于新领域，此时必须清掉——否则会保存出
      // "项目不属于所选领域"的组合。
      final belongs =
          areaId != null &&
          _projects.any(
            (project) => project.id == _projectId && project.areaId == areaId,
          );
      if (!belongs) _projectId = null;
      _dirty = true;
    });
  }

  @override
  void initState() {
    super.initState();
    final start = widget.zones.toLocal(
      widget.initialStartUtc,
      widget.timeZoneId,
    );
    final end = widget.zones.toLocal(widget.initialEndUtc, widget.timeZoneId);
    _weekdays = {start.weekday};
    // 预填标题（可能为空串）：带默认值而不是可空，表单因此不必在渲染时判空。
    _titleController.text = widget.initialTitle;
    _titleController.addListener(_markDirty);
    // **时间用类型化字段承载，不再用文本框**（1.8.0，规范 §2.7／§8.1）：
    // 此前这里是四个 `TextEditingController`，用户得自己敲 `YYYY-MM-DD` 与 `HH:mm`，
    // 而项目里早就有 `plannerPickerBuilder`。日期与时间现在由选择器给出，
    // 因此"非法输入"在界面上根本无从产生。
    _range = LocalDateRangeController(
      startDate: start,
      startTime: TimeOfDay(hour: start.hour, minute: start.minute),
      endDate: end,
      endTime: TimeOfDay(hour: end.hour, minute: end.minute),
    )..addListener(_onRangeChanged);
    _intervalController = TextEditingController(text: '1');
    _areaId = widget.initialAreaId;
    _projectId = widget.initialProjectId;
    _loadWorkspace();
  }

  /// 时长联动改动之后重建一次：字段值来自 [_range]，不重建就看不到新值。
  void _onRangeChanged() {
    if (mounted) {
      setState(() {
        _dirty = true;
      });
    }
  }

  @override
  void dispose() {
    widget.updateSafety?.setUnsavedChanges(false);
    _titleController.removeListener(_markDirty);
    _titleController.dispose();
    _range
      ..removeListener(_onRangeChanged)
      ..dispose();
    _intervalController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // 本地墙上时间 → UTC 的换算只在这里做一次；两个字段给出的都是**类型化**的值，
    // 因此这里不可能出现"解析失败"这一支（`_parseLocal` 随文本框一起删掉了）。
    final startAtUtc = widget.zones.localDateTimeToUtc(
      _range.startDate,
      _range.startTime.hour * 60 + _range.startTime.minute,
      widget.timeZoneId,
    );
    final endAtUtc = widget.zones.localDateTimeToUtc(
      _range.endDate,
      _range.endTime.hour * 60 + _range.endTime.minute,
      widget.timeZoneId,
    );
    // 规范 §8.2：结束早于或等于开始时必须**明确询问**，不做静默猜测。
    // 用户选了结束日期在次日就已经把"跨日"这件事表达清楚了，因此这里只在
    // **结束日期没有前进**（同一天或更早）时报错并请他重选。
    if (_range.endsNotAfterStart) {
      setState(() {
        _errors = const {'time': '结束时间必须晚于开始时间。若跨到次日，请把结束日期改到次日。'};
        _status = null;
      });
      return;
    }
    final recurrenceEnd = _recurrenceEnd;
    final result = await widget.service.save(
      EventDraft(
        title: _titleController.text,
        startAtUtc: startAtUtc,
        endAtUtc: endAtUtc,
        timeZoneId: widget.timeZoneId,
        areaId: _areaId,
        projectId: _projectId,
        recurrenceRuleId: widget.recurrenceRuleId,
        editScope: _scope,
        recurrenceWeekdays: _weekly ? _weekdays : const {},
        recurrenceIntervalWeeks:
            int.tryParse(_intervalController.text.trim()) ?? 0,
        recurrenceValidUntilLocalDate: recurrenceEnd,
      ),
    );
    if (!mounted) return;
    setState(() {
      _errors = result.fieldErrors;
      _status = result.isSuccess ? '日程已保存' : null;
      if (result.isSuccess) _dirty = false;
    });
    if (result.isSuccess) {
      widget.updateSafety?.setUnsavedChanges(false);
      widget.onSaved?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.updateSafety?.setUnsavedChanges(_dirty);
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('event-title'),
          controller: _titleController,
          decoration: InputDecoration(
            labelText: '日程标题',
            errorText: _errors['title'],
          ),
        ),
        const SizedBox(height: 12),
        // 分类归属：领域必选其一（可留空），项目按所选领域过滤。
        //
        // 只在有领域可用时显示：给一个没有任何可选项的下拉框，比不显示更让人困惑。
        if (_areas.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            key: const Key('event-area'),
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
            onChanged: _selectArea,
          ),
          const SizedBox(height: 12),
          KeyedSubtree(
            key: const Key('event-project'),
            child: DropdownButtonFormField<String>(
              // 领域变化时重建：项目列表与"暂不归属项目"的选中状态都随之改变。
              key: ValueKey<String?>('event-project-$_areaId-$_projectId'),
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
                  DropdownMenuItem(
                    value: project.id,
                    child: Text(project.name),
                  ),
              ],
              onChanged: _areaId == null
                  ? null
                  : (value) => setState(() {
                        _projectId = value;
                        _dirty = true;
                      }),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            // **只读、可点、键盘可达的选择器字段**（规范 §8.1）：不要求用户输入
            // `YYYY-MM-DD` 或 `HH:mm`，因此"非法输入"在界面上无从产生。
            // 字号宽度按"日期宽、时间窄"分配，与既有布局意图一致。
            SizedBox(
              width: 200,
              child: PlannerDateField(
                key: const Key('event-start-date'),
                boxKey: const Key('event-start-date-box'),
                value: _range.startDate,
                label: '开始日期',
                errorText: _errors['time'],
                onChanged: _range.setStartDate,
              ),
            ),
            SizedBox(
              width: 150,
              child: PlannerTimeField(
                key: const Key('event-start-time'),
                boxKey: const Key('event-start-time-box'),
                value: _range.startTime,
                label: '开始时间',
                onChanged: _range.setStartTime,
              ),
            ),
            SizedBox(
              width: 200,
              child: PlannerDateField(
                key: const Key('event-end-date'),
                boxKey: const Key('event-end-date-box'),
                value: _range.endDate,
                label: '结束日期',
                onChanged: _range.setEndDate,
              ),
            ),
            SizedBox(
              width: 150,
              child: PlannerTimeField(
                key: const Key('event-end-time'),
                boxKey: const Key('event-end-time-box'),
                value: _range.endTime,
                label: '结束时间',
                onChanged: _range.setEndTime,
              ),
            ),
          ],
        ),
        if (_errors['time'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _errors['time']!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '时间按 ${widget.timeZoneId} 保存',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SwitchListTile(
          key: const Key('event-weekly'),
          contentPadding: EdgeInsets.zero,
          title: const Text('每周重复'),
          subtitle: const Text('适合课程、例会和固定训练'),
          value: _weekly,
          onChanged: (value) => setState(() => _weekly = value),
        ),
        if (_weekly) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('event-recurrence-preset'),
            initialValue: _recurrencePreset,
            decoration: const InputDecoration(labelText: '重复方式'),
            items: const [
              DropdownMenuItem(value: 'weekly', child: Text('每周')),
              DropdownMenuItem(value: 'biweekly', child: Text('每两周')),
              DropdownMenuItem(value: 'odd', child: Text('单周')),
              DropdownMenuItem(value: 'even', child: Text('双周')),
              DropdownMenuItem(value: 'custom', child: Text('自定义')),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _recurrencePreset = value;
                if (value == 'weekly') _intervalController.text = '1';
                if (value == 'biweekly' || value == 'odd' || value == 'even') {
                  _intervalController.text = '2';
                }
              });
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              // 重复结束日期也是日期选择器（规范 §8.2 最后一条）。
              // **可清空**：它本来就是一个可选字段，而 `showDatePicker` 只能选一个具体日期，
              // 因此"清除"必须有独立的入口——否则用户一旦选错就再也回不到"不设结束日期"。
              SizedBox(
                width: 250,
                child: PlannerDateField(
                  key: const Key('event-recurrence-end-date'),
                  boxKey: const Key('event-recurrence-end-date-box'),
                  value: _recurrenceEnd ?? _range.startDate,
                  label: '重复结束日期（可选）',
                  onChanged: (value) => setState(() {
                        _recurrenceEnd = value;
                        _dirty = true;
                      }),
                ),
              ),
              if (_recurrenceEnd != null)
                TextButton(
                  key: const Key('event-recurrence-end-clear'),
                  onPressed: () => setState(() {
                        _recurrenceEnd = null;
                        _dirty = true;
                      }),
                  child: const Text('不设结束日期'),
                ),
              if (_recurrenceEnd == null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('当前：不设结束日期'),
                ),
              if (_recurrencePreset == 'custom')
                SizedBox(
                  width: 170,
                  child: TextField(
                    key: const Key('event-recurrence-interval'),
                    controller: _intervalController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '每隔几周',
                      hintText: '1–52',
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var day = DateTime.monday; day <= DateTime.sunday; day++)
                FilterChip(
                  key: Key('event-weekday-$day'),
                  label: Text(_weekdayLabel(day)),
                  selected: _weekdays.contains(day),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _weekdays.add(day);
                      } else if (_weekdays.length > 1) {
                        _weekdays.remove(day);
                      }
                    });
                  },
                ),
            ],
          ),
          if (_errors['recurrence'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _errors['recurrence']!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
        if (widget.recurrenceRuleId != null)
          SegmentedButton<EventEditScope>(
            segments: const [
              ButtonSegment(
                value: EventEditScope.singleOccurrence,
                label: Text('仅本次'),
              ),
              ButtonSegment(
                value: EventEditScope.followingOccurrences,
                label: Text('本次及以后'),
              ),
              ButtonSegment(
                value: EventEditScope.entireSeries,
                label: Text('整个系列'),
              ),
            ],
            selected: {_scope},
            onSelectionChanged: (selection) =>
                setState(() {
                  _scope = selection.single;
                  _dirty = true;
                }),
          ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _save, child: const Text('保存日程')),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_status!),
          ),
      ],
    );
  }
}

String _weekdayLabel(int weekday) => switch (weekday) {
  DateTime.monday => '周一',
  DateTime.tuesday => '周二',
  DateTime.wednesday => '周三',
  DateTime.thursday => '周四',
  DateTime.friday => '周五',
  DateTime.saturday => '周六',
  _ => '周日',
};
