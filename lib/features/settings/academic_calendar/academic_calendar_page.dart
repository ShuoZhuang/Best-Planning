import 'package:flutter/material.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/features/settings/academic_calendar/period_template_editor.dart';

final class AcademicCalendarPage extends StatefulWidget {
  const AcademicCalendarPage({
    required this.service,
    required this.referenceDate,
    required this.timeZoneId,
    super.key,
  });

  final AcademicCalendarService service;
  final DateTime referenceDate;
  final String timeZoneId;

  @override
  State<AcademicCalendarPage> createState() => _AcademicCalendarPageState();
}

final class _AcademicCalendarPageState extends State<AcademicCalendarPage> {
  final _name = TextEditingController(text: '本学期');
  final _week = TextEditingController(text: '1');
  final _totalWeeks = TextEditingController(text: '16');
  late final TextEditingController _reference;
  late final TextEditingController _firstMonday;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _reference = TextEditingController(text: _date(widget.referenceDate));
    _firstMonday = TextEditingController(
      text: _date(
        AcademicWeekCalculator.firstWeekMonday(
          referenceDate: widget.referenceDate,
          weekNumber: 1,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _week.dispose();
    _totalWeeks.dispose();
    _reference.dispose();
    _firstMonday.dispose();
    super.dispose();
  }

  void _fromReference() {
    final reference = _parseDate(_reference.text);
    final week = int.tryParse(_week.text);
    if (reference == null || week == null || week < 1) return;
    _firstMonday.text = _date(
      AcademicWeekCalculator.firstWeekMonday(
        referenceDate: reference,
        weekNumber: week,
      ),
    );
    setState(() {});
  }

  void _fromFirstMonday() {
    final reference = _parseDate(_reference.text);
    final first = _parseDate(_firstMonday.text);
    if (reference == null || first == null) return;
    try {
      _week.text = AcademicWeekCalculator.weekNumber(
        firstWeekMonday: first,
        date: reference,
      ).toString();
      setState(() {});
    } on ArgumentError {
      setState(() => _error = '参考日期必须位于第一周之后');
    }
  }

  Future<void> _saveTerm() async {
    final first = _parseDate(_firstMonday.text);
    final weeks = int.tryParse(_totalWeeks.text);
    if (first == null || weeks == null) {
      setState(() => _error = '请填写有效的学期日期与总周数');
      return;
    }
    try {
      await widget.service.saveTerm(
        name: _name.text,
        firstWeekMonday: first,
        totalWeeks: weeks,
        timeZoneId: widget.timeZoneId,
      );
      if (mounted) {
        setState(() {
          _error = null;
          _status = '学期设置已保存';
        });
      }
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _error = error.message?.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('学期与节次模板')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('学期校准', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('“参考日期 + 当前周数”和“第一周星期一”会相互换算。'),
        const SizedBox(height: 24),
        TextField(
          key: const Key('academic-term-name'),
          controller: _name,
          decoration: const InputDecoration(labelText: '学期名称'),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _field(
              _reference,
              '参考日期',
              const Key('academic-reference-date'),
              _fromReference,
            ),
            _field(
              _week,
              '当前第几周',
              const Key('academic-current-week'),
              _fromReference,
            ),
            _field(
              _firstMonday,
              '第一周星期一',
              const Key('academic-first-monday'),
              _fromFirstMonday,
            ),
            _field(
              _totalWeeks,
              '总教学周数',
              const Key('academic-total-weeks'),
              () {},
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_status != null) Text(_status!),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(onPressed: _saveTerm, child: const Text('保存学期')),
        ),
        const SizedBox(height: 32),
        const Divider(),
        const SizedBox(height: 24),
        PeriodTemplateEditor(service: widget.service),
      ],
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label,
    Key key,
    VoidCallback onChanged,
  ) => SizedBox(
    width: 210,
    child: TextField(
      key: key,
      controller: controller,
      onChanged: (_) => onChanged(),
      decoration: InputDecoration(labelText: label),
    ),
  );
}

DateTime? _parseDate(String raw) {
  final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(raw.trim());
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final value = DateTime(year, month, day);
  return value.year == year && value.month == month && value.day == day
      ? value
      : null;
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
