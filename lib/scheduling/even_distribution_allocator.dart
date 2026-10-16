// 容量感知的按日均分器（1.7.1 计划 §3.1 / Task 3）。
//
// ## 为什么需要它
//
// 修复前"均匀分布"只是**一个会被放开的单日软配额**：`_dailyQuota` 用
// "剩余分钟 ÷ 剩余可用星期数"算一个统一上限，它既不形成每个日期各自的目标，也不说明余数该
// 落在哪两天。而引擎的初次放置是"两轮"策略——第一轮守配额，第一轮选不出来就第二轮**完全放开**
// 配额。放开后同一天可以继续承接任意数量，于是用户实测出现 `35 / 125 / 50 / 0`（计划 §2.1）。
//
// 这个文件把"某一天应承担多少分钟"从"这一天具体放在几点"里**拆出来**：先按容量分配每日分钟
// 预算，日内选点由既有候选评分负责（见计划 §3.2 的分工）。
//
// ## 为什么是纯函数
//
// 它决定"哪些时段该被占用"，边界不少（容量为 0、某天明显小于份额、最小片段、粒度无法整除、
// 已锁定分钟、DST）。纯函数可以逐条钉住；塞进引擎的放置循环里就只能靠集成测试去碰。
//
// ## 确定性
//
// 同样的输入必须给出逐值相同的输出，且**与输入 Map 的迭代顺序无关**——排程器要求相同输入得到
// 相同结果，而 Dart 的 Map 迭代顺序取决于插入顺序，直接遍历会把输入顺序泄漏到输出里。
import 'dart:collection';

import 'package:personal_planner/scheduling/day_allocation.dart';

/// 均分器的输入。
///
/// 所有 `Map` 的键都是**本地日期**（`DateTime(y, m, d)`，时间部分为 0）。
final class EvenDistributionInput {
  EvenDistributionInput({
    required this.targetMinutes,
    required this.granularityMinutes,
    required this.minChunkMinutes,
    required Map<DateTime, int> capacityMinutesByLocalDate,
    Map<DateTime, int> alreadyPlannedMinutesByLocalDate = const {},
    this.rotationTaskId,
    DateTime? cycleStartLocalDate,
  }) : capacityMinutesByLocalDate = UnmodifiableMapView({
         for (final entry in capacityMinutesByLocalDate.entries)
           _dateOnly(entry.key): entry.value < 0 ? 0 : entry.value,
       }),
       alreadyPlannedMinutesByLocalDate = UnmodifiableMapView({
         for (final entry in alreadyPlannedMinutesByLocalDate.entries)
           _dateOnly(entry.key): entry.value < 0 ? 0 : entry.value,
       }),
       cycleStartLocalDate = cycleStartLocalDate == null
           ? null
           : _dateOnly(cycleStartLocalDate) {
    if (targetMinutes < 0) {
      throw ArgumentError.value(targetMinutes, 'targetMinutes', '不能为负');
    }
    if (granularityMinutes <= 0) {
      throw ArgumentError.value(granularityMinutes, 'granularityMinutes');
    }
    if (minChunkMinutes <= 0) {
      throw ArgumentError.value(minChunkMinutes, 'minChunkMinutes');
    }
  }

  /// 本次仍需要安排的分钟（**已经扣掉已记录的部分**；已锁定/已排的分钟走
  /// [alreadyPlannedMinutesByLocalDate]）。
  final int targetMinutes;
  final int granularityMinutes;
  final int minChunkMinutes;

  /// 每个本地日期还能承接多少分钟（已扣固定日程、保护时间、睡眠、锁定块与片段间休息）。
  final Map<DateTime, int> capacityMinutesByLocalDate;

  /// 该周期实例在这些日期上**已经**占用的分钟（锁定块、手动钉住的块、既有的可移动块）。
  final Map<DateTime, int> alreadyPlannedMinutesByLocalDate;

  /// 轮换键用的任务 ID（计划 §3.4 第 7 条）。
  ///
  /// **为空表示"没有身份"**：此时轮换偏移恒为 0，K 日选择退化为"余量降序 → 日期升序"，
  /// 与修复前的行为逐值相同——这是纯函数调用点（测试、诊断）的兼容路径。
  /// 生产路径（`RepositoryScheduleProblemSource` → 引擎）必须传真实的 task id。
  final String? rotationTaskId;

  /// 该任务所属周期的起点本地日期；为空时 `cycleOrdinal` 记 0。
  final DateTime? cycleStartLocalDate;
}

