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
/// **为什么不按任务求和**（用户第 73 轮）：一个任务本来就可能被拆成多块，
/// 只延后其中一块时，按任务求和会把兄弟块的时长算进来，
/// 既会**误判为未兑现**（sum ≠ 该块时长），也会让兄弟块把总时长"补"够而
/// **漏放**真的没兑现的方案。因此只认**目标块的延续者**：
/// 提案里 `id == targetBlockId` 或 `continuedFromId == targetBlockId` 的那些块。
///
/// 判定项（用户第 1 条的四项 + 拆分合计）：
/// 1. 目标块**已经离开原位置**（还在原位 = "保持原位置却显示成功"）；
/// 2. 延续者的开始时间**不早于** [AdjustmentRequirement.notBeforeUtc]；
/// 3. 延后前后**总时长一致**（拆分成多段时，各片段合计一致）；
/// 4. **没有重复块**；
/// 5. **没有遗留在下界之前的片段**。
AdjustmentFulfilment evaluateAdjustmentFulfilment({
  required AdjustmentRequirement requirement,
  required Iterable<PlannedBlock> proposalBlocks,
}) {
  final blocks = proposalBlocks.toList();

  // ④ 没有重复块。
  final ids = blocks.map((block) => block.id).toList();
  if (ids.toSet().length != ids.length) {
    return const AdjustmentFulfilment.unsatisfied('方案里存在重复的计划块');
  }

  // **只看被延后那一块的延续者**（用户第 73 轮）。
  //
  // 修复前这里取的是"同一任务的所有块"，而 `requiredMinutes` 是**那一块**的时长 ——
  // 一个任务本来就被拆成多块时，只延后其中一块就会算出
  // `sum(所有块) != 该块时长`，于是**误判为未兑现并禁止应用**；
  // 反过来，兄弟块还会把总时长"补"够，让**真的**没兑现的方案被判为已兑现。
  //
  // 延续关系由来源关联给出（裁定第 1、4 点）：
  //   · 未被拆分 ⇒ 提案里就是原 id；
  //   · 被拆分 ⇒ 各片段带 `continuedFromId == 目标块 id`；
  //   · 被级联接管的块 ⇒ 也保留原 id。
  //
  // **注意 `continuedFromId` 指向的是"目标块在确认计划里的 id"**，
  // 因此这里按 `requirement.targetBlockId` 匹配，而不是按任务匹配。
  final targetLineage = [
    for (final block in blocks)
      if (block.id == requirement.targetBlockId ||
          block.continuedFromId == requirement.targetBlockId)
        block,
  ];

  // ① 原计划块必须已经离开原位置。
  //
  // 判据是"**目标块的延续者里没有任何一个**仍停在原位置"。
  // 只看延续者而不是"整个任务"：同任务的兄弟块本来就可能在别处，
  // 那不是本次延后该管的事。
  final stillAtOriginal = targetLineage.where(
    (block) => block.startUtc == requirement.originalStartUtc,
  );
  if (stillAtOriginal.isNotEmpty) {
    return const AdjustmentFulfilment.unsatisfied('目标块仍停留在原位置');
  }

  // ⑤ 不得有片段落在下界之前。
  final beforeBound = targetLineage.where(
    (block) => block.startUtc.isBefore(requirement.notBeforeUtc),
  );
  if (beforeBound.isNotEmpty) {
    return const AdjustmentFulfilment.unsatisfied('目标块被排在要求时间之前');
  }

  // ③ 总时长一致（拆分时**各片段合计**一致）—— 只算延续者。
  final targetMinutes = targetLineage.fold<int>(
    0,
    (sum, block) => sum + block.durationMinutes,
  );
  if (targetMinutes != requirement.requiredMinutes) {
    return AdjustmentFulfilment.unsatisfied(
      '延后前后时长不一致（要求 ${requirement.requiredMinutes} 分钟，'
      '实际 $targetMinutes 分钟）',
    );
  }

  // ② 新开始时间不早于下界 —— 已由 ⑤ 覆盖（延续者的每一段都在下界之后）。
  // 这里额外确认"延续者确实存在"，否则会被上面 ③ 的时长比较先拦下（0 ≠ 要求）。
  if (targetLineage.isEmpty) {
    return const AdjustmentFulfilment.unsatisfied('延后后没有足够的可用时间');
  }

  return const AdjustmentFulfilment.fulfilled();
}
