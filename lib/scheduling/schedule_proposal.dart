import 'dart:collection';

import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/task_placement_diagnostics.dart';

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
  ///
  /// **只有在证据数字存在且确实不足时才允许使用**：
  /// `availableMinutes != null && availableMinutes < requiredMinutes`。
  /// 空证据不得落到这一条（见 [unexplainedSchedulingFailure]）。
  insufficientCapacity,

  /// **排程没有使用仍可用的合法时段**（1.8.0，「可见空闲却报容量不足」专项 §2.4）。
  ///
  /// 使用条件（三者同时成立）：
  /// 1. 任务**存在**可放置容量（`remainingPlaceableMinutes > 0`）；
  /// 2. 最终仍有缺口；
  /// 3. 已收集的硬约束证据**不能解释**这项缺口（没有任何候选被硬约束明确拒绝，
  ///    或证据的数字与缺口对不上）。
  ///
  /// **它不是"容量不足"**：用户要做的不是腾时间，而是重新生成计划并把问题报上来。
  /// 它同时是一个**阻断**问题（见 `ConflictCode.schedulingInvariantViolation`）：
  /// 一个排程器解释不了的零安排，不该被写进用户的计划里。
  unexplainedSchedulingFailure,
}

/// 一条拒绝证据：**哪条约束**挡住了这次放置，附上可判定的数字（计划 §2.4）。
///
/// ## 三个数字的分工（这是本类型存在的全部理由）
///
/// | 字段 | 含义 | 用户看到的形态 |
/// | --- | --- | --- |
/// | [placementRemainingMinutes] | **本次放置的剩余量**，恒等于 `UnscheduledTask.shortageMinutes` | 标题里的"还缺 N 分钟" |
/// | [constraintRequiredMinutes] | **某一条约束**要求的连续／最小／每日分钟 | 正文里的"要求 N 分钟" |
/// | [constraintAvailableMinutes] | **同一约束口径下**的可用分钟 | 正文里的"只有 N 分钟" |
///
/// **后两个数字不是总缺口**，因此界面**不得**再计算
/// `constraintRequiredMinutes − constraintAvailableMinutes` 并称之为"还缺"：
/// 那会造出第二个与标题矛盾的缺口数字，而用户没有任何依据判断哪一个是真的
/// （R7 实测：标题"还缺 25 分钟"与正文"还缺 130 分钟"同时出现）。
/// **"还缺多少"只显示 [placementRemainingMinutes]**（经 `UnscheduledTask.shortageMinutes`）。
///
/// ## 不变量
///
/// ```text
/// placementRemainingMinutes == UnscheduledTask.shortageMinutes
/// ```
///
/// 因此引擎必须**在构造每一条原因时**就把当轮的剩余量写进去，而不是事后补——
/// 事后补会让这条不变量在"原因来自嵌套构造"的路径上悄悄失效。
///
/// 两个 constraint 数字允许为空：不是每条原因都有它们
/// （例如"还没到最早开始时间"没有"需要多长"的概念）。**有数就带上**：
/// 预览要靠它写出"最短片段要求 30 分钟，当前最长合法空档 20 分钟"这种用户能据以行动的句子。
final class UnscheduledReason {
  const UnscheduledReason({
    required this.code,
    required this.placementRemainingMinutes,
    this.constraintRequiredMinutes,
    this.constraintAvailableMinutes,
    this.constraintLabel,
  });

  final UnscheduledReasonCode code;

  /// 见类型文档：它恒等于 `UnscheduledTask.shortageMinutes`。
  final int placementRemainingMinutes;

  /// 某一条**约束**要求的值（连续时长／最小片段／每日上限），不是总缺口。
  final int? constraintRequiredMinutes;

  /// 同一约束口径下的可用值，不是总缺口。
  final int? constraintAvailableMinutes;

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
  // **无法解释排在容量不足之前**：前者是"引擎自己没排好"（要重新生成并报诊断），
  // 后者是"确实没地方了"（要腾时间）。把前者说成后者会让用户白腾时间，
  // 而真正的问题（排程异常）继续留在产品里。
  UnscheduledReasonCode.unexplainedSchedulingFailure,
  UnscheduledReasonCode.insufficientCapacity,
];

