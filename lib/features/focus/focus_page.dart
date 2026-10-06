import 'package:flutter/material.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';
import 'package:personal_planner/domain/models/interruption_reason.dart';
import 'package:personal_planner/features/focus/focus_recovery_dialog.dart';

/// 暂停对话框的结果：选中的原因（可为空＝跳过）。用一层包装是为了把"取消对话框"
/// （`null`，什么都不做）与"跳过原因"（`reason == null`，照样暂停）区分开——
/// 两者都返回 `null` 会让"取消"变成"暂停"。
final class _PauseChoice {
  const _PauseChoice(this.reason);
  final InterruptionReason? reason;
}

/// 问一次"为什么暂停"（FR-STAT-06 的"常见中断"按原因分类）。
///
/// 每个原因一个按钮而不是下拉＋确定：中断发生时要的是**一次点击**，而两步操作会让人干脆
/// 跳过。另给一个明确的"跳过"，见 `_pause` 的说明。
final class _InterruptionReasonDialog extends StatelessWidget {
  const _InterruptionReasonDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('这次是因为什么暂停？'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final reason in InterruptionReason.choices)
          ListTile(
            key: Key('pause-reason-${reason.name}'),
            title: Text(reason.label),
            contentPadding: EdgeInsets.zero,
            onTap: () => Navigator.of(context).pop(_PauseChoice(reason)),
          ),
      ],
    ),
    actions: [
      TextButton(
        key: const Key('pause-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      TextButton(
        key: const Key('pause-skip'),
        onPressed: () => Navigator.of(context).pop(const _PauseChoice(null)),
        child: const Text('跳过'),
      ),
    ],
  );
}

final class FocusPage extends StatefulWidget {
  const FocusPage({
    required this.service,
    required this.taskId,
    required this.taskTitle,
    this.plannedEndUtc,
    super.key,
  });

  final FocusService service;
  final String taskId;
  final String taskTitle;

  /// 该任务在**当前已确认计划**里的计划块终点（"待办时间段"的结束）。
  ///
  /// 为空表示**窗口未知**（没有已确认计划、该任务还没有块，或未装配计划仓储）——那时一律允许
  /// 接续且不做任何超时提示，因为**没有依据就别说超出了**。由路由侧的 `_FocusLoader` 查出后传入；
  /// 这一页因此不必认识计划仓储。
  final DateTime? plannedEndUtc;

  @override
  State<FocusPage> createState() => _FocusPageState();
}

final class _FocusPageState extends State<FocusPage> {
  FocusSession? _session;
  String? _error;

  @override
  void initState() {
    super.initState();
    _offerRecovery();
  }

  /// FR-FOCUS-02：程序异常退出时进行中的计时会留在存储里。进入专注页时应提示用户确认
  /// 实际结束时间（或选择不计入），而不是让它无声地停在"待确认"。
  ///
  /// 此前 `FocusRecoveryDialog` 全库无人引用、`recoverOpenEntry()` 也没有调用方，因此
  /// 异常退出的记录永远不会被处理（见 §13.0 的 W10）。这里不需要任何额外装配：本页
  /// 已经持有 `FocusService`。
  Future<void> _offerRecovery() async {
    final request = await widget.service.recoverOpenEntry();
    if (request == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => FocusRecoveryDialog(
        request: request,
        onConfirm: (value) async {
          // 两个回调都返回更新后的会话，必须写回 `_session`：否则用户已经回答了，
          // 界面还停在"待确认"。
          final session = await widget.service.confirmRecovery(
            endedAtUtc: value.endedAtUtc,
            actualMinutes: value.actualMinutes,
            note: value.note,
          );
          if (mounted) setState(() => _session = session);
        },
        onDiscard: () async {
          final session = await widget.service.discardRecovery();
          if (mounted) setState(() => _session = session);
        },
      ),
    );
  }

  int? _backfillMinutes;
  String? _backfillStatus;

