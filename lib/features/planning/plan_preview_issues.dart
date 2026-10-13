import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/preview_failure_lines.dart'
    show unnamedTaskLabel;
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/task_placement_diagnostics.dart';

// 预览问题模型与**延后失败行**共用同一句占位文案（规范 §13.1）：
// 同一个概念只能有一个名字，因此这里把定义转发出去，而不是另写一份常量。
export 'package:personal_planner/scheduling/preview_failure_lines.dart'
    show unnamedTaskLabel;

/// 一条预览问题的**严重级别**（1.8.0，2026-10-12 故障；冻结决策 §1.6）。
///
/// **为什么必须分级**：截图里"容量不足"（可以明确确认后部分应用）与
/// "排程输入无效"（结构性错误，绝不能写入）被渲染成同一张卡片、同一种图标，
/// 于是页面只能给出同一个可点击的"确认应用"。
///
/// 分级之后按钮状态由它派生，而不是由页面临时判断。
enum PreviewIssueSeverity {
  /// **可以带着它应用**（在用户明确确认之后）：容量缺口属于这一级。
  warning,

  /// **不得应用**：重叠、越界、锁定块被移动、非法输入……都属这一级。
  blocking,
}

/// 预览里一条问题**可以采取的恢复动作**（1.8.0，计划 §2.8）。
///
/// **为什么是枚举而不是"跳转地址"**：页面不该知道路由长什么样（那是装配层的事），
/// 而装配层也不该知道"哪种原因该给哪个动作"（那是问题模型的职责）。
/// 两者的接缝就是这几个值：问题模型只按 reason code 选出动作，
/// 装配层再把每个动作翻成一条真实可达的路由。
///
/// **动作由 reason code 决定，不由任务属性推测**：修复前预览只能给一句文字，
/// 用户读完不知道去哪。"这件任务截止时间太早"要改任务，"每日上限已满"要改规划规则——
/// 这条映射只有引擎给的原因说了算（计划 §2.8 的映射表）。
enum PreviewRecoveryAction {
  /// 打开**既有**任务编辑路由，带上 `issue.taskId`。
  editTask,

  /// 打开规划规则页（每日上限、片段间休息、守护时段都在那里）。
  openPlanningRules,

  /// 打开保护时间管理页。
  openProtectedTimeManagement,

  /// 走既有的重新生成入口（无法解释的排程异常只有这一条路）。
  recalculate,
}

/// 预览里的一条问题：**标题 ＋ 缺口 ＋ 具体原因**（冻结决策 §1.6）。
///
/// **为什么不再用 `List<String> conflicts`**：字符串丢掉了任务、块、数值与 invalid 原因
/// （R7），于是页面既说不清"是哪一件事"，也说不出"为什么"。
/// [key] 是**去重键**（稳定、可断言），不是给用户看的。
///
/// 1.8.0（计划 §2.8）补上三样：**哪件事**（[taskId]）、
/// **哪段时间为什么用不上**（[excludedGaps]）与**能做什么**（[actions]）。
final class PreviewIssue {
  const PreviewIssue({
    required this.key,
    required this.severity,
    required this.title,
    required this.message,
    this.taskId,
    this.excludedGaps = const [],
    this.actions = const [],
  });

  /// 稳定的去重键。同一件事只能产生一个键。
  final String key;
  final PreviewIssueSeverity severity;
  final String title;
  final String message;

  /// 这条问题属于哪件任务；冲突行可能没有任务（例如两个无主块重叠）。
  ///
  /// **恢复动作要靠它**：`editTask` 需要带一个真实的 taskId，为空时页面**不显示**该动作
  /// （计划 §2.8：不给一个点了没反应的按钮）。
  final String? taskId;

  /// 这段缺口相关的、**未被使用**的空档证据（来自提案里的最终诊断）。
  ///
  /// 数据本身**不截断**：页面首屏只显示前几条，其余折叠成"另有 N 段"，
  /// 但这里的列表始终是完整的（计划 Task 6 Step 3）。
  final List<ExcludedGapEvidence> excludedGaps;

