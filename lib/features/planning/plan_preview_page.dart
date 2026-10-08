import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';

/// 预览里的一条变更。
///
/// **五类分组**（M4，路线图 §8 原文：按"新增、移动、拆分、未安排、保护时间变化"分组）：
/// 第四类从原来的 `removed`（移除）改称 `unplanned`（未安排）。改名不是措辞洁癖——
/// "没排进去的任务"并没有被移除，它还在任务列表里，只是这一版计划装不下；
/// 写成"移除"会让用户以为自己的一项待办被删了。
///
/// **原时间与目标时间**：§8 要求"显示原时间、目标时间和原因"。只给原因，用户看不出
/// **从哪挪到哪**。两者都可空，因为三种情形天生只有一个方向：
/// · 新增只有目标时间；· 未安排只有原时间；· 移动两个都有。
/// 空的那一侧**不渲染**，而不是编一个占位文案。
enum PreviewChangeKind { added, moved, split, unplanned, protectedTimeChanged }

extension on PreviewChangeKind {
  String get label => switch (this) {
    PreviewChangeKind.added => '新增',
    PreviewChangeKind.moved => '移动',
    PreviewChangeKind.split => '拆分',
    PreviewChangeKind.unplanned => '未安排',
    PreviewChangeKind.protectedTimeChanged => '保护时间变化',
  };
}

final class PreviewChange {
  const PreviewChange({
    required this.kind,
    required this.title,
    required this.reason,
    this.fromLabel,
    this.toLabel,
  });
  final PreviewChangeKind kind;
  final String title;
  final String reason;

  /// 原时间（本地时间的人话写法）。新增类为 `null`。
  final String? fromLabel;

  /// 目标时间。未安排类为 `null`。
  final String? toLabel;
}

final class PlanPreviewModel {
  PlanPreviewModel({
    required this.proposalId,
    required List<PreviewChange> changes,
    required List<String> conflicts,
    required this.isStale,
  }) : changes = UnmodifiableListView(List.of(changes)),
       conflicts = UnmodifiableListView(List.of(conflicts));

  final String proposalId;
  final List<PreviewChange> changes;
  final List<String> conflicts;
  final bool isStale;
}

abstract interface class AutoAdjustStore {
  bool get enabled;
  void setEnabled(bool value);
  void recordPreview(PlanPreviewModel preview);
}

final class MemoryAutoAdjustStore implements AutoAdjustStore {
  bool _enabled = false;
  final List<String> history = [];

  @override
  bool get enabled => _enabled;

  @override
  void setEnabled(bool value) => _enabled = value;

  @override
  void recordPreview(PlanPreviewModel preview) =>
      history.add(preview.proposalId);
}

final class PlanPreviewPage extends StatefulWidget {
  const PlanPreviewPage({
    required this.model,
    required this.autoAdjustStore,
    required this.onConfirm,
    this.onUndoPlan,
    this.onRecalculate,
    super.key,
  });

  final PlanPreviewModel model;
  final AutoAdjustStore autoAdjustStore;
  final Future<void> Function() onConfirm;

  /// 撤销上一次已确认的计划（FR-REPLAN-08）。返回 `true` 表示确实撤销了。
  ///
  /// 为空时**不显示**该按钮：宁可没有，也不要一个点了不生效的图标。返回布尔而不是抛异常，
  /// 是因为"没有可撤销的计划"是一种正常状态，不是故障。
  final Future<bool> Function()? onUndoPlan;

  /// 重新生成一份提案（技术设计时序图里 `else stale` 分支的 `request recalculation`）。
  ///
  /// **这个回调补的是一处走不通的路径**：在它之前，过期时页面只显示
  /// 「该调整提案已失效，请重新生成计划」，而**确认按钮同时被禁用、卡片也没有点击行为**——
  /// 也就是说流程**要求**用户重新计算，界面上却没有任何可做这件事的地方（提案只存在内存里，
  /// 应用重启或重新生成后旧链接必然失效，因此这条路真的会走到）。
  ///
  /// 为空时同样**不显示**按钮（与 [onUndoPlan] 同一口径）：未装配排程服务时根本无法重新生成，
  /// 此时给一个点了没反应的按钮比不给更糟。
  final Future<void> Function()? onRecalculate;

