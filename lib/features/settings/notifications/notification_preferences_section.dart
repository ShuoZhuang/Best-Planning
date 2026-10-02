import 'package:flutter/material.dart';

final class NotificationPreferencesSection extends StatelessWidget {
  const NotificationPreferencesSection({
    required this.taskLeadController,
    required this.calendarLeadController,
    required this.deadlineLeadController,
    required this.quietStartController,
    required this.quietEndController,
    required this.taskStartEnabled,
    required this.calendarStartEnabled,
    required this.deadlineEnabled,
    required this.conflictEnabled,
    required this.onTaskStartChanged,
    required this.onCalendarStartChanged,
    required this.onDeadlineChanged,
    required this.onConflictChanged,
    required this.errors,
    super.key,
  });

  final TextEditingController taskLeadController;
  final TextEditingController calendarLeadController;
  final TextEditingController deadlineLeadController;
  final TextEditingController quietStartController;
  final TextEditingController quietEndController;
  final bool taskStartEnabled;
  final bool calendarStartEnabled;
  final bool deadlineEnabled;
  final bool conflictEnabled;
  final ValueChanged<bool> onTaskStartChanged;
  final ValueChanged<bool> onCalendarStartChanged;
  final ValueChanged<bool> onDeadlineChanged;
  final ValueChanged<bool> onConflictChanged;
  final Map<String, String> errors;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _Switch(
            title: '任务开始提醒',
            value: taskStartEnabled,
            onChanged: onTaskStartChanged,
          ),
          _Switch(
            title: '固定日程提醒',
            value: calendarStartEnabled,
            onChanged: onCalendarStartChanged,
          ),
          _Switch(
            title: '截止临近提醒',
            value: deadlineEnabled,
            onChanged: onDeadlineChanged,
          ),
          _Switch(
            title: '冲突待处理提醒',
            value: conflictEnabled,
            onChanged: onConflictChanged,
          ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _NumberField(
            controller: taskLeadController,
            label: '任务开始提前（分钟）',
            errorText: errors['taskNotificationLead'],
          ),
          _NumberField(
            controller: calendarLeadController,
            label: '固定日程提前（分钟）',
            errorText: errors['calendarNotificationLead'],
          ),
          _NumberField(
            controller: deadlineLeadController,
            label: '截止日期提前（分钟）',
            errorText: errors['deadlineNotificationLead'],
          ),
          _TextField(
            controller: quietStartController,
            label: '免打扰开始',
            errorText: errors['quietHours'],
          ),
          _TextField(
            controller: quietEndController,
            label: '免打扰结束',
            errorText: errors['quietHours'],
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '普通通知在免打扰期间延后；冲突待处理提醒仍会保留。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}

final class _Switch extends StatelessWidget {
  const _Switch({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 260,
    child: SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      value: value,
      onChanged: onChanged,
    ),
  );
}

final class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    this.errorText,
  });

  final TextEditingController controller;
  final String label;
  final String? errorText;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 220,
    child: TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, errorText: errorText),
    ),
  );
}

final class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.label,
    this.errorText,
  });

  final TextEditingController controller;
  final String label;
  final String? errorText;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 180,
    child: TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'HH:mm',
        errorText: errorText,
      ),
    ),
  );
}
