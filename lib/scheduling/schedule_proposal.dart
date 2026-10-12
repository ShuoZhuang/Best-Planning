import 'dart:collection';

import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 一个任务排不下的**结构化**原因（路线图 Task 12A Step 6）。
///
/// **由排程引擎输出，预览层不得推测。** "为什么排不下"这个事实只有引擎在尝试放置时知道：
/// 事后按任务属性去猜，必然把"截止前最长空档只有 20 分钟"猜成笼统的"可用时间不足"，
/// 或者反过来把容量充足、只是被每日上限拦下的情况说成容量问题。用户据此做的处置完全不同
/// （放宽时段 vs 调低目标），因此归因错误比没有归因更糟。
enum UnscheduledReasonCode {
  /// 还没到任务的最早开始时间。
  availableTimeNotReached,

  /// 截止时间之前的窗口太短，装不下哪怕一个片段。
  deadlineWindowTooShort,

  /// 找不到足够长的**连续**空档（任务要求一次做完那么久）。
  continuousGapTooShort,

  /// 最小片段大于剩余量（`minChunk > remaining`）。
  minimumChunkTooLarge,

  /// 达到每日可安排任务上限。
  dailyLimitReached,

  /// 保护时间占住了可用时段。
  protectedTimeOccupied,

  /// 固定日程占住了可用时段。
  fixedScheduleOccupied,

  /// 锁定计划块占住了可用时段。
  lockedPlanOccupied,

  /// 片段之间的休息间隔无法满足（排满就没有休息）。
  requiredBreakUnavailable,

  /// 兜底：总体容量不足，上面几条都不成立。
  insufficientCapacity,
}

/// 一条拒绝证据：某个片段为什么没被采纳，附上可判定的数字。
///
/// `requiredMinutes` / `availableMinutes` 允许为空——不是每条原因都有这两个数
/// （例如"还没到最早开始时间"没有"需要多长"的概念）。**有数就带上**：预览要靠它写出
/// "要求连续 30 分钟，但截止前最长空档只有 20 分钟"这种用户能据以行动的句子。
final class UnscheduledReason {
  const UnscheduledReason({
    required this.code,
    this.requiredMinutes,
    this.availableMinutes,
    this.constraintLabel,
  });

  final UnscheduledReasonCode code;
  final int? requiredMinutes;
  final int? availableMinutes;
  final String? constraintLabel;
}

/// 主原因的稳定优先级（路线图 Task 12A Step 6 第 3 条，从高到低）。
///
/// **为什么需要它**：一个连续任务可能同时被保护时间切碎、又达到每日上限，最后碰巧检查到的是
/// 休息间隔。"最后一次被拒绝的约束"取决于候选遍历顺序，换个排序就换个说法，因此不能采用。
/// 正确做法是累计**全部**拒绝证据，再按这条固定优先级选主原因——同样的输入永远得到同样的说法。
const List<UnscheduledReasonCode> unscheduledReasonPriority = [
  UnscheduledReasonCode.availableTimeNotReached,
  UnscheduledReasonCode.deadlineWindowTooShort,
  UnscheduledReasonCode.continuousGapTooShort,
  UnscheduledReasonCode.minimumChunkTooLarge,
  UnscheduledReasonCode.dailyLimitReached,
  // 三种"被占住"并列：它们的处置同属一类（换个时间），先后不改变用户该做什么。
  UnscheduledReasonCode.protectedTimeOccupied,
  UnscheduledReasonCode.fixedScheduleOccupied,
  UnscheduledReasonCode.lockedPlanOccupied,
  UnscheduledReasonCode.requiredBreakUnavailable,
  UnscheduledReasonCode.insufficientCapacity,
];

/// 按 [unscheduledReasonPriority] 选主原因；没有证据时回落到兜底的容量不足。
UnscheduledReason primaryUnscheduledReason(List<UnscheduledReason> reasons) {
  if (reasons.isEmpty) {
    return const UnscheduledReason(
      code: UnscheduledReasonCode.insufficientCapacity,
    );
  }
  for (final code in unscheduledReasonPriority) {
    for (final reason in reasons) {
      if (reason.code == code) return reason;
    }
  }
  return reasons.first;
}

final class UnscheduledTask {
  const UnscheduledTask({
    required this.taskId,
    required this.shortageMinutes,
    this.primaryReason = const UnscheduledReason(
      code: UnscheduledReasonCode.insufficientCapacity,
    ),
    this.reasons = const [],
  });
  final String taskId;
  final int shortageMinutes;

  /// 用户看到的**那一条**原因。
  final UnscheduledReason primaryReason;

  /// 累计到的全部拒绝证据，供"展开查看其他限制"使用。
  ///
  /// **默认空列表而不是把 `primaryReason` 塞进去**：兜底构造（没有任何证据）时
  /// "其他限制"应该是空的，而不是把同一条原因再说一遍。
  final List<UnscheduledReason> reasons;
}

final class PlanExplanation {
  PlanExplanation({
    required this.code,
    Map<String, Object?> parameters = const {},
  }) : parameters = UnmodifiableMapView(Map.of(parameters));
  final String code;
  final Map<String, Object?> parameters;
}

