import 'package:flutter/material.dart';

import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_date_time_fields.dart';
import 'package:personal_planner/design/planner_editor_scaffold.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';

/// 新建／编辑一条**自定义保护时间**（1.8.0，设计规范 §9.2）。
///
/// **为什么要有独立页面**：1.7 及以前，"新建 → 保护时间"直接跳到 `/settings/rules`
/// （§2.8）。那个页面负责的是**长期默认规则**（午餐、晚餐、固定休息），它表达不了
/// "某天 14:00–15:00 不安排"，也表达不了"每周二自定义保护时间"。用户在"新建"里选了
/// 保护时间，想要的是一次具体的编辑，而不是去改全局默认值。
///
/// **数据上不另建模型**（§9.1）：这一页保存的仍是一个 `CalendarEvent`，只是
/// `kind: CalendarEventKind.protected`。展开、例外、冲突检测全部复用固定日程那一套。
///
/// **字段与固定日程不同的只有一处**：没有领域／项目。保护时间的语义是"这段时间不安排
/// 任何事"，把它归到某个领域会让"领域时间分配"多出一份并不存在的占用。
final class ProtectedTimeEditorPage extends StatefulWidget {
  const ProtectedTimeEditorPage({
    required this.service,
    required this.timeZoneId,
    required this.zones,
    this.workspace,
    this.initialTitle = defaultTitle,
    this.initialNotes = '',
    this.onSaved,
    this.onCancel,
    super.key,
  });

  /// 标题默认值（规范 §9.2："标题默认「保护时间」，用户可改"）。
  static const defaultTitle = '保护时间';

  final CalendarService service;
  final String timeZoneId;
  final TimeZoneDatabase zones;

  /// 保留给将来"保护时间也能控领域"的扩展位；当前不用，因此可以为空。
  final WorkspaceService? workspace;

  final String initialTitle;

  /// 已有备注（编辑既有事项时用）。
  ///
  /// **必须有这一项**：编辑器若只接受标题、却在保存时把 `notes` 写成空串，
  /// 那么"编辑一次导入的课"就会**静默抹掉它的备注**——课表导入正是用 `notes`
  /// 存教师名的。这与本批次其他几处同型：**能读的字段必须也能原样写回**。
  final String initialNotes;
  final VoidCallback? onSaved;
  final VoidCallback? onCancel;

  @override
  State<ProtectedTimeEditorPage> createState() =>
      _ProtectedTimeEditorPageState();
}

