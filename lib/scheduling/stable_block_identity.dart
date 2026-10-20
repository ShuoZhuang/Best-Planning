import 'dart:collection';

import 'package:personal_planner/scheduling/schedule_problem.dart';

/// **不可移动的基线块**（计划 Task 13 Step 2、DFR-042）。
///
/// 把"哪些块必须在调整中原样保留"抽成一个纯函数，而不是散在装配流程的
/// `if` 里：散着写时，目标块常常被顺带冻回原位，于是"延后"看起来成功、
/// 实际什么都没动（DFR-035）。
///
/// 冻结条件（任一成立）：
/// - 用户锁定（`locked`）；
/// - 已经有执行开始证据；
/// - 已经结束或正在进行（`startUtc <= nowUtc`），即"已经发生的事实"。
///
/// **目标块永远被排除**：它是本次要移动的那一块。把它冻结在原地会让
/// 回退路径"原地成功"。
Set<String> computeFrozenBlockIds({
  required Iterable<PlannedBlock> baselineBlocks,
  required String targetBlockId,
  required DateTime nowUtc,
  required Set<String> executionStartedBlockIds,
}) {
  if (!nowUtc.isUtc) {
    throw ArgumentError.value(nowUtc, 'nowUtc', 'Must be UTC.');
  }
  final frozen = <String>{};
  for (final block in baselineBlocks) {
    if (block.id == targetBlockId) continue;
    if (block.locked ||
        executionStartedBlockIds.contains(block.id) ||
        !block.startUtc.isAfter(nowUtc)) {
      frozen.add(block.id);
    }
  }
  return UnmodifiableSetView(frozen);
}

/// **软稳定**的基线块：未锁定、未开始、仍在未来的块。
///
/// 它们**不是**硬冻结：调整允许移动它们来为目标让路，但"少动块"的评分会
/// 优先保留原位。与 [computeFrozenBlockIds] 分开，是为了不把"希望稳定"
/// 误称为"不许移动"（DFR-042）。
Set<String> computeReferenceBlockIds({
  required Iterable<PlannedBlock> baselineBlocks,
  required String targetBlockId,
  required DateTime nowUtc,
  required Set<String> executionStartedBlockIds,
}) {
  final frozen = computeFrozenBlockIds(
    baselineBlocks: baselineBlocks,
    targetBlockId: targetBlockId,
    nowUtc: nowUtc,
    executionStartedBlockIds: executionStartedBlockIds,
  );
  return UnmodifiableSetView({
    for (final block in baselineBlocks)
      if (block.id != targetBlockId && !frozen.contains(block.id)) block.id,
  });
}
