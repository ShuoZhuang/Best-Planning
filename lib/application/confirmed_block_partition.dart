import 'dart:collection';

import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 一个**已确认块**在"本次排程输入"里扮演的角色（1.8.0，用户第 70 轮）。
///
/// **为什么需要显式角色**：第 67 轮的缺陷形态不是"某个集合算错"，
/// 而是**同一个块同时进入了 `lockedBlocks`、冻结集合与 `existingBlocks`** ——
/// 最终提案里同一个 ID 出现两次，用户会在日程里看到两份相同安排。
///
/// 把角色显式化之后，"一个 ID 只能有一个角色"变成**可断言**的性质，
/// 而不是靠几段 `if` 条件各自小心。
enum ConfirmedBlockRole {
  /// 不该进入本次输入：被跳过，或它所属的任务不参与排程。
  excluded,

  /// **已经结束**的块：`block.endUtc <= planningWindowStartUtc`。
  ///
  /// **它与 `hardOccupied` 不是一回事**（1.8.0，2026-10-12 实机故障；冻结决策 §1.3）：
  /// 硬占用是"这一块要占位、别动"，历史块是"这一块**根本不进入本次排程输入**"。
  /// 把它当成硬占用正是故障的根因 —— 装配层会把**全部** `hardOccupiedIds` 放进
  /// `lockedBlocks`，于是昨天的块进了提案（用户看到"新增 10-10、10-11"），
  /// 引擎又把它计入 `scheduledByTask`（历史安排污染"这次还剩多少"），
  /// 最后 `PlanValidator` 因为它的开始不在规划窗口内再报一次"排程输入无效"。
  ///
  /// **历史不会因此丢失**：过去日期的展示由 `PlanBlockHistory.blocksInWindow()`
  /// 从旧计划版本读出（见 `test/data/plan_block_history_test.dart`）。
  historical,

  /// 硬占用：锁定块与**正在进行**的块。它们只占位，不被移动。
  hardOccupied,

  /// 被拖动钉住的块：用拖动后的**替换结果**，原位置不再参与。
  replacedByPin,

  /// 本次调整的目标块：用级联算出的**替换结果**，原位置不再参与。
  replacedByAdjustment,

  /// 给目标块让路、位置被挤开的块：用**替换结果**，原位置不再参与。
  displaced,

  /// 未被本次调整碰到的可移动块：**原位冻结**（§11.4 第 3、4 条"最小改动"）。
  frozen,

  /// 引擎可以移动、但要付出移动代价的块（设计 §5.4）。
  existing,
}

/// [classifyConfirmedBlocks] 的结果：**互斥分区**。
///
/// "互斥"是构造保证：`_roleById` 每个 ID 只有一个条目，
/// 各集合都由它派生，因此不可能出现"同一块既冻结又可移动"。
final class ConfirmedBlockPartition {
  const ConfirmedBlockPartition(this._roleById);

  final Map<String, ConfirmedBlockRole> _roleById;

  /// 某个确认块 ID 的全部角色。**正常情况下长度恒为 1**
  /// （或者 0：该块没进本次输入）。断言 `hasLength(1)` 就是在验互斥。
  List<ConfirmedBlockRole> categoriesFor(String blockId) => [
    ?_roleById[blockId],
  ];

  /// 全部已分类的 ID（含重复项，供"互斥"断言使用）。
  ///
  /// 因为底层是 Map，这里天然不重复；保留这个 getter 是为了让
  /// `all.length == all.toSet().length` 这类断言在实现变化时**仍然有意义**
  /// （若将来改成多集合派生，重叠会立刻暴露）。
  List<String> get allCategoryIds => _roleById.keys.toList();

  Set<String> get frozenIds => _idsWithRole(ConfirmedBlockRole.frozen);
  Set<String> get existingIds => _idsWithRole(ConfirmedBlockRole.existing);
  Set<String> get hardOccupiedIds =>
      _idsWithRole(ConfirmedBlockRole.hardOccupied);

  /// **已经结束**的块。它们**不进入任何未来集合**（见 [ConfirmedBlockRole.historical]）。
  Set<String> get historicalIds => _idsWithRole(ConfirmedBlockRole.historical);
  Set<String> get excludedIds => _idsWithRole(ConfirmedBlockRole.excluded);

  /// 由调整路径**接管**的块：钉住／目标／被挤开／冻结。
  ///
  /// 它们不再以原位置出现在可移动集合里，否则引擎会把它们当参考位置放回去。
  Set<String> get takenOverIds => {
    ..._idsWithRole(ConfirmedBlockRole.replacedByPin),
    ..._idsWithRole(ConfirmedBlockRole.replacedByAdjustment),
    ..._idsWithRole(ConfirmedBlockRole.displaced),
    ...frozenIds,
  };

  Set<String> _idsWithRole(ConfirmedBlockRole role) => {
    for (final entry in _roleById.entries)
      if (entry.value == role) entry.key,
  };
}

