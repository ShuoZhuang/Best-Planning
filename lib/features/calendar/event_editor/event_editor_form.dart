import 'package:flutter/material.dart';
import 'package:personal_planner/application/calendar_service.dart';

final class EventEditorForm extends StatefulWidget {
  const EventEditorForm({
    required this.service,
    required this.initialStartUtc,
    required this.initialEndUtc,
    this.recurrenceRuleId,
    super.key,
  });

  final CalendarService service;
  final DateTime initialStartUtc;
  final DateTime initialEndUtc;
  final String? recurrenceRuleId;

  @override
  State<EventEditorForm> createState() => _EventEditorFormState();
}

final class _EventEditorFormState extends State<EventEditorForm> {
  final _titleController = TextEditingController();
  Map<String, String> _errors = const {};
  String? _status;
  EventEditScope _scope = EventEditScope.singleOccurrence;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final result = await widget.service.save(
      EventDraft(
        title: _titleController.text,
        startAtUtc: widget.initialStartUtc,
        endAtUtc: widget.initialEndUtc,
        recurrenceRuleId: widget.recurrenceRuleId,
        editScope: _scope,
      ),
    );
    if (!mounted) return;
    setState(() {
      _errors = result.fieldErrors;
      _status = result.isSuccess ? '日程已保存' : null;
    });
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
}
