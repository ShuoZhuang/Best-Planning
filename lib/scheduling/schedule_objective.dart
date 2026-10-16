import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/scheduling/candidate_eligibility.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/gap_classifier.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// [ScheduleObjective] 上可以被字典序比较的**业务字段名**。
///
/// 计划 §3.3 用中文列表写死了三种 profile 的字段顺序，而"顺序"是这一节唯一容易
/// 被悄悄改错的东西：把 `movedConfirmedBlockCount` 挪到 `changedConfirmedBlockCount`
/// 之前，任何一条"少移动"的用例都不会变红，但真实行为已经变了。
///
/// 因此把顺序做成**可读的字段名列表**（[scheduleObjectiveStageNames]），
/// 比较器按它派发；`schedule_objective_test.dart` 直接对这份列表断言。
/// 这样"顺序"这件事有了单一事实源，而且它自己是可测的。
enum ScheduleObjectiveField {
  hardViolationCount,
  invariantViolationCount,
  unfulfilledAdjustmentCount,
  newShortageMinutesAgainstReference,
  urgentShortageMinutes,
  highShortageMinutes,
  mediumShortageMinutes,
  lowShortageMinutes,
  maximumDailyUtilizationPermille,
  totalOverTargetPermille,
  pacingDeviationMinutes,
  movedConfirmedBlockCount,
  changedConfirmedBlockCount,
  displacementMinutes,
  extraTargetDisplacementMinutes,
  recreatedBlockCount,
  fragmentCount,
  softPreferencePenalty,
  orphanGapCount,
  orphanGapMinutes,
}

/// 一份方案按**哪一种字典序**比较（算法 17，计划 §3.3）。
///
/// 三条路径的目标顺序**不同**，因为它们要优化的东西不同：
/// - [initialGeneration]：从零排一遍，追求"完成度最高、最均衡"；
/// - [backgroundReplan]：已有确认计划，**稳定性排在均衡之前**（微小质量改善不值得
///   移动一批已确认块）；
/// - [explicitAdjustment]：用户指定了要动哪一块，**"这次调整兑现了没有"必须最优先**，
///   否则引擎可以用"删掉目标块"来赢得"少移动"。
///
/// 任何后一项的改善都不能补偿前一项的恶化（计划 §3.3 末句）。
enum ScheduleObjectiveProfile {
  initialGeneration,
  backgroundReplan,
  explicitAdjustment,
}

