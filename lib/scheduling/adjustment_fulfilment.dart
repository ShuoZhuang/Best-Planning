import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 一次延后调整的**要求**：用户点"延后 N 分钟"时系统对结果的承诺。
///
/// 它必须随提案一起走（而不是从 `PendingMoveDrafts` 现取）：
/// 调整意图在生成结束后就被清掉（规范 §11.3 最后一段"请求不能跨过两次生成"），
/// 而**应用前还要再校验一次**，因此要求必须随提案携带。
final class AdjustmentRequirement {
  const AdjustmentRequirement({
    required this.targetBlockId,
    required this.notBeforeUtc,
    required this.requiredMinutes,
    required this.originalStartUtc,
  });

  /// 用户在**确认计划**里延后的那一块。
  final String targetBlockId;

  /// 新开始时间必须**不早于**这个时刻（§11.2：下界，不是精确点）。
  final DateTime notBeforeUtc;

  /// 延后前后的总时长必须一致（拆分后各片段合计也要一致）。
  final int requiredMinutes;

  /// 原位置。用于"原计划块必须已经离开原位置"这一条。
  final DateTime originalStartUtc;
}

/// 调整要求的兑现结果。`unsatisfiedReason == null` 表示**已兑现**。
final class AdjustmentFulfilment {
  const AdjustmentFulfilment._(this.unsatisfiedReason);

  const AdjustmentFulfilment.fulfilled() : this._(null);

  const AdjustmentFulfilment.unsatisfied(String reason) : this._(reason);

  /// 未兑现的原因；`null` 表示已兑现。
  final String? unsatisfiedReason;

  bool get isFulfilled => unsatisfiedReason == null;
}

/// **只针对当前调整请求**判断它有没有被兑现（用户第 72 轮）。
///
/// **为什么不看 `unscheduled`**：部分计划本来就可能包含未安排任务，
/// 因为**别的**任务没排进去就阻止应用是错的（用户第 4 条）。
/// 这里的每一条都只关于**被延后的那一块**。
///
/// 判定项（用户第 1 条的四项 + 拆分合计）：
/// 1. 原计划块**已经离开原位置**（还在原位 = "保持原位置却显示成功"）；
/// 2. 新开始时间**不早于** [AdjustmentRequirement.notBeforeUtc]；
/// 3. 延后前后**总时长一致**（拆分成多段时，各片段合计一致）；
/// 4. **没有重复块**；
/// 5. **没有遗留在下界之前的片段**。
///
/// [taskId] 是目标块所属任务：拆分后目标块的 id 可能不再出现，
/// 因此"这一块去哪了"要按**任务**找，而不是按块 id 找。
AdjustmentFulfilment evaluateAdjustmentFulfilment({
  required AdjustmentRequirement requirement,
  required String taskId,
  required Iterable<PlannedBlock> proposalBlocks,
}) {
  final blocks = proposalBlocks.toList();

  // ④ 没有重复块。
  final ids = blocks.map((block) => block.id).toList();
  if (ids.toSet().length != ids.length) {
    return const AdjustmentFulfilment.unsatisfied('方案里存在重复的计划块');
  }

  final taskBlocks = [
    for (final block in blocks)
      if (block.taskId == taskId) block,
  ];

  // ① 原计划块必须已经离开原位置。
  //
  // 判据是"**没有任何块的开始时刻等于原位置**"，而不是"目标块 id 还在不在"：
  // 拆分之后 id 会变（引擎重排），按 id 判会误报。
  final stillAtOriginal = taskBlocks.where(
    (block) => block.startUtc == requirement.originalStartUtc,
  );
  if (stillAtOriginal.isNotEmpty) {
    return const AdjustmentFulfilment.unsatisfied('目标块仍停留在原位置');
  }

  // ⑤ 不得有片段落在下界之前。
  final beforeBound = taskBlocks.where(
    (block) => block.startUtc.isBefore(requirement.notBeforeUtc),
  );
  if (beforeBound.isNotEmpty) {
    return const AdjustmentFulfilment.unsatisfied('目标块被排在要求时间之前');
  }

  // ③ 总时长一致（拆分时各片段合计一致）。
  final total = taskBlocks.fold<int>(
    0,
    (sum, block) => sum + block.durationMinutes,
  );
  if (total != requirement.requiredMinutes) {
    return AdjustmentFulfilment.unsatisfied(
      '延后前后时长不一致（要求 ${requirement.requiredMinutes} 分钟，'
      '实际 $total 分钟）',
    );
  }

  // ② 新开始时间不早于下界 —— 已由 ⑤ 覆盖（任务的第一块就在下界之后）。
  // 这里额外确认"任务确实有块"，否则总时长为 0 的检查会先命中 ③。
  if (taskBlocks.isEmpty) {
    return const AdjustmentFulfilment.unsatisfied('延后后没有足够的可用时间');
  }

  return const AdjustmentFulfilment.fulfilled();
}
