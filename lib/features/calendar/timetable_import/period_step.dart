import 'package:flutter/material.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';

final class TimetablePeriodStep extends StatelessWidget {
  const TimetablePeriodStep({required this.controller, super.key});

  final TimetableImportController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('设置节次时间', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '识别到的“第 1–2 节”会使用这里的真实开始与结束时间。可以选择模板，也可逐节修改。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        if (controller.savedTemplates.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            key: const Key('period-template-picker'),
            initialValue: controller.selectedTemplateId,
            decoration: const InputDecoration(labelText: '节次模板'),
            items: [
              for (final template in controller.savedTemplates)
                DropdownMenuItem(
                  value: template.id,
                  child: Text(template.name),
                ),
            ],
            onChanged: controller.selectTemplate,
          ),
          const SizedBox(height: 16),
        ],
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              for (final entry in controller.periodEntries)
                _PeriodRow(entry: entry, controller: controller),
            ],
          ),
        ),
        if (controller.periodValidationMessage != null) ...[
          const SizedBox(height: 10),
          Text(
            controller.periodValidationMessage!,
            key: const Key('period-validation-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 14),
        OutlinedButton.icon(
          key: const Key('add-period-row'),
          onPressed: controller.addPeriod,
          icon: const Icon(Icons.add_rounded),
          label: const Text('添加一节'),
        ),
      ],
    );
  }
}

final class _PeriodRow extends StatelessWidget {
  const _PeriodRow({required this.entry, required this.controller});
  final PeriodEntry entry;
  final TimetableImportController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
    child: Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            '第 ${entry.periodNumber} 节',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton(
            onPressed: () => _pick(context, true),
            child: Text('开始 ${_time(entry.startMinute)}'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Icon(Icons.arrow_forward_rounded, size: 18),
        ),
        Expanded(
          child: OutlinedButton(
            onPressed: () => _pick(context, false),
            child: Text('结束 ${_time(entry.endMinute)}'),
          ),
        ),
        IconButton(
          tooltip: '删除节次',
          onPressed: () => controller.removePeriod(entry.periodNumber),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );

  Future<void> _pick(BuildContext context, bool start) async {
    final minute = start ? entry.startMinute : entry.endMinute;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
      helpText: start ? '选择开始时间' : '选择结束时间',
    );
    if (picked == null) return;
    final value = picked.hour * 60 + picked.minute;
    if ((start && value >= entry.endMinute) ||
        (!start && value <= entry.startMinute)) {
      return;
    }
    controller.updatePeriod(
      PeriodEntry(
        periodNumber: entry.periodNumber,
        startMinute: start ? value : entry.startMinute,
        endMinute: start ? entry.endMinute : value,
      ),
    );
  }

  static String _time(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
}