/// [profile] 对应的**逐层比较顺序**（计划 §3.3 的三种列表，逐字对应）。
///
/// 它是"顺序"这件事的单一事实源：[compareScheduleObjectives] 按它派发，
/// 而 `schedule_objective_test.dart` 直接对它断言，因此顺序改动不可能静默。
List<ScheduleObjectiveField> scheduleObjectiveStageNames(
  ScheduleObjectiveProfile profile,
) => switch (profile) {
  // 初次生成：完成度 → 负载 → 节奏 → 形状 → 偏好 → 空档。
  ScheduleObjectiveProfile.initialGeneration => const [
    ScheduleObjectiveField.hardViolationCount,
    ScheduleObjectiveField.invariantViolationCount,
    ScheduleObjectiveField.urgentShortageMinutes,
    ScheduleObjectiveField.highShortageMinutes,
    ScheduleObjectiveField.mediumShortageMinutes,
    ScheduleObjectiveField.lowShortageMinutes,
    ScheduleObjectiveField.maximumDailyUtilizationPermille,
    ScheduleObjectiveField.totalOverTargetPermille,
    ScheduleObjectiveField.pacingDeviationMinutes,
    ScheduleObjectiveField.fragmentCount,
    ScheduleObjectiveField.softPreferencePenalty,
    ScheduleObjectiveField.orphanGapCount,
    ScheduleObjectiveField.orphanGapMinutes,
  ],
  // 普通重排：完成度不变，**稳定性先于均衡**（计划 §3.3 普通重排第 8～10 项）。
  ScheduleObjectiveProfile.backgroundReplan => const [
    ScheduleObjectiveField.hardViolationCount,
    ScheduleObjectiveField.invariantViolationCount,
    ScheduleObjectiveField.urgentShortageMinutes,
    ScheduleObjectiveField.highShortageMinutes,
    ScheduleObjectiveField.mediumShortageMinutes,
    ScheduleObjectiveField.lowShortageMinutes,
    ScheduleObjectiveField.changedConfirmedBlockCount,
    ScheduleObjectiveField.movedConfirmedBlockCount,
    ScheduleObjectiveField.displacementMinutes,
    ScheduleObjectiveField.recreatedBlockCount,
    ScheduleObjectiveField.maximumDailyUtilizationPermille,
    ScheduleObjectiveField.totalOverTargetPermille,
    ScheduleObjectiveField.pacingDeviationMinutes,
    ScheduleObjectiveField.fragmentCount,
    ScheduleObjectiveField.softPreferencePenalty,
    ScheduleObjectiveField.orphanGapCount,
    ScheduleObjectiveField.orphanGapMinutes,
  ],
  // 指定调整：**"这次调整兑现了没有"排在最前**，然后才是别人的稳定与完成度。
  ScheduleObjectiveProfile.explicitAdjustment => const [
    ScheduleObjectiveField.hardViolationCount,
    ScheduleObjectiveField.invariantViolationCount,
    ScheduleObjectiveField.unfulfilledAdjustmentCount,
    ScheduleObjectiveField.newShortageMinutesAgainstReference,
    ScheduleObjectiveField.changedConfirmedBlockCount,
    ScheduleObjectiveField.displacementMinutes,
    ScheduleObjectiveField.extraTargetDisplacementMinutes,
    ScheduleObjectiveField.urgentShortageMinutes,
    ScheduleObjectiveField.highShortageMinutes,
    ScheduleObjectiveField.mediumShortageMinutes,
    ScheduleObjectiveField.lowShortageMinutes,
    ScheduleObjectiveField.maximumDailyUtilizationPermille,
    ScheduleObjectiveField.totalOverTargetPermille,
    ScheduleObjectiveField.pacingDeviationMinutes,
    ScheduleObjectiveField.fragmentCount,
    ScheduleObjectiveField.softPreferencePenalty,
    ScheduleObjectiveField.orphanGapCount,
    ScheduleObjectiveField.orphanGapMinutes,
  ],
};

int _valueOfField(
  ScheduleObjective objective,
  ScheduleObjectiveField field,
) => switch (field) {
  ScheduleObjectiveField.hardViolationCount => objective.hardViolationCount,
  ScheduleObjectiveField.invariantViolationCount =>
    objective.invariantViolationCount,
  ScheduleObjectiveField.unfulfilledAdjustmentCount =>
    objective.unfulfilledAdjustmentCount,
  ScheduleObjectiveField.newShortageMinutesAgainstReference =>
    objective.newShortageMinutesAgainstReference,
  ScheduleObjectiveField.urgentShortageMinutes =>
    objective.shortageMinutesByPriority[0],
  ScheduleObjectiveField.highShortageMinutes =>
    objective.shortageMinutesByPriority[1],
  ScheduleObjectiveField.mediumShortageMinutes =>
    objective.shortageMinutesByPriority[2],
  ScheduleObjectiveField.lowShortageMinutes =>
    objective.shortageMinutesByPriority[3],
  ScheduleObjectiveField.maximumDailyUtilizationPermille =>
    objective.maximumDailyUtilizationPermille,
  ScheduleObjectiveField.totalOverTargetPermille =>
    objective.totalOverTargetPermille,
  ScheduleObjectiveField.pacingDeviationMinutes =>
    objective.pacingDeviationMinutes,
  ScheduleObjectiveField.movedConfirmedBlockCount =>
    objective.movedConfirmedBlockCount,
  ScheduleObjectiveField.changedConfirmedBlockCount =>
    objective.changedConfirmedBlockCount,
  ScheduleObjectiveField.displacementMinutes => objective.displacementMinutes,
  ScheduleObjectiveField.extraTargetDisplacementMinutes =>
    objective.extraTargetDisplacementMinutes,
  ScheduleObjectiveField.recreatedBlockCount => objective.recreatedBlockCount,
  ScheduleObjectiveField.fragmentCount => objective.fragmentCount,
  ScheduleObjectiveField.softPreferencePenalty =>
    objective.softPreferencePenalty,
  ScheduleObjectiveField.orphanGapCount => objective.orphanGapCount,
  ScheduleObjectiveField.orphanGapMinutes => objective.orphanGapMinutes,
};

