import 'package:flutter/material.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/settings/notifications/notification_preferences_section.dart';

final class PlanningRulesPage extends StatefulWidget {
  const PlanningRulesPage({
    required this.service,
    this.localDate,
    this.autoAdjustStore,
    super.key,
  });

  final SettingsService service;
  final DateTime? localDate;
  final AutoAdjustStore? autoAdjustStore;

  @override
  State<PlanningRulesPage> createState() => _PlanningRulesPageState();
}

final class _PlanningRulesPageState extends State<PlanningRulesPage> {
  final Map<String, TextEditingController> _controllers = {};
  final List<_EnergyDraft> _weekdayEnergy = [];
  final List<_EnergyDraft> _weekendEnergy = [];
  Map<String, String> _errors = const {};
  bool _loading = true;
  bool _saving = false;
  bool _trustAutoAdjust = false;
  bool _taskStartEnabled = true;
  bool _calendarStartEnabled = true;
  bool _deadlineEnabled = true;
  bool _conflictEnabled = true;
  final Map<ProtectedTimeKind, bool> _protectedEnabled = {
    for (final kind in ProtectedTimeKind.values) kind: false,
  };
  String? _status;

  /// **载入完成那一刻的快照**，用来判断"用户是不是改了东西还没保存"（M8，§12）。
  ///
  /// 为什么需要快照而不是一个 `_dirty` 布尔：这一页的 20 多个输入框在 `_load()` 里
  /// 被程序填入初值，而 `TextEditingController` 的分不清"程序填的"与"用户敲的"——
  /// 只看"有没有变过"会把载入本身当成一次编辑，于是**每次进这一页再返回都会弹确认框**，
  /// 那比不提示更烦人。
  ///
  /// 存"载入后的值"、再与"当前值"比较，才是用户视角的"我改过"。
  /// 比较的是**控件的文本**（而不是解析后的数字）：用户把 `50` 改成 `50 `（多个空格）
  /// 也算改过——他确实动了，而保存时会被重新解析。
  final Map<String, String> _loadedText = {};
  final Map<ProtectedTimeKind, bool> _loadedProtectedEnabled = {};
  bool? _loadedTrustAutoAdjust;
  bool? _loadedTaskStartEnabled;
  bool? _loadedCalendarStartEnabled;
  bool? _loadedDeadlineEnabled;
  bool? _loadedConflictEnabled;

  bool get _hasUnsavedChanges {
    // 还没载入完就退出：不算"有未保存的修改"（用户根本没看到内容）。
    if (_loading || _saving) return false;
    for (final entry in _controllers.entries) {
      if (_loadedText[entry.key] != entry.value.text) return true;
    }
    for (final kind in ProtectedTimeKind.values) {
      if (_loadedProtectedEnabled[kind] != _protectedEnabled[kind]) return true;
    }
    return _loadedTrustAutoAdjust != _trustAutoAdjust ||
        _loadedTaskStartEnabled != _taskStartEnabled ||
        _loadedCalendarStartEnabled != _calendarStartEnabled ||
        _loadedDeadlineEnabled != _deadlineEnabled ||
        _loadedConflictEnabled != _conflictEnabled;
  }

  TextEditingController _controller(String key) =>
      _controllers.putIfAbsent(key, () {
        final controller = TextEditingController();
        // **必须监听**（M8）。`PopScope` 的 `canPop` 是**构建时**算出来的一个值，
        // 而用户在输入框里打字只改 `TextEditingController` 的文本、**不会重建这一页**。
        // 没有这个监听，框架手里一直是"载入那一刻的 canPop = true"，
        // 于是返回时**直接放行**、`onPopInvokedWithResult` 收到的 `didPop` 也是 `true`
        // （实测过：dirty 明明为 true，`didPop` 仍然为 true，确认框根本不出现）。
        //
        // 这个坑很隐蔽：`_hasUnsavedChanges` 算得**完全正确**，错的只是"没人告诉框架它变了"。
        controller.addListener(_onFieldChanged);
        return controller;
      });