  /// 与主原因匹配的恢复动作，顺序即展示顺序。
  final List<PreviewRecoveryAction> actions;

  bool get isBlocking => severity == PreviewIssueSeverity.blocking;
}

/// 由**主原因**映射恢复动作（计划 §2.8 的映射表，逐条实现）。
///
/// **入参只有 reason code**：这个函数的签名里没有任务、没有设置、没有日历，
/// 因此"按任务属性猜原因"在类型上就做不到（与 `unscheduledReasonLabel` 同一条纪律）。
///
/// 三张表里没有规定的三种原因按**同一条纪律**补：
/// - `fixedScheduleOccupied`／`lockedPlanOccupied`：可动的只有任务本身
///   （改时段、改截止、换拆分方式），因此给 `editTask`；
/// - `requiredBreakUnavailable`：片段间休息是**规划规则**里的一个数
///   （`planning_rules_page.dart` 的"片段间休息（分钟）"），与每日上限同一张卡，
///   因此沿用 `dailyLimitReached` 那条：先规则、后任务。
List<PreviewRecoveryAction> recoveryActionsFor(UnscheduledReasonCode code) =>
    switch (code) {
      UnscheduledReasonCode.deadlineWindowTooShort ||
      UnscheduledReasonCode.continuousGapTooShort ||
      UnscheduledReasonCode.minimumChunkTooLarge ||
      UnscheduledReasonCode.availableTimeNotReached ||
      UnscheduledReasonCode.fixedScheduleOccupied ||
      UnscheduledReasonCode.lockedPlanOccupied => const [
        PreviewRecoveryAction.editTask,
      ],
      UnscheduledReasonCode.dailyLimitReached ||
      UnscheduledReasonCode.requiredBreakUnavailable => const [
        PreviewRecoveryAction.openPlanningRules,
        PreviewRecoveryAction.editTask,
      ],
      UnscheduledReasonCode.protectedTimeOccupied => const [
        PreviewRecoveryAction.openProtectedTimeManagement,
        PreviewRecoveryAction.editTask,
      ],
      UnscheduledReasonCode.insufficientCapacity => const [
        PreviewRecoveryAction.editTask,
        PreviewRecoveryAction.openPlanningRules,
      ],
      UnscheduledReasonCode.unexplainedSchedulingFailure => const [
        PreviewRecoveryAction.recalculate,
      ],
    };

/// 每个 [GapExclusionCode] 对应**一句用户能据以行动的中文**（计划 §1.2 U4）。
///
/// **绝不显示枚举名**：`shorterThanRequiredChunk` 对用户不是一句话，
/// 而"这段空档短于最短片段"是——他据此知道该缩短任务的最小片段，或者放过这段空档。
String gapExclusionReason(GapExclusionCode code) => switch (code) {
  GapExclusionCode.beforeAvailableFrom => '这段时间在任务的最早开始时间之前',
  GapExclusionCode.afterDeadline => '这段时间在任务的截止时间之后',
  GapExclusionCode.disallowedWeekday => '这一天不在任务允许的星期里',
  GapExclusionCode.shorterThanRequiredChunk => '这段空档短于最短片段',
  GapExclusionCode.dailyTaskLimitReached => '这一天的任务每日上限已经用满',
  GapExclusionCode.dailyMovableLimitReached => '这一天的可移动安排上限已经用满',
  GapExclusionCode.dailyEvenBudgetReached => '这一天的均匀分布份额已经用满',
  GapExclusionCode.requiredBreakUnavailable => '这段时间凑不出片段之间需要的休息',
  GapExclusionCode.occupiedByFixedSchedule => '这段时间被固定日程占住',
  GapExclusionCode.occupiedByProtectedTime => '这段时间被保护时间占住',
  GapExclusionCode.occupiedByLockedBlock => '这段时间被已锁定的计划块占住',
};