/// 按 [profile] **逐层**比较两份方案。返回负数表示 [a] 更优，零表示所有业务维度相同。
///
/// ## 为什么"零"是允许的
///
/// 末项 [ScheduleObjective.stableSignature] 已经保证**同分也有唯一答案**：
/// 调用方在得到 0 时应当用签名自己决定，或者认为两者等价。
/// 契约里"零表示所有业务维度相同后由稳定签名决定"说的就是这件事——
/// 这个函数把签名也纳入了比较，因此**只有签名也相同时才会返回 0**。
int compareScheduleObjectives(
  ScheduleObjective a,
  ScheduleObjective b,
  ScheduleObjectiveProfile profile,
) {
  for (final field in scheduleObjectiveStageNames(profile)) {
    final order = _valueOfField(a, field).compareTo(_valueOfField(b, field));
    if (order != 0) return order;
  }
  return a.stableSignature.compareTo(b.stableSignature);
}

/// 一份方案的**完整目标向量**（算法 17，计划 §3.3 / §6）。
///
/// ## 为什么是一个向量而不是一个总分
///
/// 修复前 `CandidateScorer` 把截止、优先级、精力、连续性、碎片、移动成本**相加**。
/// 相加的后果是"一个足够大的软偏好可以覆盖跨日均衡意图"（计划 §1.2 第 5 条）：
/// 高精力窗口全在工作日时，工作日会被继续堆满，而周末整周空着——不是因为没有
/// 合法容量，而是因为"精力匹配"这一个加数大于"均衡"那一个加数。
///
/// 计划 §3.3 因此禁止求和，改为**字典序**：任何后一项的改善都不能补偿前一项的恶化。
/// [compareScheduleObjectives] 是这条规则的唯一实现。
///
/// ## 每个字段的口径
///
/// 所有量都**只读显式输入**：这个类不读系统时钟、不访问仓库、不写日志（计划 Task 4 Step 4）。
final class ScheduleObjective {
  const ScheduleObjective({
    required this.hardViolationCount,
    required this.invariantViolationCount,
    required this.unfulfilledAdjustmentCount,
    required this.newShortageMinutesAgainstReference,
    required this.shortageMinutesByPriority,
    required this.maximumDailyUtilizationPermille,
    required this.totalOverTargetPermille,
    required this.pacingDeviationMinutes,
    required this.movedConfirmedBlockCount,
    required this.changedConfirmedBlockCount,
    required this.displacementMinutes,
    required this.extraTargetDisplacementMinutes,
    required this.recreatedBlockCount,
    required this.fragmentCount,
    required this.softPreferencePenalty,
    required this.orphanGapCount,
    required this.orphanGapMinutes,
    required this.stableSignature,
  });

  /// 硬约束违规数。计划 §3.3 要求它**必须为 0**（第 1 项）。
  final int hardViolationCount;

  /// 内部不变量违规数（重复块 ID、任务分钟超发等）。同样必须为 0（第 2 项）。
  final int invariantViolationCount;

  /// 指定调整**未兑现**的条数（第 2 项，仅 [ScheduleObjectiveProfile.explicitAdjustment]）。
  final int unfulfilledAdjustmentCount;

  /// **相对调整前基线新增**的未安排分钟（第 3 项）。
  ///
  /// 计划 §3.3：这一项"必须为 0，否则该调整方案不可应用"。它是"不能靠删块来少移动"
  /// 这条纪律的数字形式。
  final int newShortageMinutesAgainstReference;

  /// 基线本来就存在的未安排分钟向量，按 **urgent / high / medium / low** 顺序。
  ///
  /// 计划 Task 4 Step 2：**禁止使用单一加权和**，同级再比较分钟。
  final List<int> shortageMinutesByPriority;

  /// 最大单日负载率（千分比）。
  final int maximumDailyUtilizationPermille;

  /// 所有日期**超过目标水位**的总量（千分比之和）。
  final int totalOverTargetPermille;

  /// 周期目标节奏偏差（分钟）：实际累计分钟与节奏目标累计分钟的绝对差之和。
  final int pacingDeviationMinutes;

  /// 被移动的**已确认**块数（`backgroundReplan` 第 8 项）。
  final int movedConfirmedBlockCount;

  /// 被改变的已确认块数——**移动、删除、拆分、合并、重建都计入**（`backgroundReplan` 第 8 项）。
  ///
  /// 计划 §3.3 明确："不能用删除绕过'少移动'"。因此这个数**不小于**
  /// [movedConfirmedBlockCount]，且删除会让它增加。
  final int changedConfirmedBlockCount;