final class _ProtectedTimeEditorPageState
    extends State<ProtectedTimeEditorPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late final LocalDateRangeController _range;
  Map<String, String> _errors = const {};
  bool _weekly = false;
  late Set<int> _weekdays;
  DateTime? _recurrenceEnd;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _notesController = TextEditingController(text: widget.initialNotes);
    // 默认给"今天 14:00–15:00"：一个 60 分钟的具体区间比空字段更容易改。
    final now = widget.zones.toLocal(DateTime.now().toUtc(), widget.timeZoneId);
    final date = DateTime(now.year, now.month, now.day);
    _range = LocalDateRangeController(
      startDate: date,
      startTime: const TimeOfDay(hour: 14, minute: 0),
      endDate: date,
      endTime: const TimeOfDay(hour: 15, minute: 0),
    )..addListener(_onRangeChanged);
    _weekdays = {date.weekday};
  }

  void _onRangeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _range
      ..removeListener(_onRangeChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final errors = <String, String>{};
    if (title.isEmpty) {
      errors['title'] = '请填写标题';
    }
    // 规范 §9.2／§8.2：结束不晚于开始时明确报错，不做静默猜测。
    if (_range.endsNotAfterStart) {
      errors['time'] = '结束时间必须晚于开始时间。若跨到次日，请把结束日期改到次日。';
    }
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

    final result = await widget.service.save(
      EventDraft(
        title: title,
        startAtUtc: widget.zones.localDateTimeToUtc(
          _range.startDate,
          _range.startTime.hour * 60 + _range.startTime.minute,
          widget.timeZoneId,
        ),
        endAtUtc: widget.zones.localDateTimeToUtc(
          _range.endDate,
          _range.endTime.hour * 60 + _range.endTime.minute,
          widget.timeZoneId,
        ),
        timeZoneId: widget.timeZoneId,
        notes: _notesController.text.trim(),
        // **这一行就是"保护时间"的全部数据表示**（规范 §9.1）。
        kind: CalendarEventKind.protected,
        recurrenceWeekdays: _weekly ? _weekdays : const {},
        recurrenceValidUntilLocalDate: _weekly ? _recurrenceEnd : null,
      ),
    );
    if (!mounted) return;
    setState(() => _errors = result.fieldErrors);
    if (result.isSuccess) widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) => PlannerEditorScaffold(
    // 规范 §7.2：所有编辑器共用同一骨架的标题区、返回行为、底部保存栏与错误摘要。
    title: '新建保护时间',
    subtitle: '这段时段排程绝不会占用它。可一次性，也可按周重复。',
    onCancel: widget.onCancel,
    errorSummary: PlannerEditorErrorSummary(
      messages: [for (final message in _errors.values) message],
    ),
    actions: [
      FilledButton.icon(
        key: const Key('save-protected-time'),
        onPressed: _save,
        icon: const Icon(Icons.save_outlined),
        label: const Text('保存保护时间'),
      ),
    ],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('protected-title'),
          controller: _titleController,
          decoration: InputDecoration(
            labelText: '标题',
            errorText: _errors['title'],
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          // 规范 §9.2 把「备注」列为这一页的字段之一。
          key: const Key('protected-notes'),
          controller: _notesController,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '备注（可选）',
            hintText: '例如：这段时间用来吃饭，不安排任务',
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 200,
              child: PlannerDateField(
                key: const Key('protected-start-date'),
                boxKey: const Key('protected-start-date-box'),
                value: _range.startDate,
                label: '开始日期',
                errorText: _errors['time'],
                onChanged: _range.setStartDate,
              ),
            ),
            SizedBox(
              width: 150,
              child: PlannerTimeField(
                key: const Key('protected-start-time'),
                boxKey: const Key('protected-start-time-box'),
                value: _range.startTime,
                label: '开始时间',
                onChanged: _range.setStartTime,
              ),
            ),
            SizedBox(
              width: 200,
              child: PlannerDateField(
                key: const Key('protected-end-date'),
                boxKey: const Key('protected-end-date-box'),
                value: _range.endDate,
                label: '结束日期',
                onChanged: _range.setEndDate,
              ),
            ),
            SizedBox(
              width: 150,
              child: PlannerTimeField(
                key: const Key('protected-end-time'),
                boxKey: const Key('protected-end-time-box'),
                value: _range.endTime,
                label: '结束时间',
                onChanged: _range.setEndTime,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('protected-weekly'),
          contentPadding: EdgeInsets.zero,
          title: const Text('每周重复'),
          subtitle: const Text('例如每周二下午的两小时'),
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
                  key: Key('protected-weekday-$day'),
                  label: Text(_weekdayLabel(day)),
                  selected: _weekdays.contains(day),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _weekdays.add(day);
                      } else if (_weekdays.length > 1) {
                        // **至少留一天**：全不选会让重复规则没有可展开的日子，
                        // 保存出来的保护时间等于不存在。
                        _weekdays.remove(day);
                      }
                    });
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 250,
                child: PlannerDateField(
                  key: const Key('protected-recurrence-end-date'),
                  boxKey: const Key('protected-recurrence-end-date-box'),
                  value: _recurrenceEnd ?? _range.startDate,
                  label: '重复结束日期（可选）',
                  onChanged: (value) => setState(() => _recurrenceEnd = value),
                ),
              ),
              if (_recurrenceEnd != null)
                TextButton(
                  key: const Key('protected-recurrence-end-clear'),
                  onPressed: () => setState(() => _recurrenceEnd = null),
                  child: const Text('不设结束日期'),
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text(
          '时间按 ${widget.timeZoneId} 保存',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
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