  /// 输入框内容变化时重建一次，好让 `PopScope` 拿到最新的 `canPop`。
  ///
  /// 不在这个回调里改任何状态：它只负责触发重建，判断仍然由 [_hasUnsavedChanges] 做。
  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final draft in [..._weekdayEnergy, ..._weekendEnergy]) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final anchor = widget.localDate ?? DateTime.now();
    final weekday = await widget.service.resolveForDate(_weekdayNear(anchor));
    final weekend = await widget.service.resolveForDate(_weekendNear(anchor));
    final rules = weekday.rules;
    _setRange('weekday-sleep', rules.sleepRange);
    _setRange('weekend-sleep', weekend.rules.sleepRange);
    _setInt('minimum-sleep-minutes', rules.minimumSleepMinutes);
    _setInt('default-focus-minutes', rules.defaultFocusMinutes);
    _setInt('break-minutes', rules.breakMinutes);
    _setInt('min-chunk-minutes', rules.minChunkMinutes);
    _setInt('max-chunk-minutes', rules.maxChunkMinutes);
    _setInt('weekday-daily-limit', rules.dailyMovableTaskLimitMinutes);
    _setInt('weekend-daily-limit', weekend.rules.dailyMovableTaskLimitMinutes);
    _setInt('weekly-life-quota', rules.weeklyLifeQuotaMinutes);
    _setProtectedTimes(rules.protectedTimes);
    _replaceEnergy(_weekdayEnergy, rules.energyWindows);
    _replaceEnergy(_weekendEnergy, weekend.rules.energyWindows);

    final notifications = weekday.notifications;
    _setInt('task-notification-lead', notifications.taskStartLeadMinutes);
    _setInt(
      'calendar-notification-lead',
      notifications.calendarStartLeadMinutes,
    );
    _setInt('deadline-notification-lead', notifications.deadlineLeadMinutes);
    _setRange('quiet-hours', notifications.quietHours);
    _trustAutoAdjust = weekday.trustAutoAdjust;
    _taskStartEnabled = notifications.taskStartEnabled;
    _calendarStartEnabled = notifications.calendarStartEnabled;
    _deadlineEnabled = notifications.deadlineEnabled;
    _conflictEnabled = notifications.conflictEnabled;
    widget.autoAdjustStore?.setEnabled(_trustAutoAdjust);
    // **载入完成后才拍快照**（M8）：此后任何差异都是用户改的。
    _snapshotLoadedValues();
    if (mounted) setState(() => _loading = false);
  }

  /// 记下"载入后的值"，供 [_hasUnsavedChanges] 比较。见那个 getter 上的说明。
  void _snapshotLoadedValues() {
    _loadedText
      ..clear()
      ..addEntries(
        _controllers.entries.map((e) => MapEntry(e.key, e.value.text)),
      );
    _loadedProtectedEnabled
      ..clear()
      ..addAll(_protectedEnabled);
    _loadedTrustAutoAdjust = _trustAutoAdjust;
    _loadedTaskStartEnabled = _taskStartEnabled;
    _loadedCalendarStartEnabled = _calendarStartEnabled;
    _loadedDeadlineEnabled = _deadlineEnabled;
    _loadedConflictEnabled = _conflictEnabled;
  }

  void _setInt(String key, int value) =>
      _controller(key).text = value.toString();

  void _setRange(String key, LocalTimeRange range) {
    _controller('$key-start').text = _formatTime(range.startMinute);
    _controller('$key-end').text = _formatTime(range.endMinute);
  }

  void _setProtectedTimes(List<ProtectedTimeRule> values) {
    for (final kind in ProtectedTimeKind.values) {
      final matches = values.where((item) => item.kind == kind);
      final item = matches.isEmpty ? null : matches.first;
      final fallback = switch (kind) {
        ProtectedTimeKind.lunch => (12 * 60, 13 * 60),
        ProtectedTimeKind.dinner => (18 * 60, 19 * 60),
        ProtectedTimeKind.fixedRest => (15 * 60, 15 * 60 + 20),
      };
      _setRange(
        'protected-${kind.name}',
        item?.range ??
            LocalTimeRange(startMinute: fallback.$1, endMinute: fallback.$2),
      );
      _controller('protected-${kind.name}-enabled').text = (item != null)
          .toString();
      _protectedEnabled[kind] = item != null;
    }
  }

  void _replaceEnergy(List<_EnergyDraft> target, List<EnergyWindow> values) {
    for (final draft in target) {
      draft.dispose();
    }
    target
      ..clear()
      ..addAll(values.map(_EnergyDraft.fromWindow));
  }

  Future<void> _save() async {
    final errors = <String, String>{};
    final weekdaySleep = _range('weekday-sleep', errors);
    final weekendSleep = _range('weekend-sleep', errors);
    final lunch = _protected(ProtectedTimeKind.lunch, errors);
    final dinner = _protected(ProtectedTimeKind.dinner, errors);
    final rest = _protected(ProtectedTimeKind.fixedRest, errors);
    final weekdayEnergy = _energyWindows(_weekdayEnergy, 'weekday', errors);
    final weekendEnergy = _energyWindows(_weekendEnergy, 'weekend', errors);

    final minimumSleep = _positive('minimum-sleep-minutes', errors);
    final focus = _positive('default-focus-minutes', errors);
    final breakMinutes = _nonNegative('break-minutes', errors);
    final minChunk = _positive('min-chunk-minutes', errors);
    final maxChunk = _positive('max-chunk-minutes', errors);
    final weekdayLimit = _dailyLimit('weekday-daily-limit', errors);
    final weekendLimit = _dailyLimit('weekend-daily-limit', errors);
    final lifeQuota = _nonNegative('weekly-life-quota', errors);
    final taskLead = _nonNegative('task-notification-lead', errors);
    final calendarLead = _nonNegative('calendar-notification-lead', errors);
    final deadlineLead = _nonNegative('deadline-notification-lead', errors);
    final quietHours = _range('quiet-hours', errors);
    if (minChunk != null && maxChunk != null && minChunk > maxChunk) {
      errors['max-chunk-minutes'] = '不能小于最短片段';
    }
    if (errors.isNotEmpty) {
      setState(() {
        _errors = errors;
        _status = null;
      });
      return;
    }

    setState(() => _saving = true);
    try {
      await widget.service.saveUserRules(
        UserPlanningRules(
          common: PlanningRulesPatch(
            protectedTimes: [?lunch, ?dinner, ?rest],
            minimumSleepMinutes: minimumSleep,
            defaultFocusMinutes: focus,
            breakMinutes: breakMinutes,
            minChunkMinutes: minChunk,
            maxChunkMinutes: maxChunk,
            weeklyLifeQuotaMinutes: lifeQuota,
          ),
          weekday: PlanningRulesPatch(
            sleepRange: weekdaySleep,
            energyWindows: weekdayEnergy,
            dailyMovableTaskLimitMinutes: weekdayLimit,
          ),
          weekend: PlanningRulesPatch(
            sleepRange: weekendSleep,
            energyWindows: weekendEnergy,
            dailyMovableTaskLimitMinutes: weekendLimit,
          ),
        ),
      );
      await widget.service.saveNotificationPreferences(
        NotificationPreferences(
          taskStartEnabled: _taskStartEnabled,
          taskStartLeadMinutes: taskLead!,
          calendarStartEnabled: _calendarStartEnabled,
          calendarStartLeadMinutes: calendarLead!,
          deadlineEnabled: _deadlineEnabled,
          deadlineLeadMinutes: deadlineLead!,
          conflictEnabled: _conflictEnabled,
          quietHours: quietHours,
        ),
      );
      await widget.service.setTrustAutoAdjust(_trustAutoAdjust);
      widget.autoAdjustStore?.setEnabled(_trustAutoAdjust);
      if (mounted) {
        setState(() {
          _errors = const {};
          _status = '设置已保存';
          // **存成功后重新拍快照**（M8）：改动已经落库，"未保存"的状态到此结束。
          // 不重拍的话，保存完再返回仍会弹"还有未保存的修改"——而那时根本没有未保存的东西，
          // 用户只能莫名其妙地点一次"放弃修改"。
          _snapshotLoadedValues();
        });
      }
    } on SettingsValidationException catch (error) {
      if (mounted) {
        setState(() {
          _errors = _mapServiceErrors(error.fieldErrors);
          _status = null;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    // **离开时确认未保存的修改**（M8，§12："所有子页面……也不静默丢弃未保存内容"）。
    //
    // 这一页此前**没有任何拦截**：改动只在点「保存」时落库，而返回、点侧边导航或关窗口
    // 都会**静默丢掉**刚才的编辑。§12 把"静默丢弃"单独列出来，正是因为这类丢失
    // 没有任何反馈——用户以为改好了，下次进来发现还是老值。
    //
    // 用 `PopScope` 而不是给每个入口加钩子：它同时覆盖系统返回、返回按钮、
    // 以及路由层发出的 pop。用户点「放弃修改」才真的丢，点「继续编辑」留在原页。
    return PopScope<Object?>(
      canPop: !_hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final discard = await _confirmDiscard();
        if (!mounted || !discard) return;
        if (context.mounted) Navigator.of(context).pop();
      },
      child: _body(context),
    );
  }

  /// 问一次"要不要放弃未保存的修改"。默认选**继续编辑**（不丢东西的那一侧）。
  Future<bool> _confirmDiscard() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('planning-rules-unsaved-dialog'),
        title: const Text('还有未保存的修改'),
        content: const Text('离开这一页会丢掉刚才的改动。'),
        actions: [
          TextButton(
            key: const Key('planning-rules-keep-editing'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            key: const Key('planning-rules-discard'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    // 点外面关掉对话框按"继续编辑"处理：中断的动作不该等于同意丢弃。
    return result ?? false;
  }

  Widget _body(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '规则与偏好',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text('这些默认值只是起点，不代表健康建议，可随时调整。'),
                const SizedBox(height: 20),
                _Section(
                  title: '作息与保护时间',
                  child: Column(
                    children: [
                      _rangeRow('工作日睡眠', 'weekday-sleep'),
                      _rangeRow('周末睡眠', 'weekend-sleep'),
                      _numberField('最低睡眠（分钟）', 'minimum-sleep-minutes'),
                      _protectedRangeRow('午餐保护', ProtectedTimeKind.lunch),
                      _protectedRangeRow('晚餐保护', ProtectedTimeKind.dinner),
                      _protectedRangeRow('固定休息', ProtectedTimeKind.fixedRest),
                    ],
                  ),
                ),
                _Section(
                  title: '精力区间',
                  subtitle: '可以有多个区间；未标记时段按中性处理。',
                  child: Column(
                    children: [
                      _EnergyEditor(
                        title: '工作日',
                        prefix: 'weekday',
                        drafts: _weekdayEnergy,
                        errorText: _errors['weekday-energy'],
                        onChanged: () => setState(() {}),
                      ),
                      const Divider(),
                      _EnergyEditor(
                        title: '周末',
                        prefix: 'weekend',
                        drafts: _weekendEnergy,
                        errorText: _errors['weekend-energy'],
                        onChanged: () => setState(() {}),
                      ),
                    ],
                  ),
                ),
                _Section(
                  title: '专注与任务片段',
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _numberField('默认专注（分钟）', 'default-focus-minutes'),
                      _numberField('片段间休息（分钟）', 'break-minutes'),
                      _numberField('最短片段（分钟）', 'min-chunk-minutes'),
                      _numberField('最长片段（分钟）', 'max-chunk-minutes'),
                    ],
                  ),
                ),
                _Section(
                  title: '每日上限与生活配额',
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _numberField('工作日可移动任务（分钟）', 'weekday-daily-limit'),
                      _numberField('周末可移动任务（分钟）', 'weekend-daily-limit'),
                      _numberField('每周生活娱乐配额（分钟）', 'weekly-life-quota'),
                    ],
                  ),
                ),
                _Section(
                  title: '通知与自动调整',
                  child: Column(
                    children: [
                      NotificationPreferencesSection(
                        taskLeadController: _controller(
                          'task-notification-lead',
                        ),
                        calendarLeadController: _controller(
                          'calendar-notification-lead',
                        ),
                        deadlineLeadController: _controller(
                          'deadline-notification-lead',
                        ),
                        quietStartController: _controller('quiet-hours-start'),
                        quietEndController: _controller('quiet-hours-end'),
                        taskStartEnabled: _taskStartEnabled,
                        calendarStartEnabled: _calendarStartEnabled,
                        deadlineEnabled: _deadlineEnabled,
                        conflictEnabled: _conflictEnabled,
                        onTaskStartChanged: (value) =>
                            setState(() => _taskStartEnabled = value),
                        onCalendarStartChanged: (value) =>
                            setState(() => _calendarStartEnabled = value),
                        onDeadlineChanged: (value) =>
                            setState(() => _deadlineEnabled = value),
                        onConflictChanged: (value) =>
                            setState(() => _conflictEnabled = value),
                        errors: _errors,
                      ),
                      SwitchListTile(
                        title: const Text('信任自动调整'),
                        subtitle: const Text('默认关闭；开启后仍会校验并保留调整历史。'),
                        value: _trustAutoAdjust,
                        onChanged: (value) =>
                            setState(() => _trustAutoAdjust = value),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_status != null) ...[
                  Text(_status!),
                  const SizedBox(width: 16),
                ],
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text('保存设置'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _rangeRow(String label, String key) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        SizedBox(width: 160, child: Text(label)),
        _timeField('$key-start', '开始'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('至'),
        ),
        _timeField('$key-end', '结束'),
      ],
    ),
  );

  Widget _protectedRangeRow(String label, ProtectedTimeKind kind) {
    final key = 'protected-${kind.name}';
    final enabled = _protectedEnabled[kind] ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          value: enabled,
          onChanged: (value) => setState(() => _protectedEnabled[kind] = value),
        ),
        if (enabled) _rangeRow('$label时段', key),
      ],
    );
  }

  Widget _timeField(String key, String label) => SizedBox(
    width: 130,
    child: TextField(
      key: Key(key),
      controller: _controller(key),
      decoration: InputDecoration(
        labelText: label,
        hintText: 'HH:mm',
        errorText: _errors[key.replaceFirst(RegExp(r'-(start|end)$'), '')],
      ),
    ),
  );

  Widget _numberField(String label, String key) => SizedBox(
    width: 250,
    child: TextField(
      key: Key(key),
      controller: _controller(key),
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, errorText: _errors[key]),
    ),
  );

  LocalTimeRange? _range(String key, Map<String, String> errors) {
    final start = _parseTime(_controller('$key-start').text);
    final end = _parseTime(_controller('$key-end').text);
    if (start == null || end == null) {
      errors[key] = '请使用 HH:mm 格式';
      return null;
    }
    if (start == end) {
      errors[key] = '开始和结束不能相同';
      return null;
    }
    return LocalTimeRange(startMinute: start, endMinute: end);
  }

  ProtectedTimeRule? _protected(
    ProtectedTimeKind kind,
    Map<String, String> errors,
  ) {
    final key = 'protected-${kind.name}';
    if (!(_protectedEnabled[kind] ?? false)) return null;
    final range = _range(key, errors);
    if (range == null) return null;
    return ProtectedTimeRule(kind: kind, range: range);
  }

  List<EnergyWindow>? _energyWindows(
    List<_EnergyDraft> drafts,
    String prefix,
    Map<String, String> errors,
  ) {
    final values = <EnergyWindow>[];
    for (var index = 0; index < drafts.length; index++) {
      final draft = drafts[index];
      final start = _parseTime(draft.start.text);
      final end = _parseTime(draft.end.text);
      if (start == null || end == null || start == end) {
        errors['$prefix-energy'] = '精力区间需要有效的开始和结束';
        return null;
      }
      values.add(
        EnergyWindow(
          range: LocalTimeRange(startMinute: start, endMinute: end),
          level: draft.level,
          dayKind: prefix == 'weekday' ? DayKind.weekday : DayKind.weekend,
        ),
      );
    }
    return values;
  }

  int? _positive(String key, Map<String, String> errors) {
    final value = int.tryParse(_controller(key).text.trim());
    if (value == null || value <= 0) {
      errors[key] = '必须大于 0';
      return null;
    }
    return value;
  }

  int? _nonNegative(String key, Map<String, String> errors) {
    final value = int.tryParse(_controller(key).text.trim());
    if (value == null || value < 0) {
      errors[key] = '不能小于 0';
      return null;
    }
    return value;
  }

  int? _dailyLimit(String key, Map<String, String> errors) {
    final value = _positive(key, errors);
    if (value != null && value > LocalTimeRange.minutesPerDay) {
      errors[key] = '不能超过 1440 分钟';
      return null;
    }
    return value;
  }
}

