import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/gap_classifier.dart';
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

    /// 用于第 6、7 级的坏空档分类（§11.4 第 6 条）。
    ///
    /// **必须传进来**：一段间隔算不算"坏空档"取决于**还有哪些任务要排**
    /// （放不下任何一件的最小片段才是坏空档）。少了它就只能用一个全局固定阈值，
    /// 而规范 §12.2／计划 Task 13 Step 1 明确禁止那样做。
    Iterable<SchedulableTask> tasks = const [],

    /// 保护时间与规则休息：覆盖到的间隔归 `intentionalBreak`，**永不计为坏空档**。
    ///
    /// 这是"不得为了减少坏空档缩短休息或覆盖保护时间"这条硬边界在比较层的体现。
    List<TimeRange> protectedRanges = const [],
    int breakMinutes = 0,
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

    // ── 第 6、7 级：坏空档（规范 §11.4 第 6 条／设计 §5.5）─────────────────────
    //
    // 这两级此前**不存在**：`compare` 从第 5 级直接落到稳定签名，
    // 而候选级又实测不可行（任何负权重都吃掉休息），于是第 6 条两头都空。
    //
    // **为什么放在这里而不是候选级**：候选级只能看到**紧邻**的两段缝，
    // 于是引擎会把块往后推以"离开"一段短缝，却在更远处制造更大的缺口。
    // 方案级能看到整天的排布，这才是"这一段空档到底能不能用"的正确层次。
    final gapsA = _orphanGaps(
      a,
      tasks: tasks,
      protectedRanges: protectedRanges,
      breakMinutes: breakMinutes,
    );
    final gapsB = _orphanGaps(
      b,
      tasks: tasks,
      protectedRanges: protectedRanges,
      breakMinutes: breakMinutes,
    );
    final byGapCount = gapsA.count.compareTo(gapsB.count);
    if (byGapCount != 0) return byGapCount;
    final byGapMinutes = gapsA.minutes.compareTo(gapsB.minutes);
    if (byGapMinutes != 0) return byGapMinutes;

    return _signature(a).compareTo(_signature(b));
  }

  /// 一份方案里的坏空档统计：**只数 `orphanGap`**。
  ///
  /// `intentionalBreak`（保护时间／规则休息）与 `freeTime`（没有任务可填、
  /// 或日容量已达上限）都不计——规范 §12.1 末句："系统不能为了'看起来紧凑'
  /// 吞掉保护时间或排满所有自由时间。"
  static ({int count, int minutes}) _orphanGaps(
    LocalRepairPlan plan, {
    required Iterable<SchedulableTask> tasks,
    required List<TimeRange> protectedRanges,
    required int breakMinutes,
  }) {
    // 没有可排任务时"坏空档"这个概念没有意义（分类器会全归 `freeTime`）。
    // 直接返回 0 而不是让分类器替我们兜底：这样"比较用不上这一级"是显式的。
    if (!tasks.any((task) => task.requiredMinutes > 0)) {
      return (count: 0, minutes: 0);
    }
    var count = 0;
    var minutes = 0;
    for (final gap in classifyGaps(
      blocks: plan.blocks,
      tasks: tasks,
      protectedRanges: protectedRanges,
      breakMinutes: breakMinutes,
    )) {
      if (gap.kind != GapKind.orphan) continue;
      count++;
      minutes += gap.minutes;
    }
    return (count: count, minutes: minutes);
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

  /// **目标块的锚点**（设计 §5.5："生成有限、确定的合法方案集合"）。
  ///
  /// 为空时按既有规则取"原位与下界里更晚的那一个"——那是**最早可放**，
  /// 也是唯一产出过的那一份。传入别的锚点即可得到**同一套级联逻辑的另一份方案**：
  /// 目标块被推到该锚点之后，其余块照样让开。
  ///
  /// **为什么需要这个参数**：最早可放是贪心，它只看"我不撞谁"，
  /// 不看"我这样放会在周围留下什么"。规范 §11.4 第 6 条要求在**方案之间**
  /// 比较坏空档，因此必须先能产出多份方案。
  DateTime? targetAnchorOverride,
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
  final targetAnchor = switch (targetAnchorOverride) {
    // 显式锚点：仍不得早于下界（§11.4 第 2 级是硬条件）。
    final override? =>
      override.isAfter(earliestStart) ? override : earliestStart,
    null =>
      target.startUtc.isAfter(earliestStart) ? target.startUtc : earliestStart,
  };
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

/// 为**从零生成**的结果建立与当前确认计划的一对一**来源关联**（设计 §5.2）。
///
/// **为什么需要这一步**：普通「生成计划」是一次从零排一遍，因此引擎排出的块
/// 与上一版确认计划里的块**没有任何 id 上的联系**。于是
/// `minimizeChangedBlocks` 查不到原位（它按 `continuedFromId` 查参照），
/// `PlanDiffer` 也只能把"同一块换了时间"报成「删除＋新增」而不是「移动」。
///
/// **为什么不把 `existingBlocks` 直接塞进 `blocks`**（裁定第 2 点）：
/// 那会让旧块成为占用，却**不自动扣除任务待排时长** —— 同一件工作可能被安排两次。
/// 从零生成因此保持不变，关联在生成**之后**建立，是纯后处理。
///
/// 代价键（顺序即优先级）：
/// 1. 同一 `taskId`；
/// 2. 时长差最小；
/// 3. 开始时间位移最小；
/// 4. 产出块 id 与旧块 id 作最终排序键
///    （保证同一输入永远得到同一份配对，**且与输入的排列无关**）。
///
/// **一对一**：一个旧块只能被认领一次。多余的旧块视为删除，多余的新块来源为空。
///
/// 已经带 `continuedFromId` 的块**不被覆盖**，且它们占用的旧块也不参与匹配：
/// 调整路径可能已经显式设好来源，这一步只处理"还没建立来源"的块。
List<PlannedBlock> linkBlockProvenance({
  required List<PlannedBlock> confirmed,
  required List<PlannedBlock> generated,
}) {
  if (generated.isEmpty) return const [];

  final alreadyLinked = <String>{
    for (final block in generated) ?block.continuedFromId,
  };

  // 枚举全部合法配对，按代价键排序后贪心取用。
  //
  // **为什么是"排序＋贪心"而不是"逐块就近取"**：逐块取的结果取决于遍历顺序，
  // 同一输入可能得到两种 id 分配，而 id 会落库。排序后贪心等价于
  // "每次取当前全局最优的一对"，对这份代价键是确定的。
  // 排序键末尾带块 id，因此**同分也不依赖排序算法的稳定性**。
  final pairs = <_ProvenancePair>[];
  for (var g = 0; g < generated.length; g++) {
    final next = generated[g];
    if (next.continuedFromId != null) continue;
    for (final prev in confirmed) {
      if (prev.taskId != next.taskId) continue;
      if (alreadyLinked.contains(prev.id)) continue;
      pairs.add(
        _ProvenancePair(
          generatedId: next.id,
          confirmedId: prev.id,
          durationDelta: (next.durationMinutes - prev.durationMinutes).abs(),
          startDelta: next.startUtc
              .difference(prev.startUtc)
              .inMicroseconds
              .abs(),
        ),
      );
    }
  }
  pairs.sort(_ProvenancePair.compare);

  // 用 id 而不是下标回填：结果列表与 `generated` 同序同长，
  // 且下标会在"重复 id"的畸形输入下指错块。
  final byGeneratedId = <String, PlannedBlock>{
    for (final block in generated) block.id: block,
  };
  final used = <String>{...alreadyLinked};
  for (final pair in pairs) {
    if (used.contains(pair.confirmedId)) continue;
    final next = byGeneratedId[pair.generatedId];
    if (next == null || next.continuedFromId != null) continue;
    used.add(pair.confirmedId);
    byGeneratedId[pair.generatedId] = next.withProvenance(pair.confirmedId);
  }
  return [for (final block in generated) byGeneratedId[block.id]!];
}

/// 在**有限、确定的合法方案集合**里挑一份（裁定"Task 13 的决定"第 2 点；设计 §5.5）。
///
/// **为什么需要它**：`localRepairCascade` 只产出**一份**方案（"最早可放"）。
/// 最早可放是贪心——它只看"我不撞谁"，不看"我这样放会在周围留下什么"。
/// 本批次实测过这一点：按"离开短缝"的局部贪心去排，会在更远处制造**更大的缺口**
/// （见验收表 §9 的 `maximumUnusableGapPenalty` 实测记录）。
///
/// 规范 §11.4 第 6 条要的是**在方案之间比较**"坏空档"，因此必须先有多份方案。
///
/// 过滤（硬条件，不满足的直接淘汰）：
/// - 方案必须**含目标块**（否则第 5 级"目标块距下界"无从判定）；
/// - 目标块开始时刻**不早于** [notBeforeUtc]（§11.4 第 2 级）；
/// - 整份方案落在 [dayStartUtc]～[dayEndUtc] 之内。
///
/// 排序交给 [LocalRepairPlan.compare]（第 3～7 级 + 稳定签名）。
///
/// **确定**：候选的排列不影响结果——`compare` 的末级是稳定签名，同分也有唯一答案。
LocalRepairOutcome chooseRepairPlan({
  required String targetBlockId,
  required DateTime notBeforeUtc,
  required List<LocalRepairPlan> candidates,
  required Map<String, DateTime> reference,
  required Iterable<SchedulableTask> tasks,
  required DateTime dayStartUtc,
  required DateTime dayEndUtc,
  List<TimeRange> protectedRanges = const [],
  int breakMinutes = 0,
}) {
  // 先过滤，再排序：把不合法的候选挡在比较之外，而不是靠比较把它们排到最后
  // ——那样它们仍会参与第 6、7 级的坏空档统计，得到一个没有意义的名次。
  final legal = [
    for (final candidate in candidates)
      if (_isLegalRepairCandidate(
        candidate,
        targetBlockId: targetBlockId,
        notBeforeUtc: notBeforeUtc,
        dayStartUtc: dayStartUtc,
        dayEndUtc: dayEndUtc,
      ))
        candidate,
  ];
  if (legal.isEmpty) {
    return (feasible: false, blocks: const [], reference: const {});
  }

  // 逐个替换"当前最优"：`compare` 返回**负**表示前者更优。
  var best = legal.first;
  for (final candidate in legal.skip(1)) {
    final order = LocalRepairPlan.compare(
      candidate,
      best,
      reference: reference,
      targetBlockId: targetBlockId,
      notBeforeUtc: notBeforeUtc,
      tasks: tasks,
      protectedRanges: protectedRanges,
      breakMinutes: breakMinutes,
    );
    if (order < 0) best = candidate;
  }
  return (feasible: true, blocks: best.blocks, reference: const {});
}

/// 候选是否满足 [chooseRepairPlan] 的三条硬条件。
bool _isLegalRepairCandidate(
  LocalRepairPlan candidate, {
  required String targetBlockId,
  required DateTime notBeforeUtc,
  required DateTime dayStartUtc,
  required DateTime dayEndUtc,
}) {
  final target = candidate.blocks
      .where((block) => block.id == targetBlockId)
      .firstOrNull;
  if (target == null) return false;
  if (target.startUtc.isBefore(notBeforeUtc)) return false;
  // 整份方案必须落在当天窗口内：越界的块不是"更好的方案"，而是不可行的方案。
  for (final block in candidate.blocks) {
    if (block.startUtc.isBefore(dayStartUtc)) return false;
    if (block.endUtc.isAfter(dayEndUtc)) return false;
  }
  return true;
}

/// **按本地自然日做"当天优先"**的调整（规范 §11.4 末段）。
///
/// 裁定原文（规范 §11.4 末段）："**先在当天做向后级联；当天放不下时才考虑后续日期。**"
///
/// **为什么需要单独一层**：[repairBestPlan] 只认 [dayStartUtc]／[dayEndUtc]，
/// 而生产接线此前传的是**整个规划窗口**（默认 7 天）。于是"当天优先"没有被执行——
/// 级联可以直接把目标块放到几天之后，只要那还在窗口里。
///
/// 本函数把边界收成**目标块原位置所在的那个本地自然日**：
///
/// 1. 先用 `[本地日 00:00, 本地日 24:00)` 跑一次 [repairBestPlan]；
/// 2. 不可行时才把边界放宽到 [planningEndUtc]，再跑一次。
///
/// **"当天"取的是目标块原位置那一天**，而不是"今天"：用户对一个 10 月 14 日的块
/// 执行延后时，"当天"就是 10 月 14 日。用"今天"会把下界与窗口对不上
/// （下界在 14 日、窗口起点在 12 日）。
///
/// **确定性**：两次调用都是确定的，取舍规则固定（当天优先），与输入排列无关。
LocalRepairOutcome repairBestPlanDayScoped({
  required String targetBlockId,
  required DateTime notBeforeUtc,
  required List<PlannedBlock> blocks,
  required List<PlannedBlock> immovable,

  /// 目标块**调整前**的开始时刻：用它定位"当天"。
  required DateTime targetStartUtc,
  required String timeZoneId,
  required TimeZoneDatabase zones,

  /// 当天放不下时向外放宽到的终点（通常是规划窗口终点）。
  required DateTime planningEndUtc,
  required Iterable<SchedulableTask> tasks,
  Map<String, DateTime> reference = const {},
  List<TimeRange> protectedRanges = const [],
  int breakMinutes = 0,
  int maxCandidates = maxRepairCandidates,
}) {
  // 目标块所在**本地日**的午夜。把目标时刻转成本地，取日期部分，再换回 UTC。
  final localTarget = zones.toLocal(targetStartUtc, timeZoneId);
  final localDate = DateTime(
    localTarget.year,
    localTarget.month,
    localTarget.day,
  );
  final dayStartUtc = zones.localMidnightToUtc(localDate, timeZoneId);
  final dayEndUtc = zones.localMidnightToUtc(
    localDate.add(const Duration(days: 1)),
    timeZoneId,
  );

  LocalRepairOutcome attempt(DateTime end) => repairBestPlan(
    targetBlockId: targetBlockId,
    notBeforeUtc: notBeforeUtc,
    blocks: blocks,
    immovable: immovable,
    dayStartUtc: dayStartUtc,
    dayEndUtc: end,
    tasks: tasks,
    reference: reference,
    protectedRanges: protectedRanges,
    breakMinutes: breakMinutes,
    maxCandidates: maxCandidates,
  );

  // ① 当天优先。
  final sameDay = attempt(dayEndUtc);
  if (sameDay.feasible) return sameDay;

  // ② 当天放不下才考虑后续日期（规范 §11.4 末段）。
  //
  // 终点仍是规划窗口终点：**不越过用户看到的那段范围**——
  // 再往后就不是"这次调整"能承诺的了。
  //
  // 只有窗口确实更宽时才重试：`dayEndUtc` 已经到窗口底时，
  // 再跑一次会得到同一份不可行结果，纯属浪费（候选最多 32 份）。
  if (!planningEndUtc.isAfter(dayEndUtc)) return sameDay;
  return attempt(planningEndUtc);
}

/// 一段间隔的分类上限：候选择优只看 [maxCandidates] 份方案（设计 §5.5 的"有限"）。
///
/// **必须是有限且小的**：候选越多，"挑一份"的收益越小，而代价是每次调整都要跑
/// 多轮级联。取 32 是因为它对一天 1440 分钟的粒度来说足够细分，
/// 同时保证调整的耗时与当天块数成线性关系。
const int maxRepairCandidates = 32;

/// 为一个已确认块切出**有限、确定**的候选锚点集合（设计 §5.5）。
///
/// 锚点候选 = 下界，以及**每个与"下界之后的窗口"相交的排程区间结束时刻**
/// （让开一个占用之后重新尝试）。这样"稍晚一点反而没有坏空档"的位置会被枚举到，
/// 而集合大小受 [maxCandidates] 约束。
///
/// **确定性**：锚点由"下界 + 排程区间结束时刻"推出，按时间升序去重，
/// 与输入块的排列无关；`occupied` 会先排序。同分时由
/// [LocalRepairPlan.compare] 的稳定签名决定。
///
/// 只考虑**下界之后**的锚点：早于下界的位置不合法（§11.4 第 2 级）。
List<DateTime> repairCandidateAnchors({
  required DateTime notBeforeUtc,
  required DateTime dayEndUtc,
  required Iterable<TimeRange> occupied,
  int maxCandidates = maxRepairCandidates,
}) {
  if (maxCandidates <= 0 || !notBeforeUtc.isBefore(dayEndUtc)) return const [];
  final anchors = <DateTime>{notBeforeUtc};
  final ordered = [...occupied]
    ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
  for (final slot in ordered) {
    // 只取"在下界之后结束"的占用：更早结束的那些不影响下界之后能放什么。
    if (!slot.endUtc.isAfter(notBeforeUtc)) continue;
    if (!slot.endUtc.isBefore(dayEndUtc)) continue;
    anchors.add(slot.endUtc);
    if (anchors.length >= maxCandidates) break;
  }
  return anchors.toList()..sort();
}

/// 为一次调整生成候选方案集合，并挑出最优的一份（设计 §5.5）。
///
/// 这是 [chooseRepairPlan] 的"生成"那一半：先按 [repairCandidateAnchors] 枚举锚点，
/// 每个锚点跑一次 [localRepairCascade] 得到一份方案，再交给 [chooseRepairPlan] 排序。
///
/// 当天一份可行方案都没有时返回不可行——调用方据此决定"是否搜索后续日期"
/// （§11.4 末段），而不是在这里偷偷跨天。
LocalRepairOutcome repairBestPlan({
  required String targetBlockId,
  required DateTime notBeforeUtc,
  required List<PlannedBlock> blocks,
  required List<PlannedBlock> immovable,
  required DateTime dayStartUtc,
  required DateTime dayEndUtc,
  required Iterable<SchedulableTask> tasks,
  Map<String, DateTime> reference = const {},
  List<TimeRange> protectedRanges = const [],
  int breakMinutes = 0,
  int maxCandidates = maxRepairCandidates,
}) {
  final anchors = repairCandidateAnchors(
    notBeforeUtc: notBeforeUtc,
    dayEndUtc: dayEndUtc,
    occupied: [
      for (final block in immovable) block.range,
      for (final block in blocks)
        if (block.id != targetBlockId) block.range,
    ],
    maxCandidates: maxCandidates,
  );

  // 参照＝"调整前每个块的位置"，供第 3、4 级数块数与位移。
  final before = {for (final block in blocks) block.id: block.startUtc};

  final candidates = <LocalRepairPlan>[];
  for (final anchor in anchors) {
    final outcome = localRepairCascade(
      targetBlockId: targetBlockId,
      notBeforeUtc: notBeforeUtc,
      blocks: blocks,
      immovable: immovable,
      dayStartUtc: dayStartUtc,
      dayEndUtc: dayEndUtc,
      targetAnchorOverride: anchor,
    );
    if (!outcome.feasible) continue;
    final movedIds = <String>{};
    for (final block in outcome.blocks) {
      final original = before[block.id];
      if (original == null || original != block.startUtc) {
        movedIds.add(block.id);
      }
    }
    candidates.add(
      LocalRepairPlan(blocks: outcome.blocks, movedBlockIds: movedIds),
    );
  }

  return chooseRepairPlan(
    targetBlockId: targetBlockId,
    notBeforeUtc: notBeforeUtc,
    candidates: candidates,
    reference: reference.isEmpty ? before : reference,
    tasks: tasks,
    dayStartUtc: dayStartUtc,
    dayEndUtc: dayEndUtc,
    protectedRanges: protectedRanges,
    breakMinutes: breakMinutes,
  );
}

/// 一次候选配对。三个排序键与 [compare] 里的比较顺序一一对应。
final class _ProvenancePair {
  const _ProvenancePair({
    required this.generatedId,
    required this.confirmedId,
    required this.durationDelta,
    required this.startDelta,
  });

  final String generatedId;
  final String confirmedId;
  final int durationDelta;
  final int startDelta;

  /// 代价键 2、3、4。第 1 条（同一任务）在枚举配对时已经保证。
  static int compare(_ProvenancePair a, _ProvenancePair b) {
    final byDuration = a.durationDelta.compareTo(b.durationDelta);
    if (byDuration != 0) return byDuration;
    final byStart = a.startDelta.compareTo(b.startDelta);
    if (byStart != 0) return byStart;
    final byGeneratedId = a.generatedId.compareTo(b.generatedId);
    if (byGeneratedId != 0) return byGeneratedId;
    return a.confirmedId.compareTo(b.confirmedId);
  }
}