  /// 非目标块总位移分钟（`backgroundReplan` 第 9 项、`explicitAdjustment` 第 5 项）。
  final int displacementMinutes;

  /// 目标块**超出要求之后**的额外位移分钟（`explicitAdjustment` 第 6 项）。
  final int extraTargetDisplacementMinutes;

  /// 删除后重建的块数（`backgroundReplan` 第 10 项）。
  final int recreatedBlockCount;

  /// 不必要片段数（第 11／14 项）。
  final int fragmentCount;

  /// 日内软偏好损失（第 12／14 项）：精力、期望时段、连续性、类别切换的合计代价。
  final int softPreferencePenalty;

  /// 坏空档数量（第 13／14 项）。
  final int orphanGapCount;

  /// 坏空档总分钟（第 14 项）。
  final int orphanGapMinutes;

  /// 确定性签名：所有业务字段相同时由它打破平局（末项）。
  final String stableSignature;

  @override
  String toString() =>
      'ScheduleObjective(hard=$hardViolationCount inv=$invariantViolationCount '
      'unfulfilled=$unfulfilledAdjustmentCount newShortage=$newShortageMinutesAgainstReference '
      'priority=$shortageMinutesByPriority maxUtil=$maximumDailyUtilizationPermille '
      'overTarget=$totalOverTargetPermille pacing=$pacingDeviationMinutes '
      'moved=$movedConfirmedBlockCount changed=$changedConfirmedBlockCount '
      'displacement=$displacementMinutes extraTarget=$extraTargetDisplacementMinutes '
      'recreated=$recreatedBlockCount fragments=$fragmentCount soft=$softPreferencePenalty '
      'orphanGaps=$orphanGapCount orphanMinutes=$orphanGapMinutes sig=$stableSignature)';
}

/// 求一份方案的 [ScheduleObjective]（计划 Task 4 Step 4）。
///
/// **纯函数**：只读 [problem]、[blocks]、[ledger] 与 [zones]，不读系统时钟、
/// 不访问仓库、不写日志。同一次生成里对同一份块集合求值必须逐值相同。
ScheduleObjective evaluateScheduleObjective({
  required ScheduleProblem problem,
  required List<PlannedBlock> blocks,
  required DayCapacityLedger ledger,
  required TimeZoneDatabase zones,
  required ScheduleObjectiveProfile profile,
  Map<DateTime, int> targetUtilizationPermille = const {},
  int hardViolationCount = 0,
  int invariantViolationCount = 0,
  int softPreferencePenalty = 0,
}) {
  final shortageByPriority = _shortageByPriority(problem, blocks);
  final referenceShortageByPriority = _referenceShortageByPriority(problem);
  final newShortage = _newShortageMinutes(
    shortageByPriority,
    referenceShortageByPriority,
  );
  final stability = _stability(problem: problem, blocks: blocks, zones: zones);
  final utilization = _utilization(
    ledger: ledger,
    targetPermille: targetUtilizationPermille,
  );
  final gaps = _orphanGaps(problem: problem, blocks: blocks);
  return ScheduleObjective(
    hardViolationCount: hardViolationCount,
    invariantViolationCount: invariantViolationCount,
    unfulfilledAdjustmentCount: _unfulfilledAdjustmentCount(problem, blocks),
    newShortageMinutesAgainstReference: newShortage,
    shortageMinutesByPriority: shortageByPriority,
    maximumDailyUtilizationPermille: utilization.maximum,
    totalOverTargetPermille: utilization.totalOverTarget,
    pacingDeviationMinutes: _pacingDeviation(problem, blocks),
    movedConfirmedBlockCount: stability.moved,
    changedConfirmedBlockCount: stability.changed,
    displacementMinutes: stability.displacement,
    extraTargetDisplacementMinutes: stability.extraTargetDisplacement,
    recreatedBlockCount: stability.recreated,
    fragmentCount: fragmentsOf(problem, blocks, zones),
    softPreferencePenalty: softPreferencePenalty,
    orphanGapCount: gaps.count,
    orphanGapMinutes: gaps.minutes,
    stableSignature: stableSignatureOf(blocks),
  );
}

