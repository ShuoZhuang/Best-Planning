import 'package:flutter/material.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/workspace.dart';

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

  @override
  State<EventEditorForm> createState() => _EventEditorFormState();
}

final class _EventEditorFormState extends State<EventEditorForm> {
  final _titleController = TextEditingController();
  late final TextEditingController _startDateController;
  late final TextEditingController _startTimeController;
  late final TextEditingController _endDateController;
  late final TextEditingController _endTimeController;
  late final TextEditingController _recurrenceEndController;
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
    _startDateController = TextEditingController(text: _date(start));
    _startTimeController = TextEditingController(text: _time(start));
    _endDateController = TextEditingController(text: _date(end));
    _endTimeController = TextEditingController(text: _time(end));
    _recurrenceEndController = TextEditingController();
    _intervalController = TextEditingController(text: '1');
    _areaId = widget.initialAreaId;
    _projectId = widget.initialProjectId;
    _loadWorkspace();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _startDateController.dispose();
    _startTimeController.dispose();
    _endDateController.dispose();
    _endTimeController.dispose();
    _recurrenceEndController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final startAtUtc = _parseLocal(
      _startDateController.text,
      _startTimeController.text,
    );
    final endAtUtc = _parseLocal(
      _endDateController.text,
      _endTimeController.text,
    );
    if (startAtUtc == null || endAtUtc == null) {
      setState(() {
        _errors = const {'time': '请按 YYYY-MM-DD 和 HH:mm 填写有效时间'};
        _status = null;
      });
      return;
    }
    final recurrenceEndInput = _recurrenceEndController.text.trim();
    final recurrenceEnd = recurrenceEndInput.isEmpty
        ? null
        : _parseDate(recurrenceEndInput);
    if (_weekly && recurrenceEndInput.isNotEmpty && recurrenceEnd == null) {
      setState(() {
        _errors = const {'recurrence': '请按 YYYY-MM-DD 填写重复结束日期'};
        _status = null;
      });
      return;
    }
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
    });
    if (result.isSuccess) widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) {
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
                  : (value) => setState(() => _projectId = value),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _timeField(
              key: const Key('event-start-date'),
              controller: _startDateController,
              label: '开始日期',
              hint: 'YYYY-MM-DD',
              width: 190,
            ),
            _timeField(
              key: const Key('event-start-time'),
              controller: _startTimeController,
              label: '开始时间',
              hint: 'HH:mm',
              width: 140,
            ),
            _timeField(
              key: const Key('event-end-date'),
              controller: _endDateController,
              label: '结束日期',
              hint: 'YYYY-MM-DD',
              width: 190,
            ),
            _timeField(
              key: const Key('event-end-time'),
              controller: _endTimeController,
              label: '结束时间',
              hint: 'HH:mm',
              width: 140,
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
              _timeField(
                key: const Key('event-recurrence-end-date'),
                controller: _recurrenceEndController,
                label: '重复结束日期（可选）',
                hint: 'YYYY-MM-DD',
                width: 240,
              ),
              if (_recurrencePreset == 'custom')
                _timeField(
                  key: const Key('event-recurrence-interval'),
                  controller: _intervalController,
                  label: '每隔几周',
                  hint: '1–52',
                  width: 160,
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
                setState(() => _scope = selection.single),
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

  Widget _timeField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required String hint,
    required double width,
  }) => SizedBox(
    width: width,
    child: TextField(
      key: key,
      controller: controller,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );

  DateTime? _parseLocal(String dateInput, String timeInput) {
    final date = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$')
        .firstMatch(dateInput.trim());
    final time = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(timeInput.trim());
    if (date == null || time == null) return null;
    final year = int.parse(date.group(1)!);
    final month = int.parse(date.group(2)!);
    final day = int.parse(date.group(3)!);
    final hour = int.parse(time.group(1)!);
    final minute = int.parse(time.group(2)!);
    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31 ||
        hour > 23 ||
        minute > 59) {
      return null;
    }
    final localDate = DateTime(year, month, day);
    if (localDate.year != year ||
        localDate.month != month ||
        localDate.day != day) {
      return null;
    }
    return widget.zones.localDateTimeToUtc(
      localDate,
      hour * 60 + minute,
      widget.timeZoneId,
    );
  }

  DateTime? _parseDate(String raw) {
    final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$')
        .firstMatch(raw.trim());
    if (match == null) return null;
    final date = DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
    return _date(date) ==
            '${match.group(1)!.padLeft(4, '0')}-'
                '${match.group(2)!.padLeft(2, '0')}-'
                '${match.group(3)!.padLeft(2, '0')}'
        ? date
        : null;
  }
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _time(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

String _weekdayLabel(int weekday) => switch (weekday) {
  DateTime.monday => '周一',
  DateTime.tuesday => '周二',
  DateTime.wednesday => '周三',
  DateTime.thursday => '周四',
  DateTime.friday => '周五',
  DateTime.saturday => '周六',
  _ => '周日',
};