  Future<void> _run(Future<FocusSession> Function() action) async {
    try {
      final session = await action();
      if (mounted) setState(() => _session = session);
    } on FocusTransitionException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  /// 暂停，并**先问清原因**（FR-STAT-06 的"常见中断"要按原因分类）。
  ///
  /// 允许"跳过"：原因是可以不填的，**跳过仍然照样暂停并照样记一次中断**（只是 code 用中性
  /// 标签）。若不给跳过，用户就只能在"随便编一个原因"和"不让计时停"之间选，两者都糟。
  ///
  /// **取舍**：先问再暂停，因此暂停时刻会晚一次对话交互。这是有意的——如果再发一条"补充
  /// 原因"的事件，同一次中断会在统计里出现两次；而时长本就按分钟级粒度记录，问清楚比抢那
  /// 几秒更重要（同一条理由也写在 `FocusService.pause` 上）。
  /// 继续接续专注（2026-10-04 的需求）。
  ///
  /// 需求：「中断后可以点击继续接续专注，**前提是还在待办时间段内**；如果**超出了待办时间段**
  /// 就要对剩余待办时间重新排序。」
  ///
  /// 三条实现上的取舍：
  /// - **超出时仍然让用户继续**：不拿"计划时段已过"去拦一个正在做事的人；超出只意味着**要重排**，
  ///   不意味着"不许做了"。重排由 `FocusService.onResumedBeyondPlan` 交给组合根（与"专注结束"
  ///   走同一条领域变化通道，因此会生成调整预览等用户确认，而不是悄悄改计划）。
  /// - **提示用与判定相同的那个函数**（`FocusService.canResumeWithinPlan`）：两处各写一份判断迟早
  ///   会不一致，而这里的不一致会直接表现为"提示说没超、实际超了"。
  /// - **计划窗口未知时不提示**：没有依据就别说超出了。
  Future<void> _resume() async {
    final beyond = !FocusService.canResumeWithinPlan(
      nowUtc: DateTime.now().toUtc(),
      plannedEndUtc: widget.plannedEndUtc,
    );
    await _run(
      () => widget.service.resume(plannedEndUtc: widget.plannedEndUtc),
    );
    if (!mounted || !beyond) return;
    showPlannerMessage(context, message: '已超出原计划时段，剩余待办时间将重新排程');
  }

  Future<void> _pause() async {
    final choice = await showDialog<_PauseChoice>(
      context: context,
      builder: (dialogContext) => const _InterruptionReasonDialog(),
    );
    if (choice == null) return;
    await _run(() => widget.service.pause(reason: choice.reason));
  }

  /// FR-FOCUS-04 的补录：用户确实专注了但没开计时器。
  ///
  /// 补录结果**不写 `_session`**：它是已结束的历史记录，写进去会让上面的"当前状态／已专注"
  /// 把一条历史显示成进行中。因此这里单独用一行状态文字回报结果。
  Future<void> _backfill() async {
    final minutes = _backfillMinutes;
    if (minutes == null || minutes <= 0) {
      setState(() => _backfillStatus = '请输入大于 0 的分钟数');
      return;
    }
    try {
      final session = await widget.service.recordCompleted(
        taskId: widget.taskId,
        minutes: minutes,
      );
      if (!mounted) return;
      setState(
        () =>
            _backfillStatus = '已补录 ${session.activeMinutes} 分钟（${session.id}）',
      );
    } on FocusTransitionException catch (error) {
      if (mounted) setState(() => _backfillStatus = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.taskTitle,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text('当前状态：${_session?.phase.name ?? '未开始'}'),
        Text('已专注：${_session?.activeMinutes ?? 0} 分钟'),
        if (_error != null) Text(_error!),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: () => _run(() => widget.service.start(widget.taskId)),
              child: const Text('开始'),
            ),
            OutlinedButton(
              key: const Key('focus-pause'),
              onPressed: _pause,
              child: const Text('暂停'),
            ),
            OutlinedButton(
              key: const Key('focus-resume'),
              onPressed: _resume,
              child: const Text('继续'),
            ),
            FilledButton.tonal(
              onPressed: () => _run(widget.service.finish),
              child: const Text('完成'),
            ),
          ],
        ),
        const Divider(height: 32),
        // FR-FOCUS-04 的补录：计时器没开，但确实专注过。补录以"已完成＋已确认"落库，
        // 因此和计时产生的记录一样进入统计与学习证据。
        Text('补录已完成的专注', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('backfill-minutes'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '分钟'),
                onChanged: (value) =>
                    _backfillMinutes = int.tryParse(value.trim()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('backfill-focus'),
              onPressed: _backfill,
              child: const Text('补录'),
            ),
          ],
        ),
        if (_backfillStatus != null) ...[
          const SizedBox(height: 8),
          Text(_backfillStatus!),
        ],
      ],
    ),
  );
}
