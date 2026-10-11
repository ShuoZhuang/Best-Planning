import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 把**还能回到原位**的块放回原位，从而最小化"被移动的块数"（1.8.0，规范 §11.4 第 3 条）。
///
/// **为什么需要这一步**：引擎的生成是"从零排一遍"，它不知道哪些块**本来就在合适的位置**。
/// 于是用户按一次"延后 30 分钟"，引擎可能顺手把一整天重排一遍——而规范第 3、4 条要的
/// 恰恰是"少动"：先比被移动的块数，再比总位移分钟。
///
/// **算法**：按块 id 排序（顺序必须确定），逐个尝试把它放回
/// `problem.referenceBlocks[id]`。放回**只有在验证器确认无冲突时才接受**，
/// 因此这个步骤**永远不会制造新冲突**：它要么减少改动，要么什么都不做。
///
/// **为什么贪心就够**：把某块放回原位只会让它自己"不再被算作移动"，
/// 不会让任何别的块变成移动。因此"能放回就放回"不可能让结果变差——
/// 每一块的处理都是单调的，且各块之间只通过"原位是否被占"互相影响，
/// 而那个影响由验证器如实判定。
///
/// **不动的东西**：锁定块、没有参照的块（新排进来的）、以及放回会冲突的块。
///
/// 返回的 [LocalRepairPlan.movedBlockIds] 就是规范第 3 条要数的那个集合，
/// 参照由 [LocalRepairPlan.compare] 用来算第 4 条的位移分钟。
LocalRepairPlan minimizeChangedBlocks({
  required ScheduleProblem problem,
  required List<PlannedBlock> blocks,
  required DateTime dayStartUtc,
  required DateTime dayEndUtc,
  PlanValidator? validator,
}) {
  // 不可移动的集合：锁定块，以及**没有参照**的块（新排进来的，没有"调整前"）。
  final immovableIds = {
    for (final block in blocks)
      if (block.locked || !problem.referenceBlocks.containsKey(block.id))
        block.id,
  };

  // 固定占用：锁定的块、固定日程、保护时间。放回原位时不能撞上它们。
  final busy = <TimeRange>[
    for (final block in blocks)
      if (block.locked) block.range,
    for (final interval in problem.fixedIntervals) interval.range,
    for (final interval in problem.protectedIntervals) interval.range,
  ];

  final byId = {for (final block in blocks) block.id: block};
  // **按 id 排序**：顺序不确定会让同一次输入产出两份不同的结果。
  final restorable = [
    for (final entry in problem.referenceBlocks.entries)
      if (byId.containsKey(entry.key) &&
          !immovableIds.contains(entry.key) &&
          byId[entry.key]!.startUtc != entry.value)
        entry,
  ]..sort((a, b) => a.key.compareTo(b.key));

  for (final entry in restorable) {
    final current = byId[entry.key]!;
    final reference = TimeRange(
      startUtc: entry.value,
      endUtc: entry.value.add(Duration(minutes: current.durationMinutes)),
    );
    // ① 必须在规划窗口内。
    if (!problem.planningWindow.contains(reference.startUtc) ||
        reference.endUtc.isAfter(problem.planningWindow.endUtc)) {
      continue;
    }
    // ② 不能撞上固定占用。
    if (busy.any((range) => range.overlaps(reference))) continue;
    // ③ 不能撞上**当前位置上的**别的块。逐个试算，用验证器确认。
    final candidate = PlannedBlock(
      id: current.id,
      taskId: current.taskId,
      range: reference,
      locked: current.locked,
      explanationCode: current.explanationCode,
    );
    final trial = [
      for (final block in byId.values)
        if (block.id == current.id) candidate else block,
    ];
    if ((validator ?? PlanValidator(TimeZoneDatabase()))
        .validate(problem, trial)
        .isNotEmpty) {
      continue;
    }

    // 验证器说没问题 ⇒ 接受。更新工作副本，后续块基于新状态判断。
    byId[entry.key] = candidate;
  }

  return LocalRepairPlan(
    // **保持输入顺序**：预览与其他消费方依赖它。
    blocks: [for (final block in blocks) byId[block.id]!],
    movedBlockIds: {
      for (final block in byId.values)
        if (problem.referenceBlocks[block.id] case final reference?
            when reference != block.startUtc)
          block.id,
    },
  );
}

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

/// 一次**向后级联**的结果（1.8.0，设计规范 §11.4）。
///
/// [feasible] 为 `false` 表示在给定范围内找不到合法方案；调用方应当据此**如实失败**，
/// 而不是拿一份勉强排出来的结果去覆盖已确认的计划（全局不变量第 3 条）。
typedef LocalRepairOutcome = ({
  bool feasible,
  List<PlannedBlock> blocks,
  Map<String, DateTime> reference,
});