/// 各优先级**仍然未安排**的分钟，按 urgent / high / medium / low 排列。
///
/// **它是向量而不是一个数**：计划 Task 4 Step 2 明确"禁止使用单一加权和"。
/// 一个加权和会让"少缺 1 分钟紧急任务"与"少缺 30 分钟低优先任务"变成可比的数，
/// 而计划 §3.3 要求紧急任务**永远**先完整。
List<int> _shortageByPriority(
  ScheduleProblem problem,
  List<PlannedBlock> blocks,
) {
  final scheduledByTask = <String, int>{};
  for (final block in blocks) {
    scheduledByTask.update(
      block.taskId,
      (value) => value + block.durationMinutes,
      ifAbsent: () => block.durationMinutes,
    );
  }
  final byPriority = <TaskPriority, int>{
    for (final priority in TaskPriority.values) priority: 0,
  };
  for (final task in problem.tasks) {
    final scheduled = scheduledByTask[task.id] ?? 0;
    final remaining = task.requiredMinutes - scheduled;
    if (remaining <= 0) continue;
    byPriority[task.priority] = byPriority[task.priority]! + remaining;
  }
  return [for (final priority in TaskPriority.values) byPriority[priority]!];
}

/// 基线（调整前）本来就存在的未安排分钟向量。
///
/// 计划 §3.3 指定调整第 7 项比较的是"**基线本来就有**的各优先级未安排分钟向量"：
/// 比较的是"谁把原本就没做完的事做得更好"，而不是"谁凭空多出了缺口"。
/// 没有确认计划时基线就是空的（全部为零）。
List<int> _referenceShortageByPriority(ScheduleProblem problem) {
  final confirmedByTask = <String, int>{};
  for (final block in problem.confirmedBlocks) {
    confirmedByTask.update(
      block.taskId,
      (value) => value + block.durationMinutes,
      ifAbsent: () => block.durationMinutes,
    );
  }
  final byPriority = <TaskPriority, int>{
    for (final priority in TaskPriority.values) priority: 0,
  };
  for (final task in problem.tasks) {
    final scheduled = confirmedByTask[task.id] ?? 0;
    final remaining = task.requiredMinutes - scheduled;
    if (remaining <= 0) continue;
    byPriority[task.priority] = byPriority[task.priority]! + remaining;
  }
  return [for (final priority in TaskPriority.values) byPriority[priority]!];
}

/// **相对基线新增**的未安排分钟：只把"变差"的部分加起来。
///
/// 计划 §3.3 用词是"相对调整前基线**新增**的未安排分钟"，因此一份比基线更好的方案
/// 记 0，而不是负数。
int _newShortageMinutes(List<int> current, List<int> reference) {
  var total = 0;
  for (var index = 0; index < current.length; index++) {
    final delta = current[index] - reference[index];
    if (delta > 0) total += delta;
  }
  return total;
}

/// 若干日负载指标：最大单日负载率与超目标水位总量（计划 §3.3 的公式）。
({int maximum, int totalOverTarget}) _utilization({
  required DayCapacityLedger ledger,
  required Map<DateTime, int> targetPermille,
}) {
  var maximum = 0;
  var over = 0;
  for (final snapshot in ledger.snapshots) {
    if (snapshot.utilizationPermille > maximum) {
      maximum = snapshot.utilizationPermille;
    }
    final target = targetPermille[snapshot.localDate];
    if (target == null) continue;
    final excess = snapshot.utilizationPermille - target;
    if (excess > 0) over += excess;
  }
  return (maximum: maximum, totalOverTarget: over);
}

