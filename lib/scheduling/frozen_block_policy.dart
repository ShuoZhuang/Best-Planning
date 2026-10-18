import 'dart:collection';

import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 计算本次生成中**不可移动**的基线块 ID 集合（规范 §6 / ALG20-037）。
///
/// 六类边界各有一条明确结果：
///
/// | 输入 | 结果 |
/// | --- | --- |
/// | 已执行（`end <= now`） | 冻结 |
/// | 执行中（`start <= now < end`） | 冻结 |
/// | 显式锁定 | 冻结 |
/// | 手动钉住 | 冻结 |
/// | 目标调整块 | **不冻结**（它是本次操作的对象） |
/// | 未锁定未来块 | 可移动 |
///
/// **缺失来源时阻断，不猜测**：`executingBlockIds` / `explicitlyPinnedIds` 中出现
/// 基线里不存在的 ID、或调整目标不在基线里，一律抛 [StateError]。静默忽略会让
/// "用户拖动的那一块"被当成可移动块重排，用户看到的是"拖了没用"。
///
/// 返回顺序稳定（按 ID 升序），因此它可以直接进入确定性签名。
Set<String> computeFrozenBlockIds({
  required List<PlannedBlock> baseline,
  required DateTime nowUtc,
  required Set<String> executingBlockIds,
  required Set<String> explicitlyPinnedIds,
  BlockAdjustmentContext? adjustment,
}) {
  if (!nowUtc.isUtc) {
    throw ArgumentError.value(nowUtc, 'nowUtc', '必须是 UTC 时刻');
  }
  final byId = <String, PlannedBlock>{};
  for (final block in baseline) {
    if (byId.containsKey(block.id)) {
      throw ArgumentError.value(
        block.id,
        'baseline',
        '基线块 ID 重复：同一块不能在一份基线里出现两次',
      );
    }
    byId[block.id] = block;
  }
  final targetId = adjustment?.targetBlockId;
  if (targetId != null && !byId.containsKey(targetId)) {
    throw StateError('调整目标块 $targetId 不在基线里；不得猜测它对应哪一块');
  }
  for (final id in [...executingBlockIds, ...explicitlyPinnedIds]) {
    if (!byId.containsKey(id)) {
      throw StateError('冻结输入引用了基线里不存在的块 $id；不得猜测它对应哪一块');
    }
  }

  final frozen = SplayTreeSet<String>();
  for (final block in byId.values) {
    if (block.id == targetId) continue;
    final elapsed = !block.endUtc.isAfter(nowUtc);
    final executing =
        executingBlockIds.contains(block.id) ||
        (!block.startUtc.isAfter(nowUtc) && block.endUtc.isAfter(nowUtc));
    if (elapsed ||
        executing ||
        block.locked ||
        explicitlyPinnedIds.contains(block.id)) {
      frozen.add(block.id);
    }
  }
  return frozen;
}
