import 'package:flutter/material.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/application/recurring_progress_service.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';

import 'recurring_backfill_review_page.dart';
import 'recurring_history_list.dart';

/// 周期目标的详情页（路线图 §3.3、§11 Task 7 Step 3／5／6）。
///
/// 三块内容按用户真正要问的问题排序：
/// ① **这一周怎么样**——已完成 / 目标 / 还差多少，以及"本段多少分钟"；
/// ② **怎么改**——手动补记、跳过本周、暂停到某日、停止以后生成；
/// ③ **以前几周怎么样**——历史周次，并且**明确写出每种操作会影响哪些周**。
///
/// **"安排"与"完成"必须分开写**（§3.3 最后一条）：本页所有关于专注记录的数字都写"已完成"，
/// 排进日历的分钟在计划页里。把两者混成一个数，用户就再也分不清"排进了日历"与"真的做了"。
///
/// **导航与破坏性动作全部由路由注入**（与 `TaskEditorPage` 的 `onSaved` 同一条约定）：
/// 页面不认识路由，也不知道"删除"之后该去哪。
final class RecurringTaskDetailPage extends StatefulWidget {
  const RecurringTaskDetailPage({
    required this.service,
    required this.templateId,
    required this.nowUtc,
    this.onStartFocus,
    this.onEdit,
    this.onDelete,
    this.recurringProgress,
    this.recurringFragments,
    this.executionOutbox,
    super.key,
  });

  final RecurringTaskService service;
  final RecurringProgressService? recurringProgress;
  final DriftRecurringExecutionRepository? recurringFragments;
  final DriftExecutionRepository? executionOutbox;

  /// 模板 id。**页面自己按 id 读模板**，而不是由路由先读好再传进来：
  /// 暂停、归档、恢复都会改模板，而 `FutureBuilder` 的 future 不会自己重跑——
  /// 那样用户点完"暂停"之后，"当前暂停至…"那一行会继续显示旧值。
  final String templateId;

  /// 当前时刻（UTC）。周期、进度与"本段"都按它计算。
  final DateTime nowUtc;

  /// 开始专注。为 `null` 时不渲染该按钮——**不给死入口**。
  final void Function(String taskId)? onStartFocus;

  /// 编辑模板。为 `null` 时不渲染。
  final void Function(RecurringTaskTemplate template)? onEdit;

  /// 删除（连同本周记录）。为 `null` 时不渲染。
  final Future<void> Function(RecurringTaskTemplate template)? onDelete;

  @override
  State<RecurringTaskDetailPage> createState() =>
      _RecurringTaskDetailPageState();
}