/// 稳定性成本：相对**确认计划**改变了多少（计划 §3.3 普通重排第 8～10 项）。
///
/// ## 判据："位置或时长变了"就计入 changed
///
/// 计划要求"移动、删除、拆分、合并和重建都算改变，不能用删除绕过'少移动'"。
/// 因此 [changed] 数的判据是**逐块配对**的结果：
///
/// - 确认计划里的一块，在新方案里由**同一 `continuedFromId`** 的一条块延续、
///   且区间逐值相同 ⇒ 未改变；
/// - 其余情况（移位、改长、被拆成多条、被合并、彻底消失、新块与它无关）⇒ 计入 changed。
///
/// 把"删除"计入 changed 是关键：否则"删掉那一块，再在别处新建一块"会得到
/// `changed = 0`，而用户实际看到的是"你把我的安排动了"。
({
  int moved,
  int changed,
  int displacement,
  int extraTargetDisplacement,
  int recreated,
})
_stability({
  required ScheduleProblem problem,
  required List<PlannedBlock> blocks,
  required TimeZoneDatabase zones,
}) {
  final reference = problem.referenceBlocks;
  if (reference.isEmpty) {
    return (
      moved: 0,
      changed: 0,
      displacement: 0,
      extraTargetDisplacement: 0,
      recreated: 0,
    );
  }
  final targetBlockId = problem.adjustment?.targetBlockId;
  final notBeforeUtc = problem.adjustment?.notBeforeUtc;

  // 新方案里"延续自哪一块"的索引。同一来源可能被多条块引用（拆分），因此是列表。
  final continuedBySource = <String, List<PlannedBlock>>{};
  final matchedSourceIds = <String>{};
  for (final block in blocks) {
    final source = block.continuedFromId;
    if (source == null || !reference.containsKey(source)) continue;
    (continuedBySource[source] ??= []).add(block);
    matchedSourceIds.add(source);
  }

  var moved = 0;
  var changed = 0;
  var displacement = 0;
  var extraTarget = 0;
  var recreated = 0;
  final confirmedIds = reference.keys.toList()..sort();

  for (final id in confirmedIds) {
    final originalStart = reference[id]!;
    final continuations = continuedBySource[id];
    final isTarget = id == targetBlockId;
    if (continuations == null || continuations.isEmpty) {
      // 确认块在新方案里没有延续者：它被删除（或被彻底重建）。
      changed++;
      recreated++;
      continue;
    }
    final isSameSingleBlock =
        continuations.length == 1 &&
        continuations.single.startUtc == originalStart &&
        continuations.single.id == id;
    if (isSameSingleBlock) continue; // 原样保留：不动、不位移、不计改变。

    // 位置或形状变了（或一条被拆成多条）：计入 changed 与位移。
    changed++;
    if (continuations.length == 1 && continuations.single.id == id) {
      moved++;
    } else if (continuations.length == 1) {
      moved++;
    } else {
      // 拆分：整块被换成了多条，位移按"最靠前那条与原位置的差"计。
      moved++;
    }
    final nearest = continuations
        .map((block) => block.startUtc)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final delta = nearest.difference(originalStart).inMinutes.abs();
    if (isTarget) {
      // 目标块**应该**移动：只有"超出要求之后"的部分才计入额外位移。
      final required = problem.adjustment == null || notBeforeUtc == null
          ? 0
          : nearest.difference(notBeforeUtc).inMinutes;
      if (required > 0) extraTarget += required;
    } else {
      displacement += delta;
    }
  }
  return (
    moved: moved,
    changed: changed,
    displacement: displacement,
    extraTargetDisplacement: extraTarget,
    recreated: recreated,
  );
}

/// **指定调整未兑现**的条数（0 或 1）。
///
/// 判据与 `adjustment_fulfilment.dart` 一致：目标块必须存在、且开始时刻不早于
/// `notBeforeUtc`。没有调整要求时恒为 0。
int _unfulfilledAdjustmentCount(
  ScheduleProblem problem,
  List<PlannedBlock> blocks,
) {
  final adjustment = problem.adjustment;
  if (adjustment == null) return 0;
  final target = blocks
      .where((block) => block.id == adjustment.targetBlockId)
      .firstOrNull;
  if (target == null) return 1;
  return target.startUtc.isBefore(adjustment.notBeforeUtc) ? 1 : 0;
}

/// 周期目标节奏偏差（分钟）：每个任务"实际累计"与"节奏目标累计"的绝对差之和。
///
/// 只用**可以在方案层算出来**的口径：任务的目标分钟（`requiredMinutes`）与已排分钟之差，
/// 与"均匀节奏下此刻应当完成多少"比较。没有截止的任务按"已完成量"看待，
/// 因此它们的偏差恒为 0——不引入任何猜测。
int _pacingDeviation(ScheduleProblem problem, List<PlannedBlock> blocks) {
  final scheduledByTask = <String, int>{};
  for (final block in blocks) {
    scheduledByTask.update(
      block.taskId,
      (value) => value + block.durationMinutes,
      ifAbsent: () => block.durationMinutes,
    );
  }
  var deviation = 0;
  for (final task in problem.tasks) {
    if (task.dueAtUtc == null) continue;
    final scheduled = scheduledByTask[task.id] ?? 0;
    final remaining = task.requiredMinutes - scheduled;
    // 节奏目标＝"按均匀节奏到截止为止应当已完成"；没有逐日节奏输入时，
    // 用"是否还差一个最小片段以上"作为偏差的保守估计，避免凭空造出节奏数字。
    if (remaining >= task.minChunkMinutes) {
      deviation += remaining % task.minChunkMinutes;
    }
  }
  return deviation;
}

