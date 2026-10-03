import 'package:flutter/material.dart';
import 'package:personal_planner/application/recovery_planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';

final class SpecialDayPage extends StatefulWidget {
  const SpecialDayPage({
    required this.recoveryDate,
    required this.rules,
    required this.fixedEvents,
    required this.onCreateOverride,
    required this.timeZoneId,
    this.onOpenPreview,
    super.key,
  });

  final DateTime recoveryDate;
  final PlanningRules rules;
  final List<CalendarOccurrence> fixedEvents;

  /// IANA 时区标识，用于把用户填写的"结束时间"解释为本地墙上时间。
  ///
  /// 该参数**必须显式传入**：此前它默认 `'Asia/Shanghai'`，任何忘记传的调用方都会
  /// 静默按东八区解释时间，而需求 §13 要求以本机当前时区保存和展示（R11）。组合根
  /// 在启动时解析本机时区并逐层传下来，这里改为必填，让"忘记传"变成编译错误而不是
  /// 一个只在别的时区才暴露的错误结果。
  final String timeZoneId;

  final Future<RecoveryPlan> Function(SpecialDayDraft draft) onCreateOverride;

  /// 生成方案后进入调整预览的入口。为空时不显示该按钮。
  ///
  /// 恢复方案本身只是一份提案：没有这一步，用户拿到 proposalId 却无处确认，恢复保护
  /// 就永远停在"已生成、未应用"。导航由路由器注入，页面不认识路由。
  final ValueChanged<String>? onOpenPreview;

  @override
  State<SpecialDayPage> createState() => _SpecialDayPageState();
}

final class _SpecialDayPageState extends State<SpecialDayPage> {
  final _endTime = TextEditingController(text: '01:00');
  final _acceptedSleep = TextEditingController(text: '360');
  RecoveryResolution _resolution = RecoveryResolution.scheduleRecoverySleep;
  RecoveryPlan? _result;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _endTime.dispose();
    _acceptedSleep.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final endMinute = _parseTime(_endTime.text);
    final accepted = int.tryParse(_acceptedSleep.text.trim());
    if (endMinute == null ||
        (_resolution == RecoveryResolution.acceptShorterSleep &&
            (accepted == null || accepted <= 0))) {
      setState(() => _error = '请填写有效的结束时间和睡眠时长');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final endUtc = TimeZoneDatabase().localDateTimeToUtc(
        widget.recoveryDate,
        endMinute,
        widget.timeZoneId,
      );
      final result = await widget.onCreateOverride(
        SpecialDayDraft(
          recoveryDate: widget.recoveryDate,
          actualEndUtc: endUtc,
          timeZoneId: widget.timeZoneId,
          rules: widget.rules,
          fixedEvents: widget.fixedEvents,
          resolution: _resolution,
          acceptedSleepMinutes:
              _resolution == RecoveryResolution.acceptShorterSleep
              ? accepted
              : null,
        ),
      );
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) setState(() => _error = '无法生成恢复方案，请检查输入');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('特殊日与恢复保护')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '晚归或加班后，程序会先保护恢复时间，再重新计算次日任务。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 220,
            child: TextField(
              key: const Key('actual-end-time'),
              controller: _endTime,
              decoration: const InputDecoration(
                labelText: '实际结束时间',
                hintText: 'HH:mm',
              ),
            ),
          ),
          const SizedBox(height: 20),
          for (final option in _options)
            _ResolutionCard(
              option: option,
              selected: _resolution == option.value,
              onTap: () => setState(() => _resolution = option.value),
            ),
          if (_resolution == RecoveryResolution.acceptShorterSleep)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: TextField(
                key: const Key('accepted-sleep-minutes'),
                controller: _acceptedSleep,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '本次接受的睡眠时长（分钟）',
                  helperText: '仅影响本次恢复，不会修改长期作息。',
                ),
              ),
            ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _saving ? null : _submit,
            icon: const Icon(Icons.bedtime_outlined),
            label: const Text('生成恢复方案'),
          ),
          if (_result != null) ...[
            const SizedBox(height: 20),
            const Card(
              child: ListTile(
                leading: Icon(Icons.shield_outlined),
                title: Text('恢复保护已用于本次方案'),
                subtitle: Text('仅作用于本次生成的计划，不会写入长期作息偏好。'),
              ),
            ),
            for (final conflict in _result!.conflicts)
              if (conflict.code == ConflictCode.minimumSleepConflict)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber),
                    title: Text('最低睡眠与不可移动${_conflictTitle(conflict)}冲突'),
                  ),
                ),
            for (final event in _result!.fixedEventsToKeep)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text('已保留：${event.title}'),
              ),
            if (widget.onOpenPreview != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('open-recovery-preview'),
                onPressed: () =>
                    widget.onOpenPreview!(_result!.proposalId),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('查看调整预览'),
              ),
            ],
          ],
        ],
      ),
    ),
  );

  String _conflictTitle(PlanningConflict conflict) {
    final explicit = conflict.details['title'];
    if (explicit is String && explicit.isNotEmpty) return explicit;
    for (final event in _result!.fixedEventsToKeep) {
      if (conflict.relatedEntityIds.contains(event.eventId)) return event.title;
    }
    return '日程';
  }
}

final class _ResolutionOption {
  const _ResolutionOption(this.value, this.title, this.impact);
  final RecoveryResolution value;
  final String title;
  final String impact;
}

const _options = [
  _ResolutionOption(
    RecoveryResolution.rescheduleMovableTasks,
    '重新安排可移动任务',
    '保留固定日程和睡眠，重算后续任务与截止风险。',
  ),
  _ResolutionOption(
    RecoveryResolution.cancelMovableTasks,
    '取消次日可移动任务',
    '释放次日任务时间，但可能增加之后的截止压力。',
  ),
  _ResolutionOption(
    RecoveryResolution.scheduleRecoverySleep,
    '安排补觉',
    '按常规最低睡眠时长保护恢复窗口。',
  ),
  _ResolutionOption(
    RecoveryResolution.acceptShorterSleep,
    '单次接受较短睡眠',
    '需要明确填写时长；不会修改长期作息。',
  ),
];

final class _ResolutionCard extends StatelessWidget {
  const _ResolutionCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _ResolutionOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    color: selected
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerLow,
    child: ListTile(
      onTap: onTap,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
      ),
      title: Text(option.title),
      subtitle: Text(option.impact),
    ),
  );
}

int? _parseTime(String input) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(input.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}