final class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

final class _EnergyEditor extends StatelessWidget {
  const _EnergyEditor({
    required this.title,
    required this.prefix,
    required this.drafts,
    required this.onChanged,
    this.errorText,
  });

  final String title;
  final String prefix;
  final List<_EnergyDraft> drafts;
  final VoidCallback onChanged;
  final String? errorText;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      for (var index = 0; index < drafts.length; index++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  key: Key('$prefix-energy-$index-start'),
                  controller: drafts[index].start,
                  decoration: const InputDecoration(labelText: '开始'),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 110,
                child: TextField(
                  key: Key('$prefix-energy-$index-end'),
                  controller: drafts[index].end,
                  decoration: const InputDecoration(labelText: '结束'),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<EnergyLevel>(
                value: drafts[index].level,
                onChanged: (value) {
                  if (value == null) return;
                  drafts[index].level = value;
                  onChanged();
                },
                items: const [
                  DropdownMenuItem(value: EnergyLevel.high, child: Text('高')),
                  DropdownMenuItem(value: EnergyLevel.medium, child: Text('中')),
                  DropdownMenuItem(value: EnergyLevel.low, child: Text('低')),
                ],
              ),
              IconButton(
                tooltip: '删除区间',
                onPressed: () {
                  drafts.removeAt(index).dispose();
                  onChanged();
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      if (errorText != null)
        Text(
          errorText!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () {
            drafts.add(_EnergyDraft.empty());
            onChanged();
          },
          icon: const Icon(Icons.add),
          label: const Text('添加精力区间'),
        ),
      ),
    ],
  );
}

final class _EnergyDraft {
  _EnergyDraft({
    required String start,
    required String end,
    required this.level,
  }) : start = TextEditingController(text: start),
       end = TextEditingController(text: end);