/// "未使用空档"的一行：**本地日期时间 ＋ 原因**（计划 Task 6 Step 3）。
///
/// `zones.toLocal()` 是**唯一**的换算入口：UTC 区间直接印出来会在东八区差 8 小时，
/// 用户拿着这行字去日历上找，只会找到一段根本没有空闲的时间。
///
/// **不追加"需要 N 分钟／只有 M 分钟"**：那两个数字在不同 code 下口径不同
/// （有的是"试过的片段长度"，有的是"这段空档本身有多长"），
/// 混在一行里会让用户按一个不存在的额度去改设置（与 §2.4 禁止重算缺口同一条纪律）。
String excludedGapLabel(
  ExcludedGapEvidence gap, {
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) {
  final start = zones.toLocal(gap.range.startUtc, timeZoneId);
  final end = zones.toLocal(gap.range.endUtc, timeZoneId);
  String two(int value) => value.toString().padLeft(2, '0');
  final startsAndEndsSameDay =
      start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
  final startText =
      '${two(start.month)}-${two(start.day)} '
      '${two(start.hour)}:${two(start.minute)}';
  // 跨午夜的空档要写出结束那一侧的日期：只写 `23:00–01:00` 会被读成同一天的倒退区间。
  final endText = startsAndEndsSameDay
      ? '${two(end.hour)}:${two(end.minute)}'
      : '${two(end.month)}-${two(end.day)} '
            '${two(end.hour)}:${two(end.minute)}';
  return '$startText–$endText　${gapExclusionReason(gap.code)}';
}

/// 一个块是否**属于前向预览**（1.8.0，冻结决策 §1.3）。
///
/// **两侧都要过滤**：只看提案那一侧不够——当前计划里的历史块会因为"提案里没有它"
/// 被 `PlanDiffer` 报成**移除**，于是用户看到昨天与今天已结束的安排被"删除"。
///
/// 判据是"与规划窗口相交"（半开区间）：
/// - 已结束的块（`end <= window.start`）⇒ 不显示；
/// - **进行中的块**（跨过起点）⇒ 显示（它是当前承诺）；
/// - 恰好在起点开始的块 ⇒ 显示。
bool visibleToForwardPreview(PlannedBlock block, TimeRange planningWindow) =>
    block.endUtc.isAfter(planningWindow.startUtc) &&
    block.startUtc.isBefore(planningWindow.endUtc);

/// 把结构化冲突与缺口转成预览问题（冻结决策 §1.6）。
///
/// **职责边界**（计划 §2 的文件职责表）：
/// - 本函数是**纯函数**：不访问数据库、不读时钟、不依赖 Flutter；
/// - 批量标题表由调用方传入（一次 `TaskTitleLookup.titlesFor()` 的结果）；
/// - 找不到标题回落 [unnamedTaskLabel]（定义在 `preview_failure_lines.dart`），
///   **绝不回落成 UUID**。
///
/// **顺序与去重**：
/// 1. 每个 `unscheduled` 一条 warning（标题、缺口分钟、主原因三件都在）；
/// 2. 每个 `conflict` 一条 blocking；
/// 3. 相同 `taskId + shortage` 只出现一次。
///
/// **缺口与冲突不会互相重复**：容量缺口只有一个结构化来源（`unscheduled`），
/// 引擎不再补 `insufficientCapacity` 冲突。去重仍然保留为第二道防线。
///
/// **无法解释的排程异常是唯一需要跨两处合并的一类**（1.8.0 专项 §2.4）：
/// 引擎必须同时给出 `unscheduled` 里那条 `unexplainedSchedulingFailure`（供缺口数字）
/// 与一条 `schedulingInvariantViolation` blocker（供"不得应用"这个级别）。
/// 它们是**同一件事**，因此这里把该任务的缺口行提升为 `blocking`，并**跳过**
/// 对应的冲突行——否则同一件事会在页面上说两遍（一句 warning、一句 blocker），
/// 那正是冻结决策 §1.5 要消灭的形态。
List<PreviewIssue> buildPreviewIssues({
  required ScheduleProposal proposal,
  required Map<String, String> titleByTaskId,
}) {
  final issues = <PreviewIssue>[];
  final seen = <String>{};
  // 被提升为阻断的缺口：**先去重再提升**，于是 warning 与 blocker 只会留下一条。
  final unexplainedTasks = <String>{
    for (final conflict in proposal.conflicts)
      if (conflict.code == ConflictCode.schedulingInvariantViolation &&
          conflict.taskId != null)
        conflict.taskId!,
  };

  for (final task in proposal.unscheduled) {
    final title = titleOfTask(task.taskId, titleByTaskId);
    final isUnexplained =
        unexplainedTasks.contains(task.taskId) ||
        task.primaryReason.code ==
            UnscheduledReasonCode.unexplainedSchedulingFailure;
    final key = 'unscheduled:${task.taskId}:${task.shortageMinutes}';
    if (!seen.add(key)) continue;
    issues.add(
      PreviewIssue(
        key: key,
        // **容量不足是 warning**：允许用户明确确认后应用可安排的部分。
        // **无法解释的排程异常是 blocking**：排程器解释不了的安排不该被写进计划。
        severity: isUnexplained
            ? PreviewIssueSeverity.blocking
            : PreviewIssueSeverity.warning,
        title: '$title 还缺 ${task.shortageMinutes} 分钟',
        // 原因只说引擎给的那一条，页面上不猜（与 `unscheduledReasonLabel` 同一条纪律）。
        message: unscheduledReasonLabel(task.primaryReason),
        taskId: task.taskId,
        // **证据来自提案里的最终诊断**（不是放置循环里的旧证据）：
        // 它回答的正是用户盯着日历空白时要问的那句"这段为什么不能用"。
        // 诊断缺失（例如测试直接构造的提案）时如实留空，页面上不编一段空档出来。
        excludedGaps:
            proposal.placementDiagnostics[task.taskId]?.excludedGaps ??
            const [],
        // **动作只由主原因决定**（§2.8 的映射表）。
        actions: recoveryActionsFor(task.primaryReason.code),
      ),
    );
  }

  for (var index = 0; index < proposal.conflicts.length; index++) {
    final conflict = proposal.conflicts[index];
    final taskId = conflict.taskId;
    // **已被缺口行承载的那条 blocker 不重复显示**（见上面的说明）。
    // 条件用同一个 `unexplainedTasks` 集合，因此"提升"与"跳过"不会各自漂移。
    if (conflict.code == ConflictCode.schedulingInvariantViolation &&
        taskId != null &&
        unexplainedTasks.contains(taskId) &&
        proposal.unscheduled.any((item) => item.taskId == taskId)) {
      continue;
    }
    final title = taskId == null ? null : titleOfTask(taskId, titleByTaskId);
    // 键里带下标是必要的：同一种冲突可能合法地出现多次（例如两个不同块各与固定日程重叠，
    // 而它们都没有 taskId）。用"内容"作键会把它们合并掉，那会**少报**问题。
    final key = 'conflict:$index:${conflict.code.name}';
    if (!seen.add(key)) continue;
    issues.add(
      PreviewIssue(
        key: key,
        severity: PreviewIssueSeverity.blocking,
        title: title ?? conflictLabel(conflict.code),
        // **唯一翻译链**：与 `previewFailureLines` 共用同一个函数，
        // 因此 invalid 原因会分别写成"时间块早于本次规划范围"等具体说法。
        message: planningConflictMessage(
          conflict,
          taskTitle: title ?? unnamedTaskLabel,
        ),
        taskId: taskId,
        // **冲突行不给恢复动作**（计划 Task 6 Step 1）：冲突说的是"计划内部有矛盾"，
        // 它的处置是挑一个让步，由用户自己在冲突卡片与底部主操作之间决定；
        // 与某件任务一一对应的"编辑任务"在这里会指向一个不必然相关的入口。
        // 唯一需要"重新生成"的那条路径（无法解释的排程异常）由底部主操作承担。
      ),
    );
  }

  return issues;
}

/// 标题解析：**批量映射里查，查不到用占位文案，绝不回退成 id**。
///
/// 与 `preview_failure_lines.dart` 的 `_titleOf` 是同一条规则，因此在这里**公开**一份，
/// 供预览问题模型与路由共用。
String titleOfTask(String taskId, Map<String, String> titleByTaskId) {
  final title = titleByTaskId[taskId]?.trim();
  return title == null || title.isEmpty ? unnamedTaskLabel : title;
}