  @override
  State<PlanPreviewPage> createState() => _PlanPreviewPageState();
}

final class _PlanPreviewPageState extends State<PlanPreviewPage> {
  late bool _autoAdjust;
  bool _applying = false;
  bool _recalculating = false;

  @override
  void initState() {
    super.initState();
    _autoAdjust = widget.autoAdjustStore.enabled;
  }

  Future<void> _recalculate() async {
    final recalculate = widget.onRecalculate;
    if (recalculate == null) return;
    setState(() => _recalculating = true);
    try {
      await recalculate();
    } finally {
      // 重新生成会导航到新提案的预览页，因此本 widget 通常已被卸载；仍然判断 mounted，
      // 否则"重新生成失败且留在原页"这一种结局会抛异常。
      if (mounted) setState(() => _recalculating = false);
    }
  }

  Future<void> _confirm() async {
    setState(() => _applying = true);
    widget.autoAdjustStore.recordPreview(widget.model);
    try {
      await widget.onConfirm();
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('调整预览')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.model.isStale)
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.refresh),
                        title: Text('提案已过期，请重新计算'),
                      ),
                      // 这段话此前**没有对应的动作**：确认按钮被禁用、卡片也不可点，于是界面
                      // 要求用户做一件它在任何地方都没提供的事。现在给出入口。
                      if (widget.onRecalculate != null)
                        FilledButton.icon(
                          key: const Key('recalculate-plan'),
                          onPressed: _recalculating ? null : _recalculate,
                          icon: _recalculating
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.autorenew),
                          label: const Text('重新生成计划'),
                        ),
                    ],
                  ),
                ),
              ),
            for (final kind in PreviewChangeKind.values)
              _ChangeGroup(
                kind: kind,
                changes: widget.model.changes
                    .where((change) => change.kind == kind)
                    .toList(),
              ),
            _ConflictGroup(conflicts: widget.model.conflicts),
            const Divider(height: 32),
            SwitchListTile(
              title: const Text('信任自动调整'),
              subtitle: const Text('开启后仍保存每次差异和解释历史'),
              value: _autoAdjust,
              onChanged: (value) {
                setState(() => _autoAdjust = value);
                widget.autoAdjustStore.setEnabled(value);
              },
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: widget.model.isStale || _applying ? null : _confirm,
              icon: _applying
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: const Text('确认应用'),
            ),
            // FR-REPLAN-08：撤销上一次已确认的计划。结果用 SnackBar 回报，因此这里不需要
            // 额外状态——"已撤销"与"无可撤销"是两种正常结局，都应由用户看见。
            if (widget.onUndoPlan != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('undo-plan'),
                onPressed: () async {
                  final undone = await widget.onUndoPlan!();
                  if (!context.mounted) return;
                  showPlannerMessage(
                    context,
                    message: undone ? '已撤销上一次计划' : '没有可撤销的已执行计划',
                  );
                },
                icon: const Icon(Icons.undo),
                label: const Text('撤销上一次计划'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _ChangeGroup extends StatelessWidget {
  const _ChangeGroup({required this.kind, required this.changes});
  final PreviewChangeKind kind;
  final List<PreviewChange> changes;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              kind.label,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (changes.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('无'),
            )
          else
            for (final change in changes)
              ExpansionTile(
                title: Text(change.title),
                children: [
                  // §8：显示**原时间与目标时间**。空的一侧不渲染——
                  // 新增没有原时间、未安排没有目标时间，硬编占位文案只会让人以为缺了数据。
                  if (change.fromLabel != null)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.schedule, size: 18),
                      title: Text('原时间　${change.fromLabel}'),
                    ),
                  if (change.toLabel != null)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.arrow_forward, size: 18),
                      title: Text('目标时间　${change.toLabel}'),
                    ),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.info_outline, size: 18),
                    title: Text(change.reason),
                  ),
                ],
              ),
        ],
      ),
    ),
  );
}

final class _ConflictGroup extends StatelessWidget {
  const _ConflictGroup({required this.conflicts});
  final List<String> conflicts;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('冲突', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (conflicts.isEmpty)
            const Text('无')
          else
            for (final conflict in conflicts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warning_amber),
                title: Text(conflict),
              ),
        ],
      ),
    ),
  );
}