  factory _EnergyDraft.fromWindow(EnergyWindow window) => _EnergyDraft(
    start: _formatTime(window.range.startMinute),
    end: _formatTime(window.range.endMinute),
    level: window.level,
  );

  factory _EnergyDraft.empty() =>
      _EnergyDraft(start: '09:00', end: '10:00', level: EnergyLevel.medium);

  final TextEditingController start;
  final TextEditingController end;
  EnergyLevel level;

  void dispose() {
    start.dispose();
    end.dispose();
  }
}

int? _parseTime(String input) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(input.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}

String _formatTime(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:'
    '${(minute % 60).toString().padLeft(2, '0')}';

DateTime _weekdayNear(DateTime anchor) {
  var value = DateTime(anchor.year, anchor.month, anchor.day);
  while (value.weekday > DateTime.friday) {
    value = value.add(const Duration(days: 1));
  }
  return value;
}

DateTime _weekendNear(DateTime anchor) {
  var value = DateTime(anchor.year, anchor.month, anchor.day);
  while (value.weekday != DateTime.saturday) {
    value = value.add(const Duration(days: 1));
  }
  return value;
}

Map<String, String> _mapServiceErrors(Map<String, String> input) {
  final output = <String, String>{};
  for (final entry in input.entries) {
    output[switch (entry.key) {
          'minimumSleepMinutes' => 'minimum-sleep-minutes',
          'defaultFocusMinutes' => 'default-focus-minutes',
          'breakMinutes' => 'break-minutes',
          'minChunkMinutes' => 'min-chunk-minutes',
          'maxChunkMinutes' => 'max-chunk-minutes',
          'weeklyLifeQuotaMinutes' => 'weekly-life-quota',
          'dailyMovableTaskLimitMinutes' => 'weekday-daily-limit',
          'energyWindows' => 'weekday-energy',
          _ => entry.key,
        }] =
        entry.value;
  }
  return output;
}