/// 按 [unscheduledReasonPriority] 选主原因。
///
/// **没有证据时不再回落"可用时间不足"**（1.8.0 专项 §2.4）：
/// 空证据只说明"引擎收集不到任何可判定的约束证据"，那正是
/// [UnscheduledReasonCode.unexplainedSchedulingFailure] 的定义。
///
/// 修复前这里回落 `insufficientCapacity`，而它**不带任何数字**——用户看到的是
/// 一句无法行动、也无法被测试证伪的"可用时间不足"。这与
/// "引擎不得在没有 `availableMinutes` 或其它可判定证据时，把默认原因写成可用时间不足"
/// （Global Constraints）直接冲突。
UnscheduledReason primaryUnscheduledReason(List<UnscheduledReason> reasons) {
  if (reasons.isEmpty) {
    return const UnscheduledReason(
      code: UnscheduledReasonCode.unexplainedSchedulingFailure,
      placementRemainingMinutes: 0,
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
      code: UnscheduledReasonCode.unexplainedSchedulingFailure,
      // **契约占位值**：真实提案里的 [primaryReason] 必须由引擎按最终缺口构造，
      // 使 `placementRemainingMinutes == shortageMinutes`（见 `UnscheduledReason` 的不变量）。
      placementRemainingMinutes: 0,
    ),
    this.reasons = const [],
  });
  final String taskId;
  final int shortageMinutes;

  /// 用户看到的**那一条**原因。
  ///
  /// **默认值刻意是 [UnscheduledReasonCode.unexplainedSchedulingFailure] 而不是
  /// `insufficientCapacity`**（1.8.0 专项 §2.4）：没有任何证据的缺口不是"可用时间不足"，
  /// 而是"排程结果无法解释"。默认成容量不足会把每一次引擎故障都伪装成用户该腾时间。
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
    Map<String, TaskPlacementDiagnostics> placementDiagnostics = const {},
    this.ruleOverride,
    this.adjustmentRequirement,
  }) : blocks = UnmodifiableListView(List.of(blocks)),
       unscheduled = UnmodifiableListView(List.of(unscheduled)),
       conflicts = UnmodifiableListView(List.of(conflicts)),
       explanations = UnmodifiableListView(List.of(explanations)),
       placementDiagnostics = UnmodifiableMapView(Map.of(placementDiagnostics));

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

  /// 每件有缺口任务的**最终放置诊断**（计划 §2.3）。
  ///
  /// **为什么必须随提案走**：诊断是"这段可见空档为什么用不上"的**唯一**事实源，
  /// 而它由引擎在最终块集合上算出。若只留在引擎的局部变量里，预览层就只能**重新猜**
  /// 一遍原因（那正是 R5／R6 的形态：原因取自旧轮次或与最终块不一致），
  /// 或者干脆不给证据——用户盯着日历上的空白，页面却说不出它为什么空着（U4）。
  ///
  /// **它只进内存提案**：不写日志、不写遥测、不进数据库、不参与 `inputHash`。
  /// 因此 `with*` 方法**原样传递**这份数据——它们是"同一份结果换个包装",不是新结果。
  final Map<String, TaskPlacementDiagnostics> placementDiagnostics;

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
        placementDiagnostics: placementDiagnostics,
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
        placementDiagnostics: placementDiagnostics,
        ruleOverride: ruleOverride,
        adjustmentRequirement: value,
      );

  /// 换一份块集合，其余原样（1.8.0，裁定第 1、4 点；设计 §5.2）。
  ///
  /// 用于"生成**之后**建立来源关联"：`linkBlockProvenance` 只给块补上
  /// `continuedFromId`，不改位置也不改 id，因此其余字段（未安排、冲突、指标、
  /// 规则覆盖、**延后要求**）逐值不变。
  ///
  /// **`adjustmentRequirement` 必须显式带过去**：它此前被漏在这里，而 `withRuleOverride`
  /// 与 `withAdjustmentRequirement` 都传了。当时的调用链（`PlanningService.createProposal`）
  /// 恰好把 `withAdjustmentRequirement` 排在 `withLinkedBlocks` **之后**、且那一刻该字段
  /// 本来就是 `null`，所以生产路径没有被咬到——但这是一个"只要有人调整那三行的顺序、
  /// 或在带要求的提案上再关联一次来源，就会静默丢掉用户延后要求"的陷阱，而丢掉的后果是
  /// 应用前那次兑现校验拿不到要求（`PlanApplicationService` 会以为"这次没有延后意图"）。
  /// 三个 `with*` 现在对它的处理完全一致。
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
        placementDiagnostics: placementDiagnostics,
        ruleOverride: ruleOverride,
        adjustmentRequirement: adjustmentRequirement,
      );
}
