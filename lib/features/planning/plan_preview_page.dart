import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';
import 'package:personal_planner/domain/models/capacity_shortfall.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/repositories/task_title_lookup.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 预览里一个事项的可读名字（Task 12A Step 6）。
///
/// **它存在的唯一理由是不让裸 UUID 出现在用户眼前。** 排程引擎的输出以 id 为准（那是它的主键
/// 语言），而界面必须显示名字；`TaskDisplayInfo` 是这两者之间的那一层，由预览装配层用
/// [TaskTitleLookup] 填好。
final class TaskDisplayInfo {
  const TaskDisplayInfo({required this.taskId, required this.title});

  final String taskId;
  final String title;
}

/// 查不到标题时的兜底名。
///
/// **刻意不是空串、更不是 id**：空串在界面上是一片空白，用户不知道那里本该有字；id 是一串
/// UUID，对用户毫无意义。两者都比"未命名任务"更糟——后者至少说明"这里有一个任务，只是它的
/// 名字取不到"，用户仍能据缺口分钟数判断该怎么办。
const String unnamedTaskLabel = '未命名任务';

/// 为一批 id 解析可读名字。空的（或只有空白的）标题同样回落到 [unnamedTaskLabel]。
///
/// 单独抽成函数是为了能**脱离界面测试**：这几条回落规则是"绝不显示裸 UUID"的实际内容，
/// 而它们在 widget 测试里很难穷举（要分别构造查不到、空标题、空白标题三种数据）。
Future<List<TaskDisplayInfo>> resolveTaskDisplayInfos(
  TaskTitleLookup lookup,
  Iterable<String> taskIds,
) async {
  final ids = taskIds.toSet().toList();
  if (ids.isEmpty) return const [];
  final titles = await lookup.titlesFor(ids);
  return [
    for (final id in ids)
      TaskDisplayInfo(
        taskId: id,
        title: (titles[id]?.trim().isNotEmpty ?? false)
            ? titles[id]!.trim()
            : unnamedTaskLabel,
      ),
  ];
}

/// 把引擎给出的结构化原因翻译成一句用户能据以行动的话（Task 12A Step 6 第 5 条）。
///
/// **这里只翻译，不判断。** 归因由引擎负责（`UnscheduledReasonCode`），本函数不得据任务属性
/// 反过来猜原因——那正是这一步要消灭的东西。因此这个函数的签名收的是 [UnscheduledReason]，
/// 而不是任务或提案。
///
/// 有 `requiredMinutes` / `availableMinutes` 的原因尽量把两个数写进句子里：用户据此才知道
/// "差多少"，而这决定了他是该调目标还是改截止时间。
String unscheduledReasonLabel(UnscheduledReason reason) =>
    switch (reason.code) {
      UnscheduledReasonCode.availableTimeNotReached =>
        reason.constraintLabel == null
            ? '还没到这件事可以开始的时间。'
            : '还没到这件事可以开始的时间（${reason.constraintLabel}）。',
      UnscheduledReasonCode.deadlineWindowTooShort => _withNumbers(
        '截止时间之前装不下一个片段',
        required: reason.requiredMinutes,
        available: reason.availableMinutes,
        tail: '。',
      ),
      UnscheduledReasonCode.continuousGapTooShort => _withNumbers(
        '这件事需要一次做完',
        required: reason.requiredMinutes,
        available: reason.availableMinutes,
        tail: '，但最长的一段空档不够长。',
      ),
      UnscheduledReasonCode.minimumChunkTooLarge => _withNumbers(
        '剩下的时间不够一个最短片段',
        required: reason.requiredMinutes,
        available: reason.availableMinutes,
        tail: '。',
      ),
      UnscheduledReasonCode.dailyLimitReached => '已经达到这一天能安排的上限，剩下的时间排不进去了。',
      UnscheduledReasonCode.protectedTimeOccupied => '保护时间占住了这些时段，引擎不会挤占它。',
      UnscheduledReasonCode.fixedScheduleOccupied => '固定日程占住了这些时段。',
      UnscheduledReasonCode.lockedPlanOccupied =>
        reason.constraintLabel == null
            ? '这些时段已经被别的计划块占住了。'
            : '这些时段已经被${reason.constraintLabel}占住了。',
      UnscheduledReasonCode.requiredBreakUnavailable =>
        '排满就没有片段之间的休息时间，因此没有排进去。',
      UnscheduledReasonCode.insufficientCapacity => _withNumbers(
        '可用时间不足',
        required: reason.requiredMinutes,
        available: reason.availableMinutes,
        tail: '。',
      ),
    };

String _withNumbers(
  String lead, {
  required int? required,
  required int? available,
  required String tail,
}) {
  if (required != null && available != null) {
    return '$lead：需要 $required 分钟，可用 $available 分钟$tail';
  }
  if (required != null) return '$lead：需要 $required 分钟$tail';
  return '$lead$tail';
}

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

enum ShortfallAction {
  /// 调低本周目标到"能安排的量"。
  lowerTarget,

  /// 放宽期望时段（去掉模板上的期望时段）。
  relaxPreferredWindow,

