import 'package:flutter/material.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';

final class PeriodTemplateEditor extends StatefulWidget {
  const PeriodTemplateEditor({required this.service, super.key});

  final AcademicCalendarService service;

  @override
  State<PeriodTemplateEditor> createState() => _PeriodTemplateEditorState();
}

final class _PeriodTemplateEditorState extends State<PeriodTemplateEditor> {
  final _name = TextEditingController(text: '默认课表');
  final _firstStart = TextEditingController(text: '08:00');
  final _duration = TextEditingController(text: '45');
  final _break = TextEditingController(text: '10');
  final _count = TextEditingController(text: '12');
  final List<(TextEditingController, TextEditingController)> _rows = [];
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _name.dispose();
    _firstStart.dispose();
    _duration.dispose();
    _break.dispose();
    _count.dispose();
    for (final row in _rows) {
      row.$1.dispose();
      row.$2.dispose();
    }
    super.dispose();
  }

  void _generate() {
    final start = _minute(_firstStart.text);
    final duration = int.tryParse(_duration.text);
    final gap = int.tryParse(_break.text);
    final count = int.tryParse(_count.text);
    if (start == null ||
        duration == null ||
        duration <= 0 ||
        gap == null ||
        gap < 0 ||
        count == null ||
        count < 1 ||
        count > 30) {
      setState(() => _error = '请填写有效的首节时间、时长、课间和节数');
      return;
    }
    for (final row in _rows) {
      row.$1.dispose();
      row.$2.dispose();
    }
    _rows.clear();
    var cursor = start;
    for (var index = 0; index < count; index++) {
      _rows.add((
        TextEditingController(text: _clock(cursor)),
        TextEditingController(text: _clock(cursor + duration)),
      ));
      cursor += duration + gap;
    }
    if (mounted) setState(() => _error = null);
  }

  Future<void> _save() async {
    try {
      final entries = <PeriodEntry>[];
      for (final (index, row) in _rows.indexed) {
        final start = _minute(row.$1.text);
        final end = _minute(row.$2.text);
        if (start == null || end == null) {
          throw ArgumentError('第 ${index + 1} 节时间格式无效');
        }
        entries.add(
          PeriodEntry(
            periodNumber: index + 1,
            startMinute: start,
            endMinute: end,
          ),
        );
      }
      await widget.service.saveTemplate(
        name: _name.text,
        entries: entries,
        isDefault: true,
      );
      if (mounted) setState(() => _status = '节次模板已保存');
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error is ArgumentError
              ? error.message?.toString()
              : '$error';
          _status = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('节次模板', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      TextField(
        key: const Key('period-template-name'),
        controller: _name,
        decoration: const InputDecoration(labelText: '模板名称'),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _field(_firstStart, '第一节开始', const Key('period-first-start')),
          _field(_duration, '每节分钟', const Key('period-duration')),
          _field(_break, '课间分钟', const Key('period-break')),
          _field(_count, '总节数', const Key('period-count')),
          FilledButton.tonal(onPressed: _generate, child: const Text('批量生成')),
        ],
      ),
      const SizedBox(height: 24),
      for (final (index, row) in _rows.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              SizedBox(width: 72, child: Text('第 ${index + 1} 节')),
              Expanded(
                child: TextField(
                  key: Key('period-start-${index + 1}'),
                  controller: row.$1,
                  decoration: const InputDecoration(labelText: '开始'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: Key('period-end-${index + 1}'),
                  controller: row.$2,
                  decoration: const InputDecoration(labelText: '结束'),
                ),
              ),
            ],
          ),
        ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      if (_status != null) Text(_status!),
      const SizedBox(height: 12),
      FilledButton(onPressed: _save, child: const Text('保存节次模板')),
    ],
  );

  Widget _field(TextEditingController controller, String label, Key key) =>
      SizedBox(
        width: 140,
        child: TextField(
          key: key,
          controller: controller,
          decoration: InputDecoration(labelText: label),
        ),
      );
}

int? _minute(String raw) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(raw.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour > 23 || minute > 59) return null;
  return hour * 60 + minute;
}

String _clock(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:'
    '${(minute % 60).toString().padLeft(2, '0')}';