/// 均分结果。
final class EvenDistributionPlan {
  const EvenDistributionPlan({
    required this.finalMinutesByLocalDate,
    required this.additionalMinutesByLocalDate,
    required this.allocatableMinutes,
    required this.shortageMinutes,
  });

  /// 每日**最终**总量，包含该周期实例在该日已经锁定／钉住的分钟。
  final Map<DateTime, int> finalMinutesByLocalDate;

  /// 本次生成仍需**新增**的每日分钟；引擎实际消费这一张表。
  final Map<DateTime, int> additionalMinutesByLocalDate;

  /// 所有参与日期合起来能承接的分钟（`min(targetMinutes, 总容量)`）。
  final int allocatableMinutes;

  /// 缺口＝`targetMinutes - allocatableMinutes`；容量足够时为 0。
  final int shortageMinutes;

  /// 参与分配的本地日期，升序。
  List<DateTime> get localDates =>
      finalMinutesByLocalDate.keys.toList()..sort();
}

/// 容量感知的水位分配。
///
/// 算法：每一轮把一个**粒度**分钟分给"当前总量最低且仍有容量"的日期；同量时取本地日期升序。
/// 这给出确定性的、与输入顺序无关的结果，并且天然把余数摊到不同日期上。
///
/// ## 关键约定与理由
///
/// - **只有容量大于 0 的日期进入结果**。容量为 0 的日期不参与，也不被"补偿"——
///   计划 §3.1 第 4 条要求"某天容量不足时只把该天无法承接的部分重新分给仍有剩余容量的日期"。
///   水位算法天然满足这一点：某一日到顶后就不再被选中，剩余分钟自动流向其他日期。
/// - **已排分钟计入水位**。否则"已锁定 30 分钟的那天"会被当成还空着，从而再拿满一整份，
///   结果是锁定块把当天的总量顶到远超其他日期（计划 §3.3）。
/// - **总量精确**：能分配的部分一定恰好等于 `allocatableMinutes`，不丢分钟也不超排。
/// - `targetMinutes` 小于一个粒度时，仍按"最终余量可短于最小片段"的既有规则分配
///   （路线图 Task 12A：余量本身就是最后一段时，让它短于下限，而不是拒绝安排）。
EvenDistributionPlan allocateEvenDistribution(EvenDistributionInput input) {
  final target = input.targetMinutes;
  final granularity = input.granularityMinutes;

  // 每个日期还**剩**多少可承接分钟 = 总容量 − 该日已经占用的分钟。
  //
  // **一个字段一个含义**：`capacityMinutesByLocalDate` 是这一天的总许可量，
  // `alreadyPlannedMinutesByLocalDate` 是其中已经被占用的部分。我第一版把前者一会儿当总量、
  // 一会儿当余量，于是"已排 30 分钟的那天"被算成还空着 30 分钟——测试当场抓住了它。
  final headroom = <DateTime, int>{};
  for (final date in input.capacityMinutesByLocalDate.keys.toList()..sort()) {
    final capacity = input.capacityMinutesByLocalDate[date]!;
    final already = input.alreadyPlannedMinutesByLocalDate[date] ?? 0;
    final free = capacity - already;
    if (free > 0) headroom[date] = free;
  }
  final active = headroom.keys.toList()..sort();
  final totalHeadroom = headroom.values.fold<int>(
    0,
    (sum, value) => sum + value,
  );
  final allocated = <DateTime, int>{for (final date in active) date: 0};

  // 目标为 0、或没有任何还有余量的日期：不分配，缺口如实。
  if (target <= 0 || active.isEmpty) {
    return EvenDistributionPlan(
      finalMinutesByLocalDate: UnmodifiableMapView({
        for (final date in active)
          date:
              (input.alreadyPlannedMinutesByLocalDate[date] ?? 0) +
              (allocated[date] ?? 0),
      }),
      additionalMinutesByLocalDate: const {},
      allocatableMinutes: 0,
      shortageMinutes: target,
    );
  }

  // ── 参与日期的个数：**每个参与日期至少拿到 minChunk**（计划 §3.1 第 1 条）────────
  //
  // 这一条是被真实缺陷逼出来的。180 分钟、minChunk 30、窗口覆盖 **8** 个本地日时，
  // 朴素水位分配给出 `25 × 4 + 20 × 4`——**每天都不足一个最小片段**，于是引擎一个候选都
  // 用不上，`ranked` 为空，任务整周排不进去（实测 `candidates=1304` 却 `blocks=0`，
  // 拒绝原因是 `dailyLimitReached` 且 `availableMinutes=25`）。
  //
  // "每天 25 分钟"不是"均匀"，那是**不可用的预算**。正确做法是让参与日期的个数 K 满足
  // `K × minChunk ≤ target ≤ 这些日期的总余量`，并在其中取**最大**的 K（K 越大每天越少、
  // 越均匀）。找不到这样的 K 时才退回尽量分配。
  final minChunk = input.minChunkMinutes;
  // ── K 日选择：**按稳定轮换键排序，禁止按日期取前 K 个**（计划 §3.4 第 6、7 条）────
  //
  // 修复前的判据是"余量降序、日期升序"再取前 K 个。七天余量完全相同时，
  // 那个判据**永远**选中周一至周五——用户看到的是"工作日越来越挤、周末一直空着"
  // （计划 §1.2 第 3 条），而不是容量不够。
  //
  // 现在排序键分成两级：
  // 1. **余量降序**：余量更大的日期更值得承担（容量证据优先）；
  // 2. **轮换位次升序**，再按日期 —— 由 `AllocationRotation` 从
  //    `SHA-256(taskId)` 前 8 字节与周期序号算出（**不用 `hashCode`、不用随机数**），
  //    因此同一周期逐值稳定，而周期推进时起始星期轮转。
  final rotation = AllocationRotation.forTask(
    taskId: input.rotationTaskId,
    cycleStartLocalDate: input.cycleStartLocalDate,
  );
  final byRanking = [...active]
    ..sort((a, b) {
      final byRoom = headroom[b]!.compareTo(headroom[a]!);
      if (byRoom != 0) return byRoom;
      final byRotation = rotation
          .rotationRank(a)
          .compareTo(rotation.rotationRank(b));
      if (byRotation != 0) return byRotation;
      return a.compareTo(b);
    });
  var chosen = <DateTime>[];
  for (var k = byRanking.length; k >= 1; k--) {
    final candidates = byRanking.take(k).toList()..sort();
    final room = candidates.fold<int>(0, (sum, date) => sum + headroom[date]!);
    if (k * minChunk <= target && target <= room) {
      chosen = candidates;
      break;
    }
  }
  // 没有任何 K 满足（例如总余量本身不足 K × minChunk）：退回全部有余量的日期，
  // 由下面的水位分配尽量排，缺口如实汇报。
  final participating = chosen.isEmpty ? active : chosen;
  final participatingHeadroom = {
    for (final date in participating) date: headroom[date]!,
  };

  // 容量感知的水位分配：每轮把一个粒度分给"当前新增最少且仍有余量"的日期，
  // 同量时取本地日期升序（`participating` 已升序，因此只在严格更小时改写即可保证这一点）。
  //
  // 步长是粒度；目标不是粒度整数倍时最后剩的余量**照旧分配**，否则会丢分钟。
  var remaining = target;
  while (remaining > 0) {
    final step = remaining < granularity ? remaining : granularity;
    DateTime? best;
    var bestAllocated = 0;
    for (final date in participating) {
      final allocatedHere = allocated[date]!;
      if (allocatedHere + step > participatingHeadroom[date]!) continue;
      if (best == null || allocatedHere < bestAllocated) {
        best = date;
        bestAllocated = allocatedHere;
      }
    }
    if (best == null) break; // 所有参与日期都到顶：剩下的就是缺口。
    allocated[best] = allocated[best]! + step;
    remaining -= step;
  }

  final finalMinutes = <DateTime, int>{
    for (final date in active)
      date:
          (input.alreadyPlannedMinutesByLocalDate[date] ?? 0) +
          allocated[date]!,
  };
  final additional = <DateTime, int>{
    for (final date in active)
      if (allocated[date]! > 0) date: allocated[date]!,
  };
  final allocatedTotal = target - remaining;
  return EvenDistributionPlan(
    finalMinutesByLocalDate: UnmodifiableMapView(finalMinutes),
    additionalMinutesByLocalDate: UnmodifiableMapView(additional),
    // `allocatableMinutes` 是"这些日期合起来能为**本次**承接多少"，
    // 因此同时受目标与剩余余量约束。`alreadyTotal` 是已经占用的部分，不计入本次可分配量。
    allocatableMinutes: allocatedTotal < totalHeadroom
        ? allocatedTotal
        : totalHeadroom,
    shortageMinutes: remaining,
  );
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
