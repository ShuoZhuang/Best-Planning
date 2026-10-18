import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';
import 'package:personal_planner/design/protected_time_labels.dart';
import 'package:personal_planner/domain/models/capacity_shortfall.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_title_lookup.dart';
import 'package:personal_planner/features/planning/plan_preview_issues.dart';
import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/extension_day_policy.dart';
import 'package:personal_planner/scheduling/proposal_disposition.dart';
import 'package:personal_planner/scheduling/task_placement_diagnostics.dart';
// `unnamedTaskLabel` 由 `plan_preview_issues.dart` 转发（同一个概念只有一个名字），
// 因此这里不再单独 import `preview_failure_lines.dart`——那会变成两处来源。
export 'package:personal_planner/features/planning/plan_preview_issues.dart'
    show
        PreviewIssue,
        PreviewIssueSeverity,
        PreviewRecoveryAction,
        buildPreviewIssues,
        excludedGapLabel,
        gapExclusionReason,
        recoveryActionsFor;
export 'package:personal_planner/scheduling/explanations.dart'
    show unscheduledReasonLabel;
export 'package:personal_planner/scheduling/preview_failure_lines.dart'
    show PreviewFailureLine, formatFailureLine, previewFailureLines;
export 'package:personal_planner/scheduling/preview_failure_lines.dart'
    show unnamedTaskLabel;