final class _RecurringTaskDetailPageState
    extends State<RecurringTaskDetailPage> {
  RecurringTaskTemplate? _template;
  RecurringTaskCycle? _cycle;
  RecurringProgress? _progress;
  List<ExecutionFragment> _fragments = const [];
  List<RecurringHistoryEntry> _history = const [];
  int _segmentMinutes = 0;
  String? _failure;
  bool _loading = true;
  bool _busy = false;

  WeeklyPeriod get _period => widget.service.periodContaining(widget.nowUtc);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final template = await widget.service.repository.findTemplate(
        widget.templateId,
      );
      if (template == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _template = null;
          });
        }
        return;
      }
      final period = _period;
      final cycle = await widget.service.repository.findCycle(
        template.id,
        period.startLocalDate,
      );
      RecurringProgress? progress;
      var segment = 0;
      var fragments = const <ExecutionFragment>[];
      if (cycle != null) {
        progress = await widget.service.progressForCycle(
          template.id,
          period.startLocalDate,
        );
        final fragmentRepository = widget.recurringFragments;
        if (fragmentRepository != null) {
          final cycleId =
              '${template.id}:${formatLocalDate(period.startLocalDate)}';
          final snapshot = await fragmentRepository.findCycleSnapshot(cycleId);
          if (snapshot != null) {
            fragments = await fragmentRepository.fragmentsForCycle(cycleId);
          }
        }
        // "本段"＝本周最后记录的那一段。取"最后一段"而不是今天之和：用户问的是
        // "刚才这一段做了多少"，而"今天之和"会把早上那一段也算进来。
        final segments = await widget.service.repository
            .recordedSegmentsForTask(
              cycle.taskId,
              period.startUtc,
              period.endUtc,
            );
        segment = segments.isEmpty ? 0 : segments.last;
      }

      final cycles = await widget.service.repository.listCyclesForTemplate(
        template.id,
        limit: 12,
      );
      final history = <RecurringHistoryEntry>[];
      for (final item in cycles) {
        final itemPeriod = WeeklyPeriod.startingAt(
          item.periodStartLocalDate,
          widget.service.timeZoneId,
          widget.service.zones,
        );
        final recorded = await widget.service.repository.recordedMinutesForTask(
          item.taskId,
          itemPeriod.startUtc,
          itemPeriod.endUtc,
        );
        history.add(
          RecurringHistoryEntry(cycle: item, recordedMinutes: recorded),
        );
      }
      if (!mounted) return;
      setState(() {
        _template = template;
        _cycle = cycle;
        _progress = progress;
        _fragments = fragments;
        _segmentMinutes = segment;
        _history = history;
        _loading = false;
        _failure = null;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failure = '加载失败：$error';
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } on Object catch (error) {
      if (mounted) setState(() => _failure = '操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final template = _template;
    if (template == null) {
      return Center(
        key: const Key('recurring-detail-missing'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '这个周期目标不存在（可能已被删除）。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }
    final progress = _progress;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                template.title,
                key: const Key('recurring-detail-title'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              if (widget.executionOutbox != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('recurring-backfill-review'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RecurringBackfillReviewPage(
                          repository: widget.executionOutbox!,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('回填复核'),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                '每周目标 ${template.targetMinutes} 分钟'
                '${_paceLabel(template.pace)}'
                '${template.carryOverUnfinished ? '　·　结转未完成分钟' : '　·　不结转'}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              if (progress == null)
                Card(
                  key: const Key('recurring-detail-no-cycle'),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '这一周还没有生成周期实例。'
                      '${template.isPausedOn(_period.startLocalDate) ? '当前处于暂停期，暂停到期后会自动继续生成。' : '下次生成计划时会按模板创建。'}',
                    ),
                  ),
                )
              else
                _progressCard(context, template, progress),
              if (_fragments.isNotEmpty) ...[
                const SizedBox(height: 20),
                _fragmentsCard(context),
              ],
              const SizedBox(height: 20),
              _actionsCard(context, template),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '历史周次',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      const Text('最近的十二周，含本周。'),
                      const SizedBox(height: 12),
                      RecurringHistoryList(entries: _history),
                    ],
                  ),
                ),
              ),
              if (_failure != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _failure!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _fragmentTime(DateTime utc) {
    final local = widget.service.zones.toLocal(utc, widget.service.timeZoneId);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _completeFragment(ExecutionFragment fragment) async {
    final progress = widget.recurringProgress;
    if (progress == null || _busy) return;
    setState(() => _busy = true);
    try {
      final runtime = await progress.executionRepository.ensureRuntimeState();
      await progress.completeFragment(
        CompleteExecutionFragmentCommand(
          operationId:
              'fragment-complete:${fragment.fragmentId}:'
              '${DateTime.now().microsecondsSinceEpoch}',
          dataEpoch: runtime.dataEpoch,
          fragmentId: fragment.fragmentId,
          planVersionId: fragment.planVersionId,
          blockId: fragment.blockId,
          expectedFragmentRevision: fragment.revision,
          occurredAtUtc: widget.nowUtc,
        ),
      );
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _fragmentsCard(BuildContext context) => Card(
    key: const Key('recurring-detail-fragments'),
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('本周片段', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('每个可见块独立完成，不联动同周其他片段。'),
          const SizedBox(height: 8),
          for (final fragment in _fragments)
            ListTile(
              key: Key('recurring-fragment-${fragment.fragmentId}'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${_fragmentTime(fragment.plannedStartUtc)}–'
                '${_fragmentTime(fragment.plannedEndUtc)}',
              ),
              subtitle: Text(
                '${fragment.completedMicros ~/ 60000000}/'
                '${fragment.allocatedMicros ~/ 60000000} 分钟 · '
                '${fragment.state.name}',
              ),
              trailing:
                  fragment.state == ExecutionFragmentState.withdrawn ||
                      fragment.state == ExecutionFragmentState.superseded
                  ? const Text('已失效')
                  : fragment.state == ExecutionFragmentState.completed
                  ? const Icon(Icons.check_circle_outline)
                  : OutlinedButton(
                      key: Key(
                        'recurring-fragment-complete-${fragment.fragmentId}',
                      ),
                      onPressed: widget.recurringProgress == null || _busy
                          ? null
                          : () => _completeFragment(fragment),
                      child: const Text('完成本次'),
                    ),
            ),
        ],
      ),
    ),
  );

  Widget _progressCard(
    BuildContext context,
    RecurringTaskTemplate template,
    RecurringProgress progress,
  ) {
    final cycle = _cycle!;
    return Card(
      key: const Key('recurring-detail-progress'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('这一周', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(
              '本周已完成 ${progress.recordedMinutes}/${progress.targetMinutes} 分钟',
              key: const Key('recurring-detail-progress-label'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '本段 $_segmentMinutes 分钟',
              key: const Key('recurring-detail-segment-label'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            if (progress.remainingMinutes > 0)
              Text('本周还差 ${progress.remainingMinutes} 分钟，排程会继续安排。')
            else
              Text(
                progress.overTargetMinutes > 0
                    ? '已超出目标 ${progress.overTargetMinutes} 分钟，记录保留，本周不再安排。'
                    : '本周已达标。',
              ),
            if (cycle.carryInMinutes > 0) ...[
              const SizedBox(height: 8),
              Text('其中含上周结转 ${cycle.carryInMinutes} 分钟。'),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                if (widget.onStartFocus != null && !cycle.status.isSettled)
                  FilledButton.tonalIcon(
                    key: const Key('recurring-detail-start-focus'),
                    onPressed: _busy
                        ? null
                        : () => widget.onStartFocus!(cycle.taskId),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('开始专注'),
                  ),
                if (!cycle.status.isSettled)
                  OutlinedButton.icon(
                    key: const Key('recurring-detail-record-minutes'),
                    onPressed: _busy
                        ? null
                        : () => _promptManualMinutes(context, cycle),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('手动补记'),
                  ),
                // **达标即建议完成——但"未达标／已跳过"的周不给**：那会把"上周没做到"
                // 变成一句"现在补完吧"。状态为 `met` 时同样显示（点了只是再确认一次，
                // 服务那边幂等），因为**"里程碑达成"与"已经点了完成"是两件事**：
                // 用户可能刚补记到位，正需要这一步把这一周正式收尾。
                if (cycle.status != RecurringCycleStatus.missed &&
                    cycle.status != RecurringCycleStatus.skipped &&
                    progress.isMet)
                  OutlinedButton(
                    key: const Key('recurring-detail-complete'),
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await widget.service.completeCycle(
                              template.id,
                              cycle.periodStartLocalDate,
                            );
                          }),
                    child: const Text('建议完成本周'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionsCard(BuildContext context, RecurringTaskTemplate template) {
    final cycle = _cycle;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('管理', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('每项操作都写明它影响哪些周，避免改错范围。'),
            const SizedBox(height: 12),
            if (widget.onEdit != null)
              ListTile(
                key: const Key('recurring-detail-edit'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑模板'),
                subtitle: const Text('影响：从下周开始；本周实例保持原样。'),
                onTap: _busy ? null : () => widget.onEdit!(template),
              ),
            if (cycle != null &&
                cycle.status == RecurringCycleStatus.open &&
                template.status == RecurringTemplateStatus.active)
              ListTile(
                key: const Key('recurring-detail-pause'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.pause_circle_outline),
                title: const Text('暂停到某日'),
                subtitle: Text(
                  template.pausedUntilLocalDate == null
                      ? '影响：暂停期间不生成新周期；本周实例保留。到期自动恢复。'
                      : '当前暂停至 ${formatLocalDate(template.pausedUntilLocalDate!)}，到期自动恢复。',
                ),
                onTap: _busy ? null : () => _promptPause(context, template),
              ),
            if (cycle != null &&
                cycle.status != RecurringCycleStatus.skipped &&
                template.status == RecurringTemplateStatus.active)
              ListTile(
                key: const Key('recurring-detail-skip'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.skip_next_rounded),
                title: const Text('跳过本周'),
                subtitle: const Text('影响：仅这一周；模板与其他周不变。'),
                onTap: _busy
                    ? null
                    : () => _run(() async {
                        await widget.service.skipCycle(
                          template.id,
                          cycle.periodStartLocalDate,
                        );
                      }),
              ),
            if (template.status == RecurringTemplateStatus.active)
              ListTile(
                key: const Key('recurring-detail-stop'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.stop_circle_outlined),
                title: const Text('停止以后生成'),
                subtitle: const Text('影响：以后所有周；已生成的周与它们的记录保留。'),
                onTap: _busy
                    ? null
                    : () => _run(
                        () => widget.service.stopGenerating(template.id),
                      ),
              ),
            if (template.status == RecurringTemplateStatus.archived)
              ListTile(
                key: const Key('recurring-detail-resume'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('恢复生成'),
                subtitle: const Text('影响：从下一周开始重新生成周期。'),
                onTap: _busy
                    ? null
                    : () => _run(
                        () => widget.service.resumeGenerating(template.id),
                      ),
              ),
            if (widget.onDelete != null)
              ListTile(
                key: const Key('recurring-detail-delete'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除这个周期目标'),
                subtitle: const Text('影响：模板与本周记录一起删除；历史周次同时消失，且无法撤销。'),
                onTap: _busy ? null : () => _confirmDelete(context, template),
              ),
          ],
        ),
      ),
    );
  }

  /// 手动补记。
  ///
  /// **到达目标时不阻止补记**（超额记录是合法的，§3.3）；"未达标就点完成要二次确认"那条
  /// 要求落在别处——未达标时本页根本不显示"完成本周"，因此不存在"点一下就悄悄过了"的路径。
  ///
  /// **输入框的控制器交给一个独立的 `StatefulWidget`**：早先在这里 `controller.dispose()`
  /// 紧跟 `showDialog` 返回之后执行，而对话框还在播放关闭动画并重建那棵树，于是抛出
  /// `A TextEditingController was used after being disposed`——那条异常会把后面的刷新整段
  /// 打断，用户看到的现象是"补记了但页面没动"。
  Future<void> _promptManualMinutes(
    BuildContext context,
    RecurringTaskCycle cycle,
  ) async {
    final minutesFieldKey = GlobalKey<_MinutesFieldState>();
    final minutes = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('recurring-record-dialog'),
        title: const Text('手动补记分钟'),
        content: _MinutesField(key: minutesFieldKey),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('recurring-record-confirm'),
            onPressed: () => Navigator.of(dialogContext)
                .pop(int.tryParse(minutesFieldKey.currentState?.text ?? '')),
            child: const Text('记入本周'),
          ),
        ],
      ),
    );
    if (minutes == null || minutes <= 0) return;
    final localNow = widget.service.zones.toLocal(
      widget.nowUtc,
      widget.service.timeZoneId,
    );
    final today = DateTime(localNow.year, localNow.month, localNow.day);
    if (!context.mounted) return;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: today,
      firstDate: cycle.periodStartLocalDate,
      lastDate: today,
      helpText: '这次实际发生在哪一天？',
    );
    if (pickedDate == null) return;
    if (!mounted) return;
    await _run(() async {
      final progress = widget.recurringProgress;
      if (progress != null) {
        final end = pickedDate == today
            ? widget.nowUtc
            : widget.service.zones.localDateTimeToUtc(
                pickedDate,
                localNow.hour * 60 + localNow.minute,
                widget.service.timeZoneId,
              );
        final runtime = await progress.executionRepository.ensureRuntimeState();
        await progress.recordActivity(
          RecordRecurringActivityCommand(
            operationId:
                'recurring-manual:${cycle.taskId}:'
                '${DateTime.now().microsecondsSinceEpoch}',
            dataEpoch: runtime.dataEpoch,
            startUtc: end.subtract(Duration(minutes: minutes)),
            endUtc: end,
            occurredAtUtc: end,
          ),
        );
      } else {
        await widget.service.recordManualMinutes(
          widget.templateId,
          cycle.periodStartLocalDate,
          minutes,
        );
      }
    });
  }

  Future<void> _promptPause(
    BuildContext context,
    RecurringTaskTemplate template,
  ) async {
    final days = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        key: const Key('recurring-pause-dialog'),
        title: const Text('暂停多久'),
        children: [
          for (final (label, count) in const [
            ('一周', 7),
            ('两周', 14),
            ('一个月', 30),
          ])
            SimpleDialogOption(
              key: Key('recurring-pause-$count'),
              onPressed: () => Navigator.of(dialogContext).pop(count),
              child: Text(label),
            ),
          if (template.pausedUntilLocalDate != null)
            SimpleDialogOption(
              key: const Key('recurring-pause-clear'),
              onPressed: () => Navigator.of(dialogContext).pop(0),
              child: const Text('取消暂停'),
            ),
        ],
      ),
    );
    if (days == null) return;
    final today = widget.service.zones.toLocal(
      widget.nowUtc,
      widget.service.timeZoneId,
    );
    // `days == 0` 是"取消暂停"那一个选项；用 `null` 表达，而不是一个哨兵日期。
    final until = days == 0
        ? null
        : DateTime(today.year, today.month, today.day + days);
    await _run(() async {
      await widget.service.pauseTemplate(template.id, until: until);
    });
  }

  Future<void> _confirmDelete(
    BuildContext context,
    RecurringTaskTemplate template,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('recurring-delete-dialog'),
        title: const Text('删除这个周期目标？'),
        content: const Text('模板与本周的记录会一起删除，历史周次也会消失。这一步无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('recurring-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() => widget.onDelete!(template));
  }
}

String _paceLabel(RecurringPace pace) => switch (pace) {
  RecurringPace.even => '　·　均匀分布',
  RecurringPace.early => '　·　尽早完成',
  RecurringPace.deadlineWeighted => '　·　临近截止',
  RecurringPace.selectedWeekdays => '　·　仅指定星期',
};

/// 手动补记对话框里的分钟输入框。
///
/// **它单独成类是为了让控制器与输入框同生共死**：`TextEditingController` 必须在
/// **挂在树上的那段时间**有效，而对话框关闭时还会重建一次。详见调用点的说明。
final class _MinutesField extends StatefulWidget {
  const _MinutesField({super.key});

  @override
  State<_MinutesField> createState() => _MinutesFieldState();
}

final class _MinutesFieldState extends State<_MinutesField> {
  final _controller = TextEditingController();

  String get text => _controller.text.trim();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: const Key('recurring-record-minutes-field'),
    controller: _controller,
    autofocus: true,
    keyboardType: TextInputType.number,
    decoration: const InputDecoration(labelText: '分钟'),
  );
}
