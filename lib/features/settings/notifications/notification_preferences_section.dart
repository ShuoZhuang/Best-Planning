import 'package:flutter/material.dart';

final class NotificationPreferencesSection extends StatelessWidget {
  const NotificationPreferencesSection({
    required this.taskLeadController,
    required this.calendarLeadController,
    required this.deadlineLeadController,
    required this.quietStartController,
    required this.quietEndController,
    required this.enabled,
    required this.taskStartEnabled,
    required this.calendarStartEnabled,
    required this.deadlineEnabled,
    required this.conflictEnabled,
    required this.onEnabledChanged,
    required this.onTaskStartChanged,
    required this.onCalendarStartChanged,
    required this.onDeadlineChanged,
    required this.onConflictChanged,
    this.recurringGoalEnabled = true,
    this.onRecurringGoalChanged,
    required this.errors,
    super.key,
  });

  final TextEditingController taskLeadController;
  final TextEditingController calendarLeadController;
  final TextEditingController deadlineLeadController;
  final TextEditingController quietStartController;
  final TextEditingController quietEndController;

  /// **通知总开关**（1.8.0，设计规范 §5.1）。
  ///
  /// 关闭时下面五个分类值**保留但不生效**：再打开时用户应当看到原来的勾选，而不是被重置。
  /// 因此关闭时**不隐藏**分类开关——隐藏会让"我原来选了哪些"在界面上无法确认，而保留
  /// （置灰）才是"值还在、只是不生效"的诚实表达。
  final bool enabled;
  final bool taskStartEnabled;
  final bool calendarStartEnabled;
  final bool deadlineEnabled;
  final bool conflictEnabled;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<bool> onTaskStartChanged;
  final ValueChanged<bool> onCalendarStartChanged;
  final ValueChanged<bool> onDeadlineChanged;
  final ValueChanged<bool> onConflictChanged;

  /// 周期目标提醒的开关（§3.5、§11 Task 9）。默认开启。
  ///
  /// 与另外四类并列，而不是藏进周期目标自己的页面：用户找"别提醒我"的时候会来通知设置，
  /// 而不会想到去周期目标里找一个开关。**`onRecurringGoalChanged` 为空时不渲染**——
  /// 与这个应用其它端口同一口径，不给点了没反应的开关。
  final bool recurringGoalEnabled;
  final ValueChanged<bool>? onRecurringGoalChanged;

  final Map<String, String> errors;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Switch(
        key: const Key('notifications-enabled'),
        title: '启用通知',
        value: enabled,
        onChanged: onEnabledChanged,
      ),
      Text(
        enabled
            ? '关闭总开关会立即取消已排入系统的全部提醒，各分类的选择会保留。'
            : '总开关已关闭：已排入系统的提醒正在取消，各分类的选择会保留，重新开启后恢复。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      // 分类开关在总开关关闭时**仍然显示但不可改**：值还在，只是不生效（§5.1）。
      // 灰掉而不是隐藏，用户才能确认"我原来选的是哪些"。
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _Switch(
            title: '任务开始提醒',
            value: taskStartEnabled,
            onChanged: enabled ? onTaskStartChanged : null,
          ),
          _Switch(
            title: '固定日程提醒',
            value: calendarStartEnabled,
            onChanged: enabled ? onCalendarStartChanged : null,
          ),
          _Switch(
            title: '截止临近提醒',
            value: deadlineEnabled,
            onChanged: enabled ? onDeadlineChanged : null,
          ),
          _Switch(
            title: '冲突待处理提醒',
            value: conflictEnabled,
            onChanged: enabled ? onConflictChanged : null,
          ),
          if (onRecurringGoalChanged case final onRecurringGoalChanged?)
            _Switch(
              title: '周期目标提醒',
              value: recurringGoalEnabled,
              onChanged: enabled ? onRecurringGoalChanged : null,
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
    super.key,
  });

  final String title;
  final bool value;

  /// 为空时**开关不可操作**（总开关关闭时各分类走这一支）。
  final ValueChanged<bool>? onChanged;

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
