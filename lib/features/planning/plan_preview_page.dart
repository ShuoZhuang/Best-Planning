import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';
import 'package:personal_planner/domain/models/capacity_shortfall.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_title_lookup.dart';
import 'package:personal_planner/features/planning/plan_preview_issues.dart';
import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/proposal_disposition.dart';
// `unnamedTaskLabel` 由 `plan_preview_issues.dart` 转发（同一个概念只有一个名字），
// 因此这里不再单独 import `preview_failure_lines.dart`——那会变成两处来源。
export 'package:personal_planner/features/planning/plan_preview_issues.dart'
    show PreviewIssue, PreviewIssueSeverity, buildPreviewIssues;
export 'package:personal_planner/scheduling/explanations.dart'
    show unscheduledReasonLabel;
export 'package:personal_planner/scheduling/preview_failure_lines.dart'
    show PreviewFailureLine, formatFailureLine, previewFailureLines;
export 'package:personal_planner/scheduling/preview_failure_lines.dart'
    show unnamedTaskLabel;

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
///
/// **定义只有一处**（`scheduling/preview_failure_lines.dart`），本文件在上方 `export` 转发。

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
    required List<PreviewIssue> issues,
    required this.isStale,
    List<CapacityShortfall> shortfalls = const [],
  }) : changes = UnmodifiableListView(List.of(changes)),
       issues = UnmodifiableListView(List.of(issues)),
       shortfalls = UnmodifiableListView(List.of(shortfalls));

  final String proposalId;
  final List<PreviewChange> changes;

  /// 结构化问题（1.8.0，冻结决策 §1.6）。
  ///
  /// **不得同时保留 `List<String> conflicts` 作为第二事实源**：两个列表一旦并存，
  /// 迟早会出现"一处有、另一处没有"，而用户看到的是两套互相矛盾的说法（R7）。
  final List<PreviewIssue> issues;
  final bool isStale;

  /// 周期目标的容量缺口（M6，§3.4）。为空时那一组卡片不渲染。
  final List<CapacityShortfall> shortfalls;

  bool get hasBlockingIssues => issues.any((issue) => issue.isBlocking);
  bool get hasWarnings => issues.any((issue) => !issue.isBlocking);

  /// 由问题列表派生的处置状态（与引擎的 `classifyProposal` 同一条规则）。
  ///
  /// **stale 不在这里**：过期是"这份提案已经作废"，与三态正交，
  /// 且它的优先级高于三态（冻结决策 §1.6 的最后一行）。
  ProposalDisposition get disposition {
    if (hasBlockingIssues) return ProposalDisposition.blocked;
    if (issues.isNotEmpty) {
      return ProposalDisposition.partialRequiresConfirmation;
    }
    return ProposalDisposition.fullyApplicable;
  }
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

  /// 确认应用。**入参是授权范围，返回是应用结果**（1.8.0，冻结决策 §1.6）。
  ///
  /// 修复前它是无参 `Future<void>`，于是页面**只能**触发应用、拿不到结果，
  /// 结果处理（导航、错误面板、重试状态）散在路由里，且失败后只弹一句
  /// "计划未通过校验，未应用"——用户既不知道是哪一件事，也没法采取动作。
  ///
  /// 页面只在这两个值里挑一个：
  /// - [PlanApplyMode.completeOnly]：完整可行的提案；
  /// - [PlanApplyMode.allowPartial]：用户在二次确认框里点了"仍然应用"。
  ///
  /// **它不直接访问仓储**：结果由页面交给同一套渲染逻辑（问题卡片 + SnackBar），
  /// 因此"失败之后还能无限重复点击同一个必失败操作"这件事在页面层就能被挡住。
  final Future<ApplyPlanResult> Function(PlanApplyMode mode) onConfirm;

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

  /// 上一次应用失败的**具体原因**（为空表示没有失败过）。
  ///
  /// 存在的理由（冻结决策 §1.6 的最后一行）：应用阶段若发现新的阻断错误，
  /// 要显示具体任务与原因，并且**按钮不得允许无限重复点击同一个必失败操作**。
  /// 失败之后页面转入"先修问题"的状态：主按钮禁用，只留"重新生成计划"。
  List<PreviewIssue> _applyFailures = const [];

  @override
  void initState() {
    super.initState();
    _autoAdjust = widget.autoAdjustStore.enabled;
  }

  /// 主按钮当前是否可用。
  ///
  /// **四种情况都不可用**：过期、正在应用、模型本身含阻断问题、上一次应用刚刚失败。
  bool get _canApply =>
      !widget.model.isStale &&
      !_applying &&
      !widget.model.hasBlockingIssues &&
      _applyFailures.isEmpty;

  bool get _canApplyPartial =>
      !widget.model.isStale &&
      !_applying &&
      !widget.model.hasBlockingIssues &&
      _applyFailures.isEmpty &&
      widget.model.disposition ==
          ProposalDisposition.partialRequiresConfirmation;

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
    final disposition = widget.model.disposition;
    if (disposition == ProposalDisposition.blocked) return;
    var mode = PlanApplyMode.completeOnly;
    if (disposition == ProposalDisposition.partialRequiresConfirmation) {
      // **二次确认**：用户必须看到全部缺口，并明确选择"仍然应用"。
      final confirmed = await _askPartialConfirmation();
      if (confirmed != true) return;
      mode = PlanApplyMode.allowPartial;
    }
    if (!mounted) return;
    setState(() => _applying = true);
    widget.autoAdjustStore.recordPreview(widget.model);
    try {
      final result = await widget.onConfirm(mode);
      if (!mounted) return;
      setState(() => _applyFailures = _issuesOf(result));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  /// 把应用结果翻成页面能显示的问题列表。
  List<PreviewIssue> _issuesOf(ApplyPlanResult result) {
    if (result.status == ApplyPlanStatus.applied ||
        result.status == ApplyPlanStatus.staleProposal) {
      return const [];
    }
    final titles = {
      for (final issue in widget.model.issues) issue.key: issue.title,
    };
    return [
      for (var index = 0; index < result.conflicts.length; index++)
        PreviewIssue(
          key: 'apply-failure:${result.conflicts[index].code.name}:$index',
          severity: PreviewIssueSeverity.blocking,
          title:
              titles['conflict:$index:${result.conflicts[index].code.name}'] ??
              conflictLabel(result.conflicts[index].code),
          message: planningConflictMessage(
            result.conflicts[index],
            taskTitle: result.conflicts[index].taskId == null
                ? unnamedTaskLabel
                : titleOfTask(result.conflicts[index].taskId!, titles),
          ),
        ),
    ];
  }

  Future<bool?> _askPartialConfirmation() => showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('仍有事项没有排进去'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('下面的部分可以安排，其余的这次不会排进去：'),
            const SizedBox(height: 8),
            // **列出全部缺口**（标题、缺口分钟、结构化主原因），
            // 因为用户是在为"就这样应用"负责。
            for (final issue in widget.model.issues.where(
              (issue) => !issue.isBlocking,
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(issue.title),
                    Text(
                      issue.message,
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('仍然应用'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    // **只渲染非空分组**（冻结决策 §1.6 的最后一条）：五类各来一张"无"卡片
    // 会把真正的问题挤到屏幕外。全部为空时给一句"没有计划时间变更"。
    final groups = [
      for (final kind in PreviewChangeKind.values)
        (
          kind: kind,
          changes: model.changes
              .where((change) => change.kind == kind)
              .toList(),
        ),
    ].where((group) => group.changes.isNotEmpty).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('调整预览')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (model.isStale)
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
            for (final group in groups)
              _ChangeGroup(kind: group.kind, changes: group.changes),
            if (groups.isEmpty && model.issues.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('没有计划时间变更'),
                ),
              ),
            if (model.shortfalls.isNotEmpty)
              _ShortfallGroup(
                shortfalls: model.shortfalls,
                onHandle: widget.onHandleShortfall,
              ),
            if (model.issues.isNotEmpty) _IssueGroup(issues: model.issues),
            if (_applyFailures.isNotEmpty)
              _IssueGroup(
                key: const Key('apply-failure-group'),
                title: '应用未完成',
                issues: _applyFailures,
              ),
            const Divider(height: 32),
            SwitchListTile(
              title: const Text('信任自动调整'),
              subtitle: Text(
                // **开关代表未来偏好，不改变当前这份提案的走向**（冻结决策 §1.6）：
                // 阻断或部分提案不会被自动应用，副标题必须说清楚，
                // 否则用户会以为"打开开关就能让它落地"。
                _canApply || _canApplyPartial
                    ? '开启后仍保存每次差异和解释历史'
                    : '当前方案不会自动应用；开关只影响之后的生成',
              ),
              value: _autoAdjust,
              onChanged: (value) {
                setState(() => _autoAdjust = value);
                widget.autoAdjustStore.setEnabled(value);
              },
            ),
            const SizedBox(height: 12),
            _ConfirmButton(
              model: model,
              applying: _applying,
              failed: _applyFailures.isNotEmpty,
              canApply: _canApply,
              canApplyPartial: _canApplyPartial,
              onPressed: _confirm,
              onRecalculate: widget.onRecalculate == null ? null : _recalculate,
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
  ProtectedTimeKind.breakfast => '早餐',
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

/// 主操作按钮（冻结决策 §1.6 的三态表）。
///
/// | 状态 | 文案 | 行为 |
/// | --- | --- | --- |
/// | fullyApplicable | 确认应用 | 直接校验并应用 |
/// | partialRequiresConfirmation | 应用可安排部分 | 先弹确认框，确认后传 `allowPartial` |
/// | blocked | 无法应用（禁用） | 不调用应用服务；若装配了重算则给"重新生成计划" |
/// | stale | 无法应用（禁用） | 只允许重新生成 |
/// | 刚刚失败过 | 无法应用（禁用） | 只允许重新生成（见 `failed`） |
///
/// **阻断与 stale 都不能被绕过**：它们走的是 `onPressed == null`，
/// 因此键盘、语义动作与程序化点击都点不动。
final class _ConfirmButton extends StatelessWidget {
  const _ConfirmButton({
    required this.model,
    required this.applying,
    required this.failed,
    required this.canApply,
    required this.canApplyPartial,
    required this.onPressed,
    required this.onRecalculate,
  });

  final PlanPreviewModel model;
  final bool applying;
  final bool failed;
  final bool canApply;
  final bool canApplyPartial;
  final Future<void> Function() onPressed;
  final Future<void> Function()? onRecalculate;

  @override
  Widget build(BuildContext context) {
    final disposition = model.disposition;
    // 文案：三态 + stale + 失败后。
    final String label;
    if (model.isStale) {
      label = '无法应用';
    } else if (failed) {
      label = '无法应用';
    } else if (disposition == ProposalDisposition.blocked) {
      label = '无法应用';
    } else if (canApplyPartial) {
      label = '应用可安排部分';
    } else {
      label = '确认应用';
    }
    final enabled = canApply || canApplyPartial;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: enabled && !applying ? onPressed : null,
          icon: applying
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(enabled ? Icons.check : Icons.block),
          label: Text(label),
        ),
        // 阻断/stale/失败时给一条"能做什么"的出路，而不是把用户留在死路上。
        if (!enabled && !applying && onRecalculate != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('recalculate-after-block'),
            onPressed: onRecalculate,
            icon: const Icon(Icons.autorenew),
            label: const Text('重新生成计划'),
          ),
        ],
      ],
    );
  }
}

/// 问题卡片组：warning 与 blocking **用不同图标、标题和颜色**，
/// 但**不得仅靠颜色区分**（冻结决策 §1.6 的最后一条），因此图标与文字同时不同。
final class _IssueGroup extends StatelessWidget {
  const _IssueGroup({required this.issues, this.title, super.key});

  final List<PreviewIssue> issues;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocking = issues.where((issue) => issue.isBlocking).toList();
    final warnings = issues.where((issue) => !issue.isBlocking).toList();

    Widget tile(PreviewIssue issue) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        issue.isBlocking ? Icons.error_outline : Icons.info_outline,
        color: issue.isBlocking ? scheme.error : scheme.tertiary,
      ),
      title: Text(issue.title),
      subtitle: Text(issue.message),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title ?? (blocking.isEmpty ? '需要注意' : '无法应用的问题'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (blocking.isNotEmpty) ...[
              Text(
                '阻断问题（必须先解决）',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              for (final issue in blocking) tile(issue),
              if (warnings.isNotEmpty) const SizedBox(height: 8),
            ],
            if (warnings.isNotEmpty) ...[
              Text(
                '可以带着应用（会缺少一部分）',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              for (final issue in warnings) tile(issue),
            ],
          ],
        ),
      ),
    );
  }
}
