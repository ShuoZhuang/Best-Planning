import 'package:flutter/material.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/time_zone.dart';

final class EventEditorForm extends StatefulWidget {
  const EventEditorForm({
    required this.service,
    required this.initialStartUtc,
    required this.initialEndUtc,
    required this.timeZoneId,
    required this.zones,
    this.recurrenceRuleId,
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
  Map<String, String> _errors = const {};
  String? _status;
  EventEditScope _scope = EventEditScope.singleOccurrence;
  bool _weekly = false;
  late Set<int> _weekdays;

  @override
  void initState() {
    super.initState();
    final start = widget.zones.toLocal(
      widget.initialStartUtc,
      widget.timeZoneId,
    );
    final end = widget.zones.toLocal(widget.initialEndUtc, widget.timeZoneId);
    _weekdays = {start.weekday};
    _startDateController = TextEditingController(text: _date(start));
    _startTimeController = TextEditingController(text: _time(start));
    _endDateController = TextEditingController(text: _date(end));
    _endTimeController = TextEditingController(text: _time(end));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _startDateController.dispose();
    _startTimeController.dispose();
    _endDateController.dispose();
    _endTimeController.dispose();
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
    final result = await widget.service.save(
      EventDraft(
        title: _titleController.text,
        startAtUtc: startAtUtc,
        endAtUtc: endAtUtc,
        timeZoneId: widget.timeZoneId,
        recurrenceRuleId: widget.recurrenceRuleId,
        editScope: _scope,
        recurrenceWeekdays: _weekly ? _weekdays : const {},
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