/// 把 [targetBlockId] 推到不早于 [notBeforeUtc] 的位置，**并尽量少动别的块**。
///
/// 规范 §11.4 的三条要求：
/// - "**先在当天做向后级联**"——候选位置限制在 `[dayStartUtc, dayEndUtc)` 这一个本地日里；
///   当天放不下就返回 `feasible: false`，由调用方决定是否考虑后续日期；
/// - "**只有未锁定可移动块能被级联**。固定日程、保护时间、睡眠、过去的块和锁定块保持原位"
///   ——[immovable] 里的块是**硬边界**：级联只绕过它们，绝不移走它们；
/// - "**目标块开始时间不早于 `notBeforeUtc`**"——第一个硬约束。
///
/// **算法**：目标块先放到它最早能放的位置，其余可移动块按原开始时刻排序，
/// 各块**先试原位、留不住才往后让**。因此每一块的位置只可能"保持"或"后移"，
/// 不可能前移——前移会连带出别处的缺口，而那正是规范第 3、4 条要避免的。
///
/// **为什么不整体重排**：整体重排能得出"看起来更优"的一天，却往往动了更多块。
/// 规范第 3、4 条要的是**少动**，所以这里只做"让开"这一件事。
///
/// **不制造新缺口**由 §11.4 第 6 条单独负责（`ScoringFactor.unusableGap`），
/// 本函数只保证硬约束与"少动"。
LocalRepairOutcome localRepairCascade({
  required String targetBlockId,
  required DateTime notBeforeUtc,
  required List<PlannedBlock> blocks,
  required List<PlannedBlock> immovable,
  required DateTime dayStartUtc,
  required DateTime dayEndUtc,
  String explanationCode = 'deferred',
}) {
  assert(notBeforeUtc.isUtc && dayStartUtc.isUtc && dayEndUtc.isUtc);

  final target = blocks.where((block) => block.id == targetBlockId).firstOrNull;
  if (target == null) {
    return (feasible: false, blocks: blocks, reference: const {});
  }
  final immovableIds = {for (final block in immovable) block.id};

  /// 当前已被占用的区间：初始是全部不可移动块，之后随放置逐个加入。
  final occupied = <({DateTime start, DateTime end})>[
    for (final block in immovable) (start: block.startUtc, end: block.endUtc),
  ];

  /// [start] 处能否放下 [minutes] 分钟（不越过 `dayEndUtc`、不与 [occupied] 相交）。
  bool fitsAt(DateTime start, int minutes) {
    final end = start.add(Duration(minutes: minutes));
    if (end.isAfter(dayEndUtc)) return false;
    for (final slot in occupied) {
      // 半开区间相交：`start < slot.end && slot.start < end`。
      if (start.isBefore(slot.end) && slot.start.isBefore(end)) return false;
    }
    return true;
  }

  /// 从 [from] 起找第一个能放下 [minutes] 分钟、且不越过 [dayEndUtc] 的位置。
  ///
  /// 每绕过一个障碍就把候选推到该障碍之后，因此循环次数受障碍数约束，
  /// 不会退化成"逐分钟扫描"。
  DateTime? firstFit(DateTime from, int minutes) {
    if (fitsAt(from, minutes)) return from;
    var candidate = from;
    for (var guard = 0; guard <= occupied.length; guard++) {
      final end = candidate.add(Duration(minutes: minutes));
      if (end.isAfter(dayEndUtc)) return null;
      DateTime? blockingEnd;
      for (final slot in occupied) {
        if (candidate.isBefore(slot.end) && slot.start.isBefore(end)) {
          if (blockingEnd == null || slot.end.isAfter(blockingEnd)) {
            blockingEnd = slot.end;
          }
        }
      }
      if (blockingEnd == null) return candidate;
      candidate = blockingEnd;
    }
    return null;
  }

  final earliestStart = notBeforeUtc.isAfter(dayStartUtc)
      ? notBeforeUtc
      : dayStartUtc;
  if (!earliestStart.isBefore(dayEndUtc)) {
    return (feasible: false, blocks: blocks, reference: const {});
  }

  final planned = <PlannedBlock>[];

  /// 放一块并登记占用。
  bool place(PlannedBlock source, DateTime start) {
    final range = TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: source.durationMinutes)),
    );
    if (range.endUtc.isAfter(dayEndUtc)) return false;
    planned.add(
      PlannedBlock(
        id: source.id,
        taskId: source.taskId,
        range: range,
        locked: source.locked,
        explanationCode: source.id == targetBlockId
            ? explanationCode
            : source.explanationCode,
      ),
    );
    occupied.add((start: range.startUtc, end: range.endUtc));
    return true;
  }

  // ① 目标块最先放：它带着下界，是这次调整的全部目的。
  //
  // **它的起点是"原位与下界里更晚的那一个"，不是下界本身。**
  // 用户把 11:00 的块延后 10 分钟、而它的下界是 10:00 时，它**原位就已经满足**要求，
  // 不该被搬到 10:00——那就成了一次"提前"，而"提前属于独立操作"（规范 §11.2）。
  // 第一版直接取下界，测试`让位时绝不前移`当场把它抓出来（期望 11:00，得到 10:00）。
  final targetAnchor = target.startUtc.isAfter(earliestStart)
      ? target.startUtc
      : earliestStart;
  final targetStart = firstFit(targetAnchor, target.durationMinutes);
  if (targetStart == null) {
    return (feasible: false, blocks: blocks, reference: const {});
  }
  place(target, targetStart);

  // ② 其余可移动块：按原开始时刻排序，能留就留，不能留就往右让。
  final movable = [
    for (final block in blocks)
      if (block.id != targetBlockId && !immovableIds.contains(block.id)) block,
  ]..sort((a, b) => a.startUtc.compareTo(b.startUtc));

  for (final block in movable) {
    // **先试原位**：`firstFit(原位)` 若正好返回原位，说明它不用动。
    final anchor = block.startUtc.isBefore(dayStartUtc)
        ? dayStartUtc
        : block.startUtc;
    final start = firstFit(anchor, block.durationMinutes);
    if (start == null) {
      // **当天放不下就如实失败**：跨天这件事不在本函数的职责里。
      return (feasible: false, blocks: blocks, reference: const {});
    }
    place(block, start);
  }

  // ③ 不可移动的块原样带回：位置一个字节都没变。
  planned.addAll(immovable);

  return (
    feasible: true,
    blocks: planned,
    // 参照＝"级联之前每个块的位置"，供 `LocalRepairPlan.compare` 数块数与位移。
    reference: {for (final block in blocks) block.id: block.startUtc},
  );
}