  /// 临时放宽每日上限（只影响今天，不写设置）。
  relaxDailyLimit,

  /// 允许本周不完全安排（本周就这样，不再自动重排）。
  allowPartialWeek,
}

final class PlanPreviewModel {
  PlanPreviewModel({
    required this.proposalId,
    required List<PreviewChange> changes,
    required List<String> conflicts,
    required this.isStale,
    List<CapacityShortfall> shortfalls = const [],
  }) : changes = UnmodifiableListView(List.of(changes)),
       conflicts = UnmodifiableListView(List.of(conflicts)),
       shortfalls = UnmodifiableListView(List.of(shortfalls));

  final String proposalId;
  final List<PreviewChange> changes;
  final List<String> conflicts;
  final bool isStale;

  /// 周期目标的容量缺口（M6，§3.4）。为空时那一组卡片不渲染。
  final List<CapacityShortfall> shortfalls;
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
    this.onHandleShortfall,
    super.key,
  });

  final PlanPreviewModel model;
  final AutoAdjustStore autoAdjustStore;
  final Future<void> Function() onConfirm;

  /// 处理一条容量缺口（M6，§3.4）。
  ///
  /// **页面只负责把用户的意图报出去**：真正的落点（改模板、去设置、重新生成计划）属于
  /// 装配层。为 `null` 时**四个动作都不渲染**——当排程或周期服务没有装配时，给出一个
  /// 点了没反应的按钮比不给更糟（与 [onUndoPlan] 同一条约定）。
  final Future<void> Function(
    CapacityShortfall shortfall,
    ShortfallAction action,
  )?
  onHandleShortfall;

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
            if (widget.model.shortfalls.isNotEmpty)
              _ShortfallGroup(
                shortfalls: widget.model.shortfalls,
                onHandle: widget.onHandleShortfall,
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

/// 容量缺口卡片（M6，路线图 §3.4）。
///
/// **为什么必须单独成组而不是塞进"冲突"里**：冲突说的是"计划内部有矛盾"，而缺口说的是
/// "这一周的目标排不下"。两者的处置完全不同——冲突要用户挑一个让步，缺口要用户在四个
/// 动作里选一个（调低目标／放宽期望时段／临时放宽每日上限／允许本周不完全安排）。
///
/// 文案把**目标、可安排、缺口**三个数字都写出来：只说"排不下"用户没法决定该改多少。
final class _ShortfallGroup extends StatefulWidget {
  const _ShortfallGroup({required this.shortfalls, required this.onHandle});

  final List<CapacityShortfall> shortfalls;
  final Future<void> Function(
    CapacityShortfall shortfall,
    ShortfallAction action,
  )?
  onHandle;

  @override
  State<_ShortfallGroup> createState() => _ShortfallGroupState();
}

final class _ShortfallGroupState extends State<_ShortfallGroup> {
  String? _busyTemplateId;

  Future<void> _run(CapacityShortfall shortfall, ShortfallAction action) async {
    final handle = widget.onHandle;
    if (handle == null) return;
    setState(() => _busyTemplateId = shortfall.templateId);
    try {
      await handle(shortfall, action);
    } finally {
      if (mounted) setState(() => _busyTemplateId = null);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('shortfall-group'),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('容量不足', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final shortfall in widget.shortfalls)
            Padding(
              key: Key('shortfall-${shortfall.templateId}'),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(shortfall.message),
                  if (shortfall.protectedConstraint != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '保护时间不动；缺口是在「${_protectedLabel(shortfall.protectedConstraint!)}」'
                        '等保护时段之外算出来的。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (widget.onHandle != null) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          key: Key('shortfall-lower-${shortfall.templateId}'),
                          onPressed: _busyTemplateId != null
                              ? null
                              : () => _run(
                                  shortfall,
                                  ShortfallAction.lowerTarget,
                                ),
                          child: Text(
                            '调低本周目标到 ${shortfall.schedulableMinutes} 分钟',
                          ),
                        ),
                        OutlinedButton(
                          key: Key('shortfall-relax-${shortfall.templateId}'),
                          onPressed: _busyTemplateId != null
                              ? null
                              : () => _run(
                                  shortfall,
                                  ShortfallAction.relaxPreferredWindow,
                                ),
                          child: const Text('放宽期望时段'),
                        ),
                        OutlinedButton(
                          key: Key('shortfall-daily-${shortfall.templateId}'),
                          onPressed: _busyTemplateId != null
                              ? null
                              : () => _run(
                                  shortfall,
                                  ShortfallAction.relaxDailyLimit,
                                ),
                          child: const Text('临时放宽每日上限'),
                        ),
                        OutlinedButton(
                          key: Key('shortfall-partial-${shortfall.templateId}'),
                          onPressed: _busyTemplateId == null
                              ? () => _run(
                                  shortfall,
                                  ShortfallAction.allowPartialWeek,
                                )
                              : null,
                          child: const Text('允许本周不完全安排'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

String _protectedLabel(ProtectedTimeKind kind) => switch (kind) {
  ProtectedTimeKind.lunch => '午餐',
  ProtectedTimeKind.dinner => '晚餐',
  ProtectedTimeKind.fixedRest => '固定休息',
};

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