export 'package:personal_planner/scheduling/task_placement_diagnostics.dart'
    show ExcludedGapEvidence, GapExclusionCode, TaskPlacementDiagnostics;

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
    List<ExtensionDayCandidate> extensionCandidates = const [],
  }) : changes = UnmodifiableListView(List.of(changes)),
       issues = UnmodifiableListView(List.of(issues)),
       shortfalls = UnmodifiableListView(List.of(shortfalls)),
       extensionCandidates = UnmodifiableListView(List.of(extensionCandidates));

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

  /// 临时延长日建议（规范 §8.3）：页面只显示一张建议卡，不自动弹窗。
  final List<ExtensionDayCandidate> extensionCandidates;

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

  /// 同一份内容、标记为**过期**（计划 Task 6 Step 2）。
  ///
  /// **为什么需要它**：用户从预览点进"编辑任务／调整规划规则／管理保护时间"之后，
  /// 这份提案的输入可能已经变了。返回预览时页面必须说"它作废了，请重新生成"，
  /// 而不是继续把一份按旧输入算出的计划递给"确认应用"——
  /// 那正是"看着能用、点下去必然失败"的形态。
  ///
  /// 它**不改内容**（变更、问题、缺口逐条保留）：用户要看的是自己刚看的那一版，
  /// 只是不能再应用它。
  PlanPreviewModel asStale() => PlanPreviewModel(
    proposalId: proposalId,
    changes: changes,
    issues: issues,
    isStale: true,
    shortfalls: shortfalls,
    extensionCandidates: extensionCandidates,
  );
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
    this.onRecover,
    this.availableRecoveryActions = const {},
    this.zones,
    this.timeZoneId,
    this.onConfirmExtension,
    this.onRejectExtension,
    this.onCustomExtension,
    super.key,
  });

  final PlanPreviewModel model;
  final AutoAdjustStore autoAdjustStore;

  /// 采纳一条**恢复动作**（计划 §2.8 / Task 6 Step 2）。
  ///
  /// 页面只负责把"用户想做什么"报出去：真正打开哪个页面、返回后怎么处理这份提案，
  /// 都属于装配层（`router.dart`）。为 `null` 时**一条恢复动作都不渲染**——
  /// 未装配时给出一个点了没反应的入口比不给更糟（与 [onUndoPlan]、[onRecalculate] 同一条约定）。
  final Future<void> Function(PreviewRecoveryAction action, PreviewIssue issue)?
  onRecover;

  /// 当前装配下**真的能到达**的恢复动作（计划 §2.8：路由未装配则不显示该动作）。
  ///
  /// **为什么由装配层给而不是页面猜**：页面不知道"保护时间管理页这次接没接线"，
  /// 而一个问题模型也不知道路由长什么样。默认空集合＝什么都不显示，
  /// 因此漏传时页面是"少一个入口"，不会变成"多一个点了没反应的按钮"。
  final Set<PreviewRecoveryAction> availableRecoveryActions;

  /// 把空档证据里的 UTC 区间写成**本地**时间（计划 Task 6 Step 3）。
  ///
  /// 为空时"查看未使用空档"**不渲染**：拿不到时区就只能印 UTC，
  /// 而那行字会让用户去日历上找一段时间，实际差着时差。
  /// 装配层两者都会传（它本来就持有 `zones` 与 `timeZoneId`）。
  final TimeZoneDatabase? zones;
  final String? timeZoneId;

  /// 确认临时延长日（规范 §8.3）。为空时建议卡只展示、不提供按钮。
  final Future<void> Function(ExtensionDayCandidate candidate)?
  onConfirmExtension;

  /// 拒绝本次延长建议；由装配层写入按输入哈希的拒绝记忆。
  final Future<void> Function()? onRejectExtension;

  /// 自定义延长日期与结束时间；由装配层校验并生成新的预览提案。
  final Future<void> Function(DateTime localDate, int endMinute)?
  onCustomExtension;

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
  bool _applying = false;
  bool _recalculating = false;

  /// 是否正有一条恢复动作在飞行中（导航／重新生成）。
  ///
  /// 存在的理由与 `_applying` 相同：一次点击必须只发生一次动作。
  /// `editTask` 这一类会一直等到用户从那个页面回来，因此期间必须挡住重复点击。
  bool _recovering = false;
  bool _extensionsRejected = false;

  /// 上一次应用失败的**具体原因**（为空表示没有失败过）。
  ///
  /// 存在的理由（冻结决策 §1.6 的最后一行）：应用阶段若发现新的阻断错误，
  /// 要显示具体任务与原因，并且**按钮不得允许无限重复点击同一个必失败操作**。
  /// 失败之后页面转入"先修问题"的状态：主操作变成"重新生成计划"。
  List<PreviewIssue> _applyFailures = const [];

  /// 主按钮当前是否可用。
  ///
  /// **三种情况都不可用**：过期、正在应用、模型本身含阻断问题。
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

  /// 跑一条恢复动作（编辑任务／规划规则／保护时间／重新生成）。
  ///
  /// **动作本身不在这里实现**：页面把（动作，问题）交给装配层，由它决定打开哪一页、
  /// 以及回到预览之后这份提案还算不算数（计划 Task 6 Step 2）。
  Future<void> _pickCustomExtension(ExtensionDayCandidate candidate) async {
    final date = await showDatePicker(
      context: context,
      initialDate: candidate.localDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      helpText: '选择延长日日期',
    );
    if (date == null || !mounted) return;
    final minute = candidate.temporarySleepStartOffsetMinutes % (24 * 60);
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
      helpText: '选择入睡时间',
    );
    if (time == null || !mounted) return;
    await widget.onCustomExtension!(date, time.hour * 60 + time.minute);
  }

  Future<void> _runRecovery(
    PreviewRecoveryAction action,
    PreviewIssue issue,
  ) async {
    final recover = widget.onRecover;
    if (recover == null || _recovering) return;
    setState(() => _recovering = true);
    try {
      await recover(action, issue);
    } finally {
      if (mounted) setState(() => _recovering = false);
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
            // **逐条列出每件任务的准确缺口**（标题里的分钟数就是
            // `UnscheduledTask.shortageMinutes`），因为用户是在为"就这样应用"负责。
            //
            // **不再在这里重算缺口**（§2.4 禁止的捷径）：正文只说约束，数字只在标题里。
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
            const SizedBox(height: 8),
            // **未安排不等于被删除**：任务仍在待办里，下一次生成还会考虑它。
            // 不说这一句，用户很容易把"这次没排进去"读成"这件事没了"。
            Text(
              '未排进去的部分仍留在待办中，重新生成计划时会再次考虑。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
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
                      // **只有说明，动作在下面那一个主操作上**（§2.8 三态表）：
                      // 过期状态的主操作就是"重新生成计划"。此前这里另有一个按钮，
                      // 于是同一页出现两个做同一件事的入口，其中一个还是全宽主按钮样式。
                      const ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.refresh),
                        title: Text('提案已过期，请重新计算'),
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
            if (!_extensionsRejected)
              for (final candidate in model.extensionCandidates)
                _ExtensionSuggestionCard(
                  candidate: candidate,
                  timeZoneId: widget.timeZoneId,
                  zones: widget.zones,
                  onConfirm: widget.onConfirmExtension == null
                      ? null
                      : () => widget.onConfirmExtension!(candidate),
                  onReject: widget.onRejectExtension == null
                      ? null
                      : () async {
                          await widget.onRejectExtension!();
                          if (mounted) {
                            setState(() => _extensionsRejected = true);
                          }
                        },
                  onCustom: widget.onCustomExtension == null
                      ? null
                      : () => _pickCustomExtension(candidate),
                ),
            if (model.shortfalls.isNotEmpty)
              _ShortfallGroup(
                shortfalls: model.shortfalls,
                onHandle: widget.onHandleShortfall,
              ),
            if (model.issues.isNotEmpty)
              _IssueGroup(
                issues: model.issues,
                onRecover: widget.onRecover == null ? null : _runRecovery,
                availableRecoveryActions: widget.availableRecoveryActions,
                zones: widget.zones,
                timeZoneId: widget.timeZoneId,
                recovering: _recovering,
              ),
            if (_applyFailures.isNotEmpty)
              // **应用失败的卡片不给恢复动作**：它说的是"刚才那一下没写进去"，
              // 按任务编辑入口在这里不必然相关（问题也本来就都是阻断级）。
              _IssueGroup(
                key: const Key('apply-failure-group'),
                title: '应用未完成',
                issues: _applyFailures,
              ),
            const Divider(height: 32),
            _ConfirmButton(
              model: model,
              applying: _applying,
              failed: _applyFailures.isNotEmpty,
              canApply: _canApply,
              canApplyPartial: _canApplyPartial,
              onPressed: _confirm,
              onRecalculate: widget.onRecalculate == null ? null : _recalculate,
              recalculating: _recalculating,
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

/// 临时延长日建议卡（规范 §8.3）。
///
/// **只显示一张卡，不自动弹窗**：打开预览不写任何设置；用户必须到特殊日页
/// 选择候选并确认，应用层才在同一事务里写特殊日与计划。
final class _ExtensionSuggestionCard extends StatelessWidget {
  const _ExtensionSuggestionCard({
    required this.candidate,
    this.zones,
    this.timeZoneId,
    this.onConfirm,
    this.onReject,
    this.onCustom,
  });

  final ExtensionDayCandidate candidate;
  final TimeZoneDatabase? zones;
  final String? timeZoneId;
  final Future<void> Function()? onConfirm;
  final Future<void> Function()? onReject;
  final Future<void> Function()? onCustom;

  @override
  Widget build(BuildContext context) {
    final date = '${candidate.localDate.month} 月 ${candidate.localDate.day} 日';
    final sleep = _clockLabel(candidate.temporarySleepStartOffsetMinutes);
    final wake = _clockLabel(candidate.fixedWakeOffsetMinutes);
    return Card(
      key: ValueKey('extension-day-${candidate.stableKey}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.bedtime_outlined),
            title: Text('可以临时延长 $date 的入睡时间'),
            subtitle: Text(
              '入睡 $sleep，固定起床仍为 $wake；预计可多安排 '
              '${candidate.addedPlaceableMinutes} 分钟。'
              '确认前不会改动计划。',
            ),
          ),
          if (onConfirm != null || onReject != null || onCustom != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onCustom != null)
                    TextButton.icon(
                      key: const Key('custom-extension-day'),
                      onPressed: onCustom,
                      icon: const Icon(Icons.edit_calendar_outlined),
                      label: const Text('自定义日期和时间'),
                    ),
                  if (onReject != null)
                    TextButton.icon(
                      key: const Key('reject-extension-day'),
                      onPressed: onReject,
                      icon: const Icon(Icons.close),
                      label: const Text('本次不采用'),
                    ),
                  if (onConfirm != null)
                    FilledButton.icon(
                      key: const Key('confirm-extension-day'),
                      onPressed: onConfirm,
                      icon: const Icon(Icons.check),
                      label: const Text('确认延长并应用'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _clockLabel(int offsetMinutes) {
    final minute = offsetMinutes % (24 * 60);
    final hour = (minute ~/ 60).toString().padLeft(2, '0');
    final rest = (minute % 60).toString().padLeft(2, '0');
    return '$hour:$rest';
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
                        '保护时间不动；缺口是在「${protectedTimeKindLabel(shortfall.protectedConstraint!)}」'
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

// 保护时间的用户文案不再由本文件定义（计划 §2.5）：此前这里的 `_protectedLabel` 与
// 日历数据源里那份按 id 解析的实现**各写一遍**，同一个类别在两个页面显示不同的话。
// 现在两处都调用 `design/protected_time_labels.dart::protectedTimeKindLabel`。

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

/// 底部**唯一的**主操作（冻结决策 §1.6 的三态表，1.8.0 计划 §2.8 重写）。
///
/// | 状态 | 主操作 | 部分应用 |
/// | --- | --- | --- |
/// | fullyApplicable | `FilledButton`「确认应用」 | 不显示 |
/// | partialRequiresConfirmation | **不放全宽主按钮** | `OutlinedButton`「仍应用可安排部分」＋二次确认 |
/// | blocked（含无法解释／结构错误） | `FilledButton`「重新生成计划」（**可点**） | 不显示 |
/// | stale | `FilledButton`「重新生成计划」（**可点**） | 不显示 |
/// | 刚刚应用失败过 | `FilledButton`「重新生成计划」（**可点**） | 不显示 |
///
/// **修复前是"禁用 ＋ 一条次要的重新生成"**：主按钮显示「无法应用」且 `onPressed == null`，
/// 出路是一条 `OutlinedButton`。两件事都错：
/// 1. 屏幕正中最大的控件是一个永远点不动的按钮——用户读到的信息是"这功能坏了"，
///    而不是"你要先做另一件事"（计划 §6 禁止的捷径：不许用"把按钮禁用"伪装问题解决）；
/// 2. 真正该做的那件事（重新生成计划）被降级成次要样式，与它的必要性不符。
///
/// **阻断与过期依然不能被绕过**：它们根本不渲染应用按钮，因此键盘、语义动作与程序化点击
/// 都点不到"确认应用"——这与"放一个禁用的确认按钮"在安全性上等价，但诚实得多。
///
/// **未装配重新生成入口时什么都不渲染**（与 `PlanPreviewPage.onRecalculate` 的约定一致）：
/// 宁可不给，也不要一个点了不生效的按钮。
final class _ConfirmButton extends StatelessWidget {
  const _ConfirmButton({
    required this.model,
    required this.applying,
    required this.failed,
    required this.canApply,
    required this.canApplyPartial,
    required this.onPressed,
    required this.onRecalculate,
    required this.recalculating,
  });

  final PlanPreviewModel model;
  final bool applying;
  final bool failed;
  final bool canApply;
  final bool canApplyPartial;
  final Future<void> Function() onPressed;
  final Future<void> Function()? onRecalculate;
  final bool recalculating;

  @override
  Widget build(BuildContext context) {
    final disposition = model.disposition;
    // ① 无法解释／结构错误、过期、刚刚失败：**主操作是"重新生成计划"**，且可点。
    final needsRecalculation =
        model.isStale || failed || disposition == ProposalDisposition.blocked;
    if (needsRecalculation) {
      final recalculate = onRecalculate;
      if (recalculate == null) return const SizedBox.shrink();
      return FilledButton.icon(
        key: const Key('recalculate-plan'),
        onPressed: recalculating ? null : recalculate,
        icon: recalculating
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.autorenew),
        label: const Text('重新生成计划'),
      );
    }
    // ② 可解释的真实缺口：**底部不放误导性的全宽主按钮**（§1.2 U2）。
    //    部分应用降为次要危险动作，并且仍然要二次确认（`_confirm` 里那一段）。
    if (disposition == ProposalDisposition.partialRequiresConfirmation) {
      return OutlinedButton.icon(
        key: const Key('apply-partial'),
        onPressed: canApplyPartial && !applying ? onPressed : null,
        icon: applying
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.report_problem_outlined),
        label: const Text('仍应用可安排部分'),
      );
    }
    // ③ 完整可行：唯一一条"确认即应用"的路径。
    return FilledButton.icon(
      key: const Key('apply-plan'),
      onPressed: canApply && !applying ? onPressed : null,
      icon: applying
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.check),
      label: const Text('确认应用'),
    );
  }
}

/// 问题卡片组：warning 与 blocking **用不同图标、标题和颜色**，
/// 但**不得仅靠颜色区分**（冻结决策 §1.6 的最后一条），因此图标与文字同时不同。
final class _IssueGroup extends StatelessWidget {
  const _IssueGroup({
    required this.issues,
    this.title,
    this.onRecover,
    this.availableRecoveryActions = const {},
    this.zones,
    this.timeZoneId,
    this.recovering = false,
    super.key,
  });

  final List<PreviewIssue> issues;
  final String? title;

  /// 采纳一条恢复动作；为空时**一条动作都不渲染**（见 `PlanPreviewPage.onRecover`）。
  final Future<void> Function(PreviewRecoveryAction action, PreviewIssue issue)?
  onRecover;
  final Set<PreviewRecoveryAction> availableRecoveryActions;

  /// 空档证据的本地化所需的时区；任一为空时"查看未使用空档"不渲染。
  final TimeZoneDatabase? zones;
  final String? timeZoneId;

  /// 有动作正在飞行中（防止一次点击变成两次导航）。
  final bool recovering;

  @override
  Widget build(BuildContext context) {
    final blocking = issues.where((issue) => issue.isBlocking).toList();
    final warnings = issues.where((issue) => !issue.isBlocking).toList();

    Widget tile(PreviewIssue issue) => _IssueTile(
      issue: issue,
      onRecover: onRecover,
      availableRecoveryActions: availableRecoveryActions,
      zones: zones,
      timeZoneId: timeZoneId,
      recovering: recovering,
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
                // **警告那一组自己带「需要注意」**：卡片标题在**同时**有阻断时取
                // 「无法应用的问题」（那是对的——那一屏确实不能应用），于是
                // `需要注意` 这个措辞此前整屏都不出现，用户只能从「可以带着应用」这一句
                // 反推严重级别。分组标题是这一组**固定的名字**，不该随同屏有没有阻断而变，
                // 因此这里把它写全：先说级别，再说后果。
                '需要注意：可以带着应用（会缺少一部分）',
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

/// 一条问题：**标题 ＋ 主原因**（默认只显示主原因，§1.2 U4），
/// 加上**恢复动作**与可展开的**未使用空档证据**。
final class _IssueTile extends StatelessWidget {
  const _IssueTile({
    required this.issue,
    required this.onRecover,
    required this.availableRecoveryActions,
    required this.zones,
    required this.timeZoneId,
    required this.recovering,
  });

  final PreviewIssue issue;
  final Future<void> Function(PreviewRecoveryAction action, PreviewIssue issue)?
  onRecover;
  final Set<PreviewRecoveryAction> availableRecoveryActions;
  final TimeZoneDatabase? zones;
  final String? timeZoneId;
  final bool recovering;

  /// 这一条**实际会显示**的动作。
  ///
  /// 三重过滤，每一重都对应计划里的一句话：
  /// 1. `onRecover == null` ⇒ 装配层没法处理任何动作，一个都不显示；
  /// 2. `availableRecoveryActions` 不含它 ⇒ 那条路由这次没接线（§2.8：不显示该动作）；
  /// 3. `editTask` 还需要 `issue.taskId`（为空就没有可编辑的对象）；
  /// 4. **阻断问题不给恢复动作**（Task 6 Step 1）：冲突行的处置不是"改某一件事"，
  ///    而它唯一需要的那条路（无法解释的排程异常 ⇒ 重新生成）由底部主操作承担。
  List<PreviewRecoveryAction> get _visibleActions {
    if (issue.isBlocking) return const [];
    final recover = onRecover;
    if (recover == null) return const [];
    return [
      for (final action in issue.actions)
        if (availableRecoveryActions.contains(action) &&
            (action != PreviewRecoveryAction.editTask || issue.taskId != null))
          action,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final actions = _visibleActions;
    final gaps = issue.excludedGaps;
    final showGaps = gaps.isNotEmpty && zones != null && timeZoneId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            issue.isBlocking ? Icons.error_outline : Icons.info_outline,
            color: issue.isBlocking ? scheme.error : scheme.tertiary,
          ),
          title: Text(issue.title),
          // **默认只说主原因**：把所有约束一次摊开会把"最该先处理的那一条"淹没。
          subtitle: Text(issue.message),
        ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 56, bottom: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final action in actions)
                  OutlinedButton.icon(
                    key: Key('recovery-${issue.key}-${action.name}'),
                    onPressed: recovering
                        ? null
                        : () => onRecover!(action, issue),
                    icon: Icon(action.icon, size: 18),
                    label: Text(action.label),
                  ),
              ],
            ),
          ),
        if (showGaps)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            child: _ExcludedGapExpansion(
              issueKey: issue.key,
              gaps: gaps,
              zones: zones!,
              timeZoneId: timeZoneId!,
            ),
          ),
      ],
    );
  }
}

/// 恢复动作的用户文案与图标（**枚举名绝不显示给用户**）。
extension on PreviewRecoveryAction {
  String get label => switch (this) {
    PreviewRecoveryAction.editTask => '编辑任务',
    PreviewRecoveryAction.openPlanningRules => '调整规划规则',
    PreviewRecoveryAction.openProtectedTimeManagement => '管理保护时间',
    PreviewRecoveryAction.recalculate => '重新生成计划',
  };

  IconData get icon => switch (this) {
    PreviewRecoveryAction.editTask => Icons.edit_outlined,
    PreviewRecoveryAction.openPlanningRules => Icons.tune,
    PreviewRecoveryAction.openProtectedTimeManagement => Icons.shield_outlined,
    PreviewRecoveryAction.recalculate => Icons.autorenew,
  };
}

/// "查看未使用空档"（计划 Task 6 Step 3 / §1.2 U4）。
///
/// **首屏最多 6 行，其余折叠为"另有 N 段"**，但 `gaps` 本身**不被截断**：
/// 折叠只是渲染策略，用户点一下就能看到剩下每一段。
/// 把数据截断成 6 条会让"为什么排不下"这件事永远说不完整。
final class _ExcludedGapExpansion extends StatefulWidget {
  const _ExcludedGapExpansion({
    required this.issueKey,
    required this.gaps,
    required this.zones,
    required this.timeZoneId,
  });

  final String issueKey;
  final List<ExcludedGapEvidence> gaps;
  final TimeZoneDatabase zones;
  final String timeZoneId;

  @override
  State<_ExcludedGapExpansion> createState() => _ExcludedGapExpansionState();
}

final class _ExcludedGapExpansionState extends State<_ExcludedGapExpansion> {
  /// 首屏行数（计划 Task 6 Step 3 的"最多 6 条"）。
  static const int _firstScreenLimit = 6;

  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final gaps = widget.gaps;
    final visible = _showAll
        ? gaps
        : gaps.take(_firstScreenLimit).toList(growable: false);
    final hidden = gaps.length - visible.length;
    return ExpansionTile(
      key: Key('excluded-gaps-${widget.issueKey}'),
      tilePadding: EdgeInsets.zero,
      title: const Text('查看未使用空档'),
      subtitle: Text('共 ${gaps.length} 段'),
      children: [
        for (final gap in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                // 本地日期时间 ＋ 原因（原因文案按 code 给出，绝不显示枚举名）。
                excludedGapLabel(
                  gap,
                  zones: widget.zones,
                  timeZoneId: widget.timeZoneId,
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        if (hidden > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: Key('excluded-gaps-more-${widget.issueKey}'),
              onPressed: () => setState(() => _showAll = true),
              child: Text('另有 $hidden 段'),
            ),
          ),
      ],
    );
  }
}
