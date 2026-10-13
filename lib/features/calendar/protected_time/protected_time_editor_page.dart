import 'package:flutter/material.dart';

import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_date_time_fields.dart';
import 'package:personal_planner/design/planner_editor_scaffold.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/protected_time_series.dart';

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
    this.editAnchorId,
    this.series,
    this.onUpdateSeries,
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

  /// 非空表示这一页处在**编辑模式**，值是要编辑的锚点事件 id。
  ///
  /// **为什么用"有没有 id"而不是一个布尔**：布尔与 id 分开传会出现
  /// `isEdit: true` 而 `anchorId: null` 这种自相矛盾的组合，而那样的组合在保存时
  /// 只能二选一：要么新建（丢掉用户的编辑），要么崩溃。让模式**由数据本身决定**，
  /// 这种组合在类型上就不存在。
  ///
  /// 为空 ⇒ 新建模式，标题是「新建保护时间」（Task 8 Step 1）。
  final String? editAnchorId;

  /// 编辑模式下要预填的**系列详情**（计划 Task 8 Step 1："所有字段从详情预填"）。
  ///
  /// **与 `editAnchorId` 一起传，但不是同一个东西**：id 回答"改哪一条"，
  /// 详情回答"这条现在长什么样"。只传 id 的编辑器只能显示空表单，
  /// 用户一保存就把整条规则覆盖成"保护时间 / 今天 / 1 小时"——那比不能编辑更糟。
  ///
  /// 为空时按键值兜底（[initialTitle]／[initialNotes]），这是日视图那条路径用的：
  /// 那里用户点的是**某一次**，已知的信息就是那一次本身。
  final ProtectedTimeSeries? series;

  /// 编辑模式下真正执行保存的回调；返回**用户可见的错误文案**，`null` 表示成功。
  ///
  /// **由调用方注入而不是编辑器自己调服务**：写哪几个字段、要做什么并发校验
  /// （`expectedUpdatedAtUtc`）是**用例**的职责，而编辑器只管收集输入。
  /// 这样"编辑器绝不生成新 id"这件事由结构保证：它手上根本没有 `save()` 这条路。
  final Future<String?> Function({
    required String title,
    required String notes,
    required DateTime startAtUtc,
    required DateTime endAtUtc,
    required bool weekly,
    required Set<int> weekdays,
    DateTime? recurrenceEnd,
  })?
  onUpdateSeries;

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
    // 默认给"今天 14:00–15:00"：一个 60 分钟的具体区间比空字段更容易改。
    final now = widget.zones.toLocal(DateTime.now().toUtc(), widget.timeZoneId);
    final today = DateTime(now.year, now.month, now.day);

    // **编辑模式从系列详情预填**（Task 8 Step 1）。逐字段的理由：
    // 少填一项，用户一保存就把它覆盖成默认值——而"默认值"在这里是"今天"。
    final series = widget.series;
    // **用规则的有效期起点当开始日期，而不是"今天"**：一条 10-06 开始、每周二重复的
    // 规则若显示成"今天开始"，用户看不出它原本从哪一周起生效，而保存时那个日期会被真的改掉。
    final localStartDate = series?.validFromLocalDate ?? today;
    final startTime = series == null
        ? const TimeOfDay(hour: 14, minute: 0)
        : TimeOfDay(
            hour: series.startMinute ~/ 60,
            minute: series.startMinute % 60,
          );
    final crossesMidnight =
        series != null && series.endMinute < series.startMinute;
    final endDate = series == null
        ? today
        : (crossesMidnight
              ? localStartDate.add(const Duration(days: 1))
              : localStartDate);
    final endTime = series == null
        ? const TimeOfDay(hour: 15, minute: 0)
        : TimeOfDay(
            hour: series.endMinute ~/ 60,
            minute: series.endMinute % 60,
          );

    _titleController = TextEditingController(
      text: series?.title ?? widget.initialTitle,
    );
    _notesController = TextEditingController(
      text: series?.notes ?? widget.initialNotes,
    );
    _range = LocalDateRangeController(
      startDate: localStartDate,
      startTime: startTime,
      endDate: endDate,
      endTime: endTime,
    )..addListener(_onRangeChanged);
    _weekly = series?.repeats ?? false;
    _weekdays = series != null && series.weekdays.isNotEmpty
        ? Set.of(series.weekdays)
        : {today.weekday};
    _recurrenceEnd = series?.validUntilLocalDate;
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

    final startUtc = widget.zones.localDateTimeToUtc(
      _range.startDate,
      _range.startTime.hour * 60 + _range.startTime.minute,
      widget.timeZoneId,
    );
    final endUtc = widget.zones.localDateTimeToUtc(
      _range.endDate,
      _range.endTime.hour * 60 + _range.endTime.minute,
      widget.timeZoneId,
    );

    // **编辑模式绝不能走 `save()`**（计划 Task 8 Step 1）：
    // `save()` 会生成一个新的 `CalendarEvent` 并落库，于是"改一次名字"变成"又建了一条"
    // ——管理页多一行、日历上多一串，而用户以为自己只是改了个名字。
    // 这正是本批次要修的缺陷（计划 §1.2）。
    final update = widget.onUpdateSeries;
    if (widget.editAnchorId != null && update != null) {
      final failure = await update(
        title: title,
        notes: _notesController.text.trim(),
        startAtUtc: startUtc,
        endAtUtc: endUtc,
        weekly: _weekly,
        weekdays: _weekdays,
        recurrenceEnd: _recurrenceEnd,
      );
      if (!mounted) return;
      if (failure case final message?) {
        setState(() => _errors = {'title': message});
        return;
      }
      widget.onSaved?.call();
      return;
    }

    final result = await widget.service.save(
      EventDraft(
        title: title,
        startAtUtc: startUtc,
        endAtUtc: endUtc,
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
    //
    // **两个模式的标题必须不同**（计划 Task 8 Step 1）：共用"新建保护时间"
    // 会让用户在改一条既有规则时以为自己在新建，从而不敢保存、或者保存后又建了一条
    // 重复的。
    title: widget.editAnchorId == null
        ? '新建保护时间'
        : '编辑「${widget.initialTitle}」',
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