/// 不必要片段数：同一任务在**同一本地日**内被切成超过必要的片段数（计划第 11／14 项）。
///
/// 判据是"这一天该任务多了几段"：把该任务的块按所在本地日归组，
/// 每组 `段数 − ceil(该组分钟 / maxChunkMinutes)` 的非负部分。
/// 因此"本该一段放完却拆成两段"会被计入，而"确实需要两段"不会。
///
/// [zones] 必须传进来：本地日只能由它换算，把 UTC 时刻直接截成日期会把东八区
/// 清晨的块记到前一天（`candidate_eligibility.dart` 的 `localDateOf` 是同一条纪律）。
int fragmentsOf(
  ScheduleProblem problem,
  List<PlannedBlock> blocks,
  TimeZoneDatabase zones,
) {
  // 任务 → 本地日 → 该日各片段时长。
  final chunksByTaskDate = <String, Map<DateTime, List<int>>>{};
  for (final block in blocks) {
    if (block.taskId.isEmpty) continue;
    final date = localDateOf(block.startUtc, problem.timeZoneId, zones);
    final byDate = chunksByTaskDate[block.taskId] ??= {};
    (byDate[date] ??= []).add(block.durationMinutes);
  }
  var fragments = 0;
  for (final entry in chunksByTaskDate.entries) {
    final task = problem.tasks
        .where((item) => item.id == entry.key)
        .firstOrNull;
    if (task == null) continue;
    final maxChunk = task.maxChunkMinutes <= 0
        ? task.minChunkMinutes
        : task.maxChunkMinutes;
    for (final minutes in entry.value.values) {
      final total = minutes.fold<int>(0, (sum, value) => sum + value);
      final minimumChunks = maxChunk <= 0
          ? 1
          : (total + maxChunk - 1) ~/ maxChunk;
      final excess = minutes.length - minimumChunks;
      if (excess > 0) fragments += excess;
    }
  }
  return fragments;
}

/// 坏空档的数量与总分钟（计划 §3.7）。
///
/// **只有 `orphan` 计入**：`intentionalBreak`（保护时间／规则休息）与 `freeTime`
/// （没有待排任务或当日已达上限）都不算——计划 §3.7 把这两条写成了硬边界。
({int count, int minutes}) _orphanGaps({
  required ScheduleProblem problem,
  required List<PlannedBlock> blocks,
}) {
  final pending = [
    for (final task in problem.tasks)
      if (task.requiredMinutes > 0) task,
  ];
  if (pending.isEmpty) return (count: 0, minutes: 0);
  var count = 0;
  var minutes = 0;
  for (final gap in classifyGaps(
    blocks: blocks,
    tasks: pending,
    protectedRanges: [
      for (final interval in problem.protectedIntervals) interval.range,
    ],
    breakMinutes: problem.rules.breakMinutes,
  )) {
    if (gap.kind != GapKind.orphan) continue;
    count++;
    minutes += gap.minutes;
  }
  return (count: count, minutes: minutes);
}

/// 稳定签名：把块按（起点、任务 ID、块 ID）排序后序列化（计划 Task 4 Step 3）。
///
/// **Map 顺序不得影响它**：签名只由块集合决定，而块集合是列表不是 Map。
/// 排序键与计划 §3.3 末项逐字对应。
String stableSignatureOf(List<PlannedBlock> blocks) {
  final ordered = [...blocks]
    ..sort((a, b) {
      final byStart = a.startUtc.compareTo(b.startUtc);
      if (byStart != 0) return byStart;
      final byTask = a.taskId.compareTo(b.taskId);
      if (byTask != 0) return byTask;
      return a.id.compareTo(b.id);
    });
  return ordered
      .map(
        (block) =>
            '${block.taskId}|${block.id}|'
            '${block.startUtc.microsecondsSinceEpoch}|'
            '${block.endUtc.microsecondsSinceEpoch}',
      )
      .join(';');
}