final class ProposalMetrics {
  const ProposalMetrics({
    required this.isFullyFeasible,
    required this.scheduledMinutes,
    required this.unscheduledMinutes,
  });
  final bool isFullyFeasible;
  final int scheduledMinutes;
  final int unscheduledMinutes;
}

final class ScheduleProposal {
  ScheduleProposal({
    required this.proposalId,
    required this.inputHash,
    required this.algorithmVersion,
    required this.planningWindow,
    required List<PlannedBlock> blocks,
    required List<UnscheduledTask> unscheduled,
    required List<PlanningConflict> conflicts,
    required List<PlanExplanation> explanations,
    required this.metrics,
    this.ruleOverride,
    this.adjustmentRequirement,
  }) : blocks = UnmodifiableListView(List.of(blocks)),
       unscheduled = UnmodifiableListView(List.of(unscheduled)),
       conflicts = UnmodifiableListView(List.of(conflicts)),
       explanations = UnmodifiableListView(List.of(explanations));

  final String proposalId;
  final String inputHash;
  final String algorithmVersion;

  /// 生成这份提案时的**规划窗口**（1.8.0，2026-10-12 故障；冻结决策 §1.3）。
  ///
  /// **为什么必须随提案走**：窗口起点是"历史／进行中／未来"三种时间角色的**唯一分界**。
  /// 预览装配层要在**生成之后**过滤两侧的计划块（`visibleToForwardPreview`），
  /// 而它在预览打开时已经拿不到生成时的 `ScheduleProblem` 了 ——
  /// 提案只存在内存里，`PlanningService.preview(id)` 返回的就是它。
  ///
  /// **不能用"预览打开时的系统时钟"重算**：生成与预览之间用户可能已经等了一会儿，
  /// 那样同一份提案会随时钟漂移改变哪些块"可见"，而提案本身一个字都没变
  /// （`PlanDiffer` 也因此不该自己去读时钟）。
  final TimeRange planningWindow;

  final List<PlannedBlock> blocks;
  final List<UnscheduledTask> unscheduled;
  final List<PlanningConflict> conflicts;
  final List<PlanExplanation> explanations;
  final ProposalMetrics metrics;

  /// 生成该提案时使用的一次性规则覆盖（见 `ScheduleRuleOverride`），没有则为 null。
  ///
  /// 必须随提案一起传递，因为确认阶段会重新装配输入并比对 `inputHash`
  /// （`PlanApplicationService.apply`）。若重放时缺少同一个一次性覆盖，
  /// 重新算出的哈希必然与提案不同，一个本来合法的恢复提案会被判为"已过期"而无法应用。
  /// 引擎自身从不设置该字段，它由组合输入的应用层（`PlanningService`）附加。
  final ScheduleRuleOverride? ruleOverride;

  /// 生成该提案时用户提出的**延后要求**；没有调整意图时为 null（用户第 72 轮）。
  ///
  /// 必须随提案一起走：调整意图在生成结束后就被清掉
  /// （规范 §11.3 最后一段"请求不能跨过两次生成"），而**应用前还要再校验一次**，
  /// 否则"用户要求延后 30 分钟"这件事在确认阶段就无从得知了。
  ///
  /// 引擎自身从不设置该字段，它由组合输入的应用层（`PlanningService`）附加。
  final AdjustmentRequirement? adjustmentRequirement;

  ScheduleProposal withRuleOverride(ScheduleRuleOverride? override) =>
      ScheduleProposal(
        proposalId: proposalId,
        inputHash: inputHash,
        algorithmVersion: algorithmVersion,
        planningWindow: planningWindow,
        blocks: blocks,
        unscheduled: unscheduled,
        conflicts: conflicts,
        explanations: explanations,
        metrics: metrics,
        ruleOverride: override,
        adjustmentRequirement: adjustmentRequirement,
      );

  /// 附加本次延后要求（用户第 72 轮）。
  ScheduleProposal withAdjustmentRequirement(AdjustmentRequirement? value) =>
      ScheduleProposal(
        proposalId: proposalId,
        inputHash: inputHash,
        algorithmVersion: algorithmVersion,
        planningWindow: planningWindow,
        blocks: blocks,
        unscheduled: unscheduled,
        conflicts: conflicts,
        explanations: explanations,
        metrics: metrics,
        ruleOverride: ruleOverride,
        adjustmentRequirement: value,
      );

  /// 换一份块集合，其余原样（1.8.0，裁定第 1、4 点；设计 §5.2）。
  ///
  /// 用于"生成**之后**建立来源关联"：`linkBlockProvenance` 只给块补上
  /// `continuedFromId`，不改位置也不改 id，因此其余字段（未安排、冲突、指标、
  /// 规则覆盖）逐值不变。
  ScheduleProposal withLinkedBlocks(List<PlannedBlock> linked) =>
      ScheduleProposal(
        proposalId: proposalId,
        inputHash: inputHash,
        algorithmVersion: algorithmVersion,
        planningWindow: planningWindow,
        blocks: linked,
        unscheduled: unscheduled,
        conflicts: conflicts,
        explanations: explanations,
        metrics: metrics,
        ruleOverride: ruleOverride,
      );
}
