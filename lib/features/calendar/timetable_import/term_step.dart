import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_pickers.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';

final class TimetableTermStep extends StatelessWidget {
  const TimetableTermStep({required this.controller, super.key});

  final TimetableImportController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('确认学期', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '“当前是第几周”和“第一周周一”会相互换算，修改任意一项即可。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        if (controller.savedTerms.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            key: const Key('saved-term-picker'),
            initialValue: controller.selectedTermId,
            decoration: const InputDecoration(labelText: '使用已保存学期'),
            items: [
              for (final term in controller.savedTerms)
                DropdownMenuItem(value: term.id, child: Text(term.name)),
            ],
            onChanged: controller.selectTerm,
          ),
          const SizedBox(height: 16),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            final fields = [
              TextFormField(
                key: const Key('term-name'),
                initialValue: controller.termName,
                decoration: const InputDecoration(labelText: '学期名称'),
                onChanged: controller.setTermName,
              ),
              TextFormField(
                key: ValueKey('current-week-${controller.currentWeek}'),
                initialValue: '${controller.currentWeek}',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '当前周次',
                  prefixText: '第 ',
                  suffixText: ' 周',
                ),
                onChanged: (value) {
                  final week = int.tryParse(value);
                  if (week != null) controller.setCurrentWeek(week);
                },
              ),
              TextFormField(
                key: ValueKey('total-weeks-${controller.totalWeeks}'),
                initialValue: '${controller.totalWeeks}',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '总教学周数',
                  suffixText: ' 周',
                ),
                onChanged: (value) {
                  final weeks = int.tryParse(value);
                  if (weeks != null) controller.setTotalWeeks(weeks);
                },
              ),
            ];
            if (constraints.maxWidth < 720) {
              return Column(
                children: [
                  for (final field in fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: field,
                    ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final field in fields)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 14),
                      child: field,
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 6),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 6,
          ),
          tileColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: const Icon(Icons.event_outlined),
          title: const Text('第一周周一'),
          subtitle: Text(_date(controller.firstWeekMonday)),
          trailing: const Icon(Icons.edit_calendar_outlined),
          onTap: () => _pickMonday(context),
        ),
        const SizedBox(height: 14),
        Text(
          '换算基准：${_date(controller.referenceDate)} 是第 ${controller.currentWeek} 周。',
          key: const Key('term-conversion-summary'),
          style: TextStyle(color: Theme.of(context).colorScheme.primary),
        ),
      ],
    );
  }

  Future<void> _pickMonday(BuildContext context) async {
    final picked = await showDatePicker(
      builder: plannerPickerBuilder,
      context: context,
      initialDate: controller.firstWeekMonday,
      firstDate: DateTime(controller.referenceDate.year - 2),
      lastDate: controller.referenceDate,
      helpText: '选择第一周的周一',
      selectableDayPredicate: (day) => day.weekday == DateTime.monday,
    );
    if (picked != null) controller.setFirstWeekMonday(picked);
  }

  static String _date(DateTime value) =>
      '${value.year}年${value.month}月${value.day}日';
}