/// 把确认块**互斥地**分到各自的角色（1.8.0，用户第 70 轮）。
///
/// **它是纯函数**：不读时钟、不碰仓库、不看引擎，输入全部由参数给出。
/// 因此"分类是否正确"可以被直接断言，而不必穿透整条装配链。
///
/// 判定优先级（先到先得，**每个 ID 只会被分配一次**）：
///
/// 1. `excluded`：被跳过，或任务不在 [schedulableTaskIds] 里；
/// 2. `replacedByPin`：[pinnedBlockIds] 或 [lockedOverlayIds]（拖动后的替换结果）；
/// 3. `replacedByAdjustment`：[adjustedTargetId]；
/// 4. `displaced`：[displacedIds]；
/// 5. `historical`：`block.endUtc <= planningWindowStartUtc`（**已经结束**）；
/// 6. `hardOccupied`：`block.locked`，或块**跨过**窗口起点（`start < 起点 < end`）；
/// 7. `frozen`：**仅当 [adjustedTargetId] 非空**（即局部修复成功）时，
///    未被接管的可移动块；
/// 8. `existing`：其余可移动块。
///
/// **第 6、5 条的顺序是有意的**：锁定块即使"未被接管"也只能是 `hardOccupied`，
/// 绝不能再落到 `frozen` —— 那正是第 67 轮重复的成因。
///
/// **第 7 条的前置条件同样是有意的**：局部修复失败时（[adjustedTargetId] 为空）
/// `frozen` **必须为空**，可移动块回到 `existing` 交回引擎。
/// 否则目标块会被冻在原位，用户点了延后却什么都没变。
///
/// **第 5、6 条是本轮（2026-10-12）新增的边界**，半开区间规则是冻结决策：
/// - `end == 起点` ⇒ `historical`（**恰好在窗口起点结束的块属于历史**）；
/// - `start == 起点` ⇒ 既不是历史、也不跨过起点 ⇒ 落到 `frozen`/`existing`（**属于未来**）；
/// - `start < 起点 < end` ⇒ `hardOccupied`（**进行中，原位且不可移动**）。
///
/// 用 `<=` / `>` 的组合而不是 `isBefore`：后者会在端点上留出一条缝隙，
/// 而"恰好在现在结束"与"恰好在现在开始"必须分属两侧、不得同时缺席。
///
/// **参数名是 [planningWindowStartUtc] 而不是 `nowUtc`**：这条边界与
/// `ScheduleProblem.planningWindow.startUtc` 是**同一个**时刻，两个名字会让人
/// 以为存在两个"现在"（而本批次已经有过"同一件事在两层各算一次"的教训）。
ConfirmedBlockPartition classifyConfirmedBlocks({
  required Iterable<PlannedBlock> confirmed,
  required Set<String> schedulableTaskIds,
  required Set<String> skippedBlockIds,
  Set<String> pinnedBlockIds = const {},
  Set<String> lockedOverlayIds = const {},
  bool adjustmentRequested = false,
  String? adjustedTargetId,
  Set<String> displacedIds = const {},
  required DateTime planningWindowStartUtc,
}) {
  final roleById = <String, ConfirmedBlockRole>{};

  /// 分配角色；**已经被分配过的 ID 直接跳过**（互斥的机制保证）。
  void assign(String id, ConfirmedBlockRole role) =>
      roleById.putIfAbsent(id, () => role);

  for (final block in confirmed) {
    // ① 排除：被跳过，或任务不参与排程。
    if (skippedBlockIds.contains(block.id) ||
        !schedulableTaskIds.contains(block.taskId)) {
      assign(block.id, ConfirmedBlockRole.excluded);
      continue;
    }
    // ② 钉住（拖动后选择"不锁定"）：用替换结果。
    if (pinnedBlockIds.contains(block.id) ||
        lockedOverlayIds.contains(block.id)) {
      assign(block.id, ConfirmedBlockRole.replacedByPin);
      continue;
    }
    // ③ 本次调整的目标：用级联算出的替换结果。
    if (block.id == adjustedTargetId) {
      assign(block.id, ConfirmedBlockRole.replacedByAdjustment);
      continue;
    }
    // ④ 给目标让路、被挤开的块：用替换结果。
    if (displacedIds.contains(block.id)) {
      assign(block.id, ConfirmedBlockRole.displaced);
      continue;
    }
    // ⑤ **已经结束**：不进入本次排程输入（它既不是障碍，也不是可移动块）。
    if (!block.endUtc.isAfter(planningWindowStartUtc)) {
      assign(block.id, ConfirmedBlockRole.historical);
      continue;
    }
    // ⑥ 硬占用：锁定块，或**跨过窗口起点**的进行中块（位置冻结、只占位）。
    if (block.locked ||
        (block.startUtc.isBefore(planningWindowStartUtc) &&
            block.endUtc.isAfter(planningWindowStartUtc))) {
      assign(block.id, ConfirmedBlockRole.hardOccupied);
      continue;
    }
    // ⑦ 原位冻结：**只在局部修复成功时**。
    if (adjustmentRequested && adjustedTargetId != null) {
      assign(block.id, ConfirmedBlockRole.frozen);
      continue;
    }
    // ⑧ 其余可移动块：交回引擎。
    assign(block.id, ConfirmedBlockRole.existing);
  }

  return ConfirmedBlockPartition(UnmodifiableMapView(roleById));
}
