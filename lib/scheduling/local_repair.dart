import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 一次**最小改动局部修复**的结果（1.8.0，设计规范 §11.4）。
///
/// **它只回答"这一份候选动了多少"**，不携带参照位置：参照是"跟谁比"，
/// 属于比较的输入，不属于结果本身。第一版把参照塞进结果里（`withReference`），
/// 于是同一个对象在不同调用点算出的位移不同——测试当场抓到
/// `Expected: <30> Actual: <0>`，因为直接构造的结果没有参照。
/// 现在参照一律走显式参数。
final class LocalRepairPlan {
  LocalRepairPlan({required this.blocks, required this.movedBlockIds});

  /// 修复之后的块集合。**只包含输入里给出的那些块**——这个规划器从不新增或删除块。
  final List<PlannedBlock> blocks;

  /// 相对参照位置**发生了变化**的块 id。
  ///
  /// 规范 §11.4 第 3 条"移动的其他块数量最少"数的就是它的大小。
  final Set<String> movedBlockIds;

  /// 规范 §11.4 的字典序比较：**前一项相同时才比较后一项**。
  ///
  /// 顺序（第 1、2 条是硬约束，由生成阶段的可行性保证，不在这里比较）：
  /// 1. 移动的其他块数量最少；
  /// 2. 所有被移动块的总位移分钟最少；
  /// 3. 目标块距离 `notBeforeUtc` 最近；
  /// 4. 全部相同时按块签名——**保证顺序确定**，否则同一次输入会产生两份不同提案，
  ///    而"应用哪一份"取决于内存里的哈希顺序。
  ///
  /// 返回负数表示 [a] 更优。
  static int compare(
    LocalRepairPlan a,
    LocalRepairPlan b, {
    required Map<String, DateTime> reference,
    required String targetBlockId,
    required DateTime notBeforeUtc,
  }) {
    final byCount = a.movedBlockIds.length.compareTo(b.movedBlockIds.length);
    if (byCount != 0) return byCount;

    final byMinutes = localRepairDisplacementMinutes(
      a,
      reference,
    ).compareTo(localRepairDisplacementMinutes(b, reference));
    if (byMinutes != 0) return byMinutes;

    final byTarget = _targetDistance(
      a,
      targetBlockId,
      notBeforeUtc,
    ).compareTo(_targetDistance(b, targetBlockId, notBeforeUtc));
    if (byTarget != 0) return byTarget;

    return _signature(a).compareTo(_signature(b));
  }

  /// 目标块开始时刻距离 [notBeforeUtc] 的分钟数。
  ///
  /// **目标块在结果里必须存在**：找不到时返回一个很大的值——那是"这一份候选没有把目标块
  /// 放进去"，属于实现缺陷；排在最后而不是抛异常，是为了让缺陷表现为"选了别的方案"
  /// 而不是让整个生成崩掉。
  static int _targetDistance(
    LocalRepairPlan plan,
    String targetBlockId,
    DateTime notBeforeUtc,
  ) {
    for (final block in plan.blocks) {
      if (block.id != targetBlockId) continue;
      final delta = block.startUtc.difference(notBeforeUtc).inMinutes;
      // **早于下界要被罚**：规范第 2 条是硬约束（目标块不早于 `notBeforeUtc`），
      // 但比较器仍要能分辨两份都违反它的候选——加一个大常数让它们排在有遵守下界的候选之后。
      return delta < 0 ? -delta + 100000 : delta;
    }
    return 1 << 30;
  }

  static String _signature(LocalRepairPlan plan) {
    final entries = [...plan.blocks]..sort((a, b) => a.id.compareTo(b.id));
    return entries
        .map((block) => '${block.id}@${block.startUtc.microsecondsSinceEpoch}')
        .join(',');
  }
}

/// 相对 [reference] 的**总位移分钟**（规范 §11.4 第 4 条）。
///
/// 只统计**两边都有**的块：参照里没有的块是"新排进来的"，它的位移无从谈起——
/// 把它算成"位移等于整块时长"会让首次排程看起来像一次巨大的改动。
int localRepairDisplacementMinutes(
  LocalRepairPlan plan,
  Map<String, DateTime> reference,
) {
  var total = 0;
  for (final block in plan.blocks) {
    final before = reference[block.id];
    if (before == null) continue;
    total += block.startUtc.difference(before).inMinutes.abs();
  }
  return total;
}
