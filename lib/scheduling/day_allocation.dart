// 全局跨日预算分配器（算法 17，计划
// `2026-10-16-capacity-aware-hierarchical-scheduler-repair.md` §3.4 / §7 / Task 5）。
//
// ## 它解决什么
//
// 算法 16 的日期选择没有独立的**日负载**目标：候选评分相同后按最早开始时间打破
// 平局，于是天然向窗口前部聚集（计划 §1.2 第 4 条）。用户看到的是
// 「工作日越来越挤、周末整周空着」——不是容量不够，是**选择顺序**不对。
//
// 这个文件把"哪一天承担多少分钟"从"这一天内部放在几点"里**彻底拆出来**：
// 跨日阶段只产出**每日分钟预算**，日内选点交给既有候选评分（计划 §3.1 的两层分工）。
//
// ## 三层判据（严格字典序，禁止加权求和）
//
// 1. **日期身份**：这个日期是否合法（允许星期、截止、还有余量）；
// 2. **日负载**：放入之后**最大日负载率**与**超目标水位总量**谁更小；
// 3. **稳定轮换键**：业务字段完全相同时按周期轮换，避免每周永久排除同一星期。
//
// 第 3 层不是装饰：没有它，七天的容量与负载完全相同时会**永远**选中同一批日期，
// 而"完全同分"在真实输入里非常常见（周末无事、每天同样的课表）。
//
// ## 确定性
//
// - 所有 `Map` 迭代前先按日期排序（Dart 的 Map 顺序取决于插入顺序）；
// - 同分用**按周期轮换的稳定键**打破，而它由 `SHA-256(taskId)` 前 8 字节与
//   周期序号算出——**不使用 `hashCode`、不使用随机数**（计划 §3.4 第 7 条）；
// - 同一输入连跑多次必须逐值相同。
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';

/// 分配一个任务时需要知道的、与**日期无关**的那部分（计划 §6 `DayAllocationInput`）。
final class DayAllocationInput {
  DayAllocationInput({
    required List<SchedulableTask> tasks,
    required this.ledger,
    required Map<String, Map<DateTime, int>> alreadyPlannedByTask,
    required this.timeZoneId,
    required Map<String, DateTime> cycleStartByTask,
    required this.granularityMinutes,
    Map<String, int>? targetMinutesByTask,
    Map<String, int> alreadyScheduledMinutesByTask = const {},
    this.maxReallocationPasses = 3,
    this.maxAllocationStates = 10000,
  }) : tasks = UnmodifiableListView(List.of(tasks)),
       alreadyPlannedByTask = UnmodifiableMapView({
         for (final entry in alreadyPlannedByTask.entries)
           entry.key: UnmodifiableMapView(Map.of(entry.value)),
       }),
       cycleStartByTask = UnmodifiableMapView(Map.of(cycleStartByTask)),
       targetMinutesByTask = targetMinutesByTask == null
           ? null
           : UnmodifiableMapView(Map.of(targetMinutesByTask)),
       alreadyScheduledMinutesByTask = UnmodifiableMapView(
         Map.of(alreadyScheduledMinutesByTask),
       ) {
    if (granularityMinutes <= 0) {
      throw ArgumentError.value(granularityMinutes, 'granularityMinutes');
    }
    if (maxReallocationPasses < 0) {
      throw ArgumentError.value(maxReallocationPasses, 'maxReallocationPasses');
    }
    if (maxAllocationStates <= 0) {
      throw ArgumentError.value(maxAllocationStates, 'maxAllocationStates');
    }
  }

  final List<SchedulableTask> tasks;
  final DayCapacityLedger ledger;

  /// 每个任务在每个本地日**已经**占用的分钟（锁定块与既有可移动块）。
  final Map<String, Map<DateTime, int>> alreadyPlannedByTask;

  final String timeZoneId;

  /// 每个任务所属周期的起点本地日期（用于轮换键）。缺省表示"没有周期"。
  final Map<String, DateTime> cycleStartByTask;

  final int granularityMinutes;

  /// **本次要为每个任务安排的分钟**（契约 §3.2）。
  ///
  /// 引擎的"这次要排多少"**不是** `task.requiredMinutes`，而是
  /// `_targetFor(problem, task)` 的结果。分配器若自己用 `requiredMinutes` 推，
  /// 两边从第一步就不一致。为 `null` 时退化为按 `requiredMinutes` 推
  /// （只服务纯函数调用点）；**生产路径必须显式传引擎的目标**。
  final Map<String, int>? targetMinutesByTask;

  /// 引擎侧已经为每个任务排定的分钟（`scheduledByTask`）。
  ///
  /// [alreadyPlannedByTask] 与它**同源**，因此不能两次都减：传引擎的剩余量时，
  /// 这里传同一个 `scheduledByTask` 让分配器**减回去**。
  final Map<String, int> alreadyScheduledMinutesByTask;

  /// 最多执行几轮"预算落地失败后重新分配"（计划 §3.4 第 10 条 / §6）。
  final int maxReallocationPasses;

  /// 最多访问多少个分配状态（计划 §3.6 第 5 条）。
  final int maxAllocationStates;
}

/// 一个任务在某个本地日的**新增**分钟上限（计划 §6 `TaskDayBudget`）。
final class TaskDayBudget {
  TaskDayBudget({
    required this.taskId,
    required Map<DateTime, int> minutesByLocalDate,
    required this.allocatedMinutes,
    required this.shortageMinutes,
  }) : minutesByLocalDate = UnmodifiableMapView({
         for (final entry in minutesByLocalDate.entries)
           if (entry.value > 0) entry.key: entry.value,
       });

  final String taskId;

  /// 该任务当天可以新增的分钟（只含**正**预算的日期）。
  final Map<DateTime, int> minutesByLocalDate;

  /// 本次实际许诺的总分钟（等于 [minutesByLocalDate] 之和）。
  final int allocatedMinutes;

  /// 没能许诺出去的分钟（真实缺口）。
  final int shortageMinutes;
}

/// 全部任务的日期预算（计划 §6 `DayAllocationPlan`）。
final class DayAllocationPlan {
  DayAllocationPlan({
    required Map<String, TaskDayBudget> budgetsByTaskId,
    required this.finalLedger,
    required this.outcome,
    required this.visitedStateCount,
  }) : budgetsByTaskId = UnmodifiableMapView(Map.of(budgetsByTaskId));

  final Map<String, TaskDayBudget> budgetsByTaskId;

  /// 分配结束时的账本（`finalLedger`）。调用方据此知道每天还剩多少。
  final DayCapacityLedger finalLedger;

  final SearchOutcomeKind outcome;

  /// 本次分配访问过的状态数（有界，见 `maxAllocationStates`）。
  final int visitedStateCount;

  TaskDayBudget? budgetFor(String taskId) => budgetsByTaskId[taskId];
}

/// 为一个任务在某一天要放的一段（计划 §7 的 `buildAllocationChunks`）。
///
/// 分解规则与候选生成**同源**：尽量放一个最大片段，余量不足时退回一个合法短尾。
/// 它只决定"跨日阶段按什么粒度考虑"，具体时长仍由日内候选生成最终决定。
List<int> buildAllocationChunks({
  required SchedulableTask task,
  required int targetMinutes,
  required int granularityMinutes,
}) {
  if (targetMinutes <= 0) return const [];
  final minChunk = task.minChunkMinutes <= 0 ? 1 : task.minChunkMinutes;
  final maxChunk = task.maxChunkMinutes <= 0 ? minChunk : task.maxChunkMinutes;
  if (task.splitMode == TaskSplitMode.continuous) {
    // 连续任务只能整块放置：一段就是全部目标。
    return [targetMinutes];
  }
  final chunks = <int>[];
  var remaining = targetMinutes;
  while (remaining > 0) {
    if (remaining <= maxChunk) {
      // 最后一段允许短于最小片段——这正是既有"唯一短尾"契约。
      chunks.add(remaining);
      break;
    }
    chunks.add(maxChunk);
    remaining -= maxChunk;
  }
  // 若最后的短尾不足一个粒度，把它并进前一段（避免产生排不出来的碎片）。
  if (chunks.length > 1 && chunks.last < granularityMinutes) {
    final tail = chunks.removeLast();
    chunks[chunks.length - 1] = chunks.last + tail;
  }
  // 单段且短于最小片段：仍然保留（调用方按"唯一短尾"处理）。
  assert(chunks.fold<int>(0, (sum, value) => sum + value) == targetMinutes);
  return chunks;
}

/// 把全部任务的分钟分配到本地日期上（计划 §7 的伪代码）。
///
/// ## 顺序：受限优先（计划 §3.4 第 1、2 条）
///
/// 连续任务与可选日期最少的任务**先**分配，避免灵活任务抢走稀缺日期；
/// 同等受限时按"截止更早 → 截止压力更高 → 优先级更高 → ID 更小"。
DayAllocationPlan allocateTaskDays(DayAllocationInput input) {
  var ledger = input.ledger;
  var visited = 0;
  var exhausted = false;

  // 只处理窗口覆盖到的日期，并且**按日期升序**迭代（Map 顺序不得泄漏到结果里）。
  final allDates = ledger.localDates;
  if (allDates.isEmpty) {
    return DayAllocationPlan(
      budgetsByTaskId: const {},
      finalLedger: ledger,
      outcome: SearchOutcomeKind.solved,
      visitedStateCount: 0,
    );
  }

  final ordered = [...input.tasks]
    ..sort((a, b) {
      return compareTasksForAllocation(a, b, input, allDates);
    });

  final budgets = <String, TaskDayBudget>{};
  for (final task in ordered) {
    final planned = input.alreadyPlannedByTask[task.id] ?? const {};
    final plannedTotal = planned.values.fold<int>(
      0,
      (sum, value) => sum + value,
    );
    // **目标来自调用方**（契约 §3.2），并只扣一次同源分钟。
    final target = input.targetMinutesByTask?[task.id] ?? task.requiredMinutes;
    final remaining =
        target -
        (plannedTotal - (input.alreadyScheduledMinutesByTask[task.id] ?? 0));
    if (remaining <= 0) {
      budgets[task.id] = TaskDayBudget(
        taskId: task.id,
        minutesByLocalDate: const {},
        allocatedMinutes: 0,
        shortageMinutes: 0,
      );
      continue;
    }

    final eligible = _eligibleDates(task, input, allDates);
    final rotation = AllocationRotation.forTask(
      taskId: task.id,
      cycleStartLocalDate: input.cycleStartByTask[task.id],
    );

    if (eligible.isEmpty) {
      budgets[task.id] = TaskDayBudget(
        taskId: task.id,
        minutesByLocalDate: const {},
        allocatedMinutes: 0,
        shortageMinutes: remaining,
      );
      continue;
    }

    // ── 一轮分配：按"放入后的日负载"逐个片段挑日期（计划 §3.4 第 3、4、5 条）────
    final allocated = <DateTime, int>{};
    var remainingToAllocate = remaining;
    final targetPermille = _targetUtilizationPermille(ledger, input, allDates);

    // ── 片段预算：把目标切成"粒度整数倍"的片段（计划 §3.4 第 7 条末段）──────────
    //
    // 片段大小取 `min(最小片段, 自己的最大片段) 向上取整到粒度`：
    // 它是"这一天至少要承担一份"的量，因此**K = 需求 ÷ 片段大小**就是参与日期数。
    // 计划 §3.4 第 6 条要的正是"选择 K 个'放入后目标最优'的日期，禁止按日期取前 K 个"。
    final chunkMinutes = task.splitMode == TaskSplitMode.continuous
        ? remainingToAllocate
        : _allocationChunkMinutes(task, input.granularityMinutes);

    // 连续任务不可能被切开：只有"整体放下"或"一点也放不下"。
    if (task.splitMode == TaskSplitMode.continuous) {
      if (visited < input.maxAllocationStates) {
        // 连续任务整块放，因此"目标最优的日期"就是唯一判据（没有片段摊分可言）。
        final rankedForContinuous = _rankEligibleDates(
          allocationInput: input,
          eligible: eligible,
          task: task,
          ledger: ledger,
          alreadyPlanned: planned,
          rotation: rotation,
          targetPermille: targetPermille,
        );
        final date = rankedForContinuous.isEmpty
            ? null
            : rankedForContinuous.first;
        if (date != null) {
          final headroom = _headroomOf(
            ledger: ledger,
            input: input,
            task: task,
            date: date,
            alreadyPlanned: planned,
            allocatedNow: allocated,
          );
          if (headroom >= remainingToAllocate) {
            allocated[date] = remainingToAllocate;
            ledger = ledger.allocate(date, remainingToAllocate);
            remainingToAllocate = 0;
          }
        }
        visited++;
      } else {
        exhausted = true;
      }
      budgets[task.id] = TaskDayBudget(
        taskId: task.id,
        minutesByLocalDate: allocated,
        allocatedMinutes: allocated.values.fold<int>(
          0,
          (sum, value) => sum + value,
        ),
        shortageMinutes: remainingToAllocate,
      );
      continue;
    }

    // ── 日期排序：按"放入后的日负载"逐级比较（计划 §3.4 第 3、4、5 条）──────────
    //
    // **先排序、再取前 K 个**是关键：计划 §3.4 第 6 条明令"当目标只能覆盖 K 个最小片段时，
    // 选择 K 个'放入后目标最优'的日期，**禁止按日期取前 K 个**"。
    final ranked = _rankEligibleDates(
      allocationInput: input,
      eligible: eligible,
      task: task,
      ledger: ledger,
      alreadyPlanned: planned,
      rotation: rotation,
      targetPermille: targetPermille,
    );

    if (chunkMinutes <= 0) {
      budgets[task.id] = TaskDayBudget(
        taskId: task.id,
        minutesByLocalDate: const {},
        allocatedMinutes: 0,
        shortageMinutes: remainingToAllocate,
      );
      continue;
    }

    // ── 落地：K 天轮转，每天最多承担 `maxChunkMinutes`（计划 §3.4 第 6 条）──────
    //
    // **轮转而不是贪心**：贪心会让"当前最空的那一天"反复被选中，直到它变忙为止——
    // 于是 150 分钟会全落在两天上（实测），而那正是"参与日不得只是前五天"要避免的
    // 同一种形状。轮转保证 K 天各承担一份，之后才回头补齐。
    final neededChunks =
        (remainingToAllocate + chunkMinutes - 1) ~/ chunkMinutes;
    // **每个参与日至少拿到一个 `chunkMinutes`**（计划 §3.1 第 1 条）。
    //
    // 这条约束此前在 `even` 分支里**漏了**（那一版写 `participantCount = ranked.length`，
    // 让 K 等于可用日总数）。实测「180 分钟、8 个可用日、minChunk 30」被摊成
    // 每天 20~25 分钟——**每天都不够放一块**，引擎排出 0 块，
    // 诊断为 `unexplainedSchedulingFailure`。计划的判词很直白：
    //
    // > "每天 25 分钟"不是"均匀"，那是**不可用的预算**。
    //
    // 正确判据：`K × chunkMinutes ≤ 目标`，即 K 最多 `目标 ÷ chunkMinutes`
    // （180÷30 = 6 ⇒ 6 天各 30；150÷30 = 5 ⇒ 5 天各 30——后者正是 Task 1 的
    // 「150/30 不得固定选择前五个日期」所要求的 K=5）。
    final maxByChunk = chunkMinutes <= 0
        ? ranked.length
        : remainingToAllocate ~/ chunkMinutes;
    final cappedByChunk = maxByChunk < ranked.length
        ? maxByChunk
        : ranked.length;
    final participantCount =
        task.distributionPolicy == TaskDistributionPolicy.even
        ? cappedByChunk
        : (neededChunks < ranked.length ? neededChunks : ranked.length);
    final participants = ranked.take(participantCount).toList();

    // ── `even` 任务：**按天数等分**，不走轮转循环（契约 §7.2）───────────────────
    //
    // 轮转写法对 `even` 必然算错：它每轮给每个参与日各加一个 `chunkMinutes`，
    // 于是余数**永远落在排名第一的那天**。实测"目标 210、四天各余 120、粒度 5"：
    //
    // ```text
    // 第 1 轮 [50, 50, 50, 50]，剩 10 ⇒ 第 2 轮第一名 +10 ⇒ [60, 50, 50, 50]
    // ```
    //
    // 而计划 §3.1 要的"每天尽量均衡"是 **`[55, 55, 50, 50]`**
    // （两个 50、两个 55 —— `recurring_even_distribution_test` 钉住的形状）。
    //
    // 正确判据：先给每个参与日 `base = ⌊目标 / K⌋`（向下取整到粒度），
    // 再把余量按**粒度**逐份发给排名靠前的日期。
    if (task.distributionPolicy == TaskDistributionPolicy.even) {
      final granularity = input.granularityMinutes;
      final perDayBase =
          (remainingToAllocate ~/ participants.length) ~/
          granularity *
          granularity;
      var left = remainingToAllocate;
      for (final date in participants) {
        if (left <= 0) break;
        if (visited >= input.maxAllocationStates) {
          exhausted = true;
          break;
        }
        visited++;
        final headroom = _headroomOf(
          ledger: ledger,
          input: input,
          task: task,
          date: date,
          alreadyPlanned: planned,
          allocatedNow: allocated,
        );
        final wanted = perDayBase < left ? perDayBase : left;
        final minutes = wanted < headroom ? wanted : headroom;
        if (minutes <= 0) continue;
        allocated[date] = (allocated[date] ?? 0) + minutes;
        ledger = ledger.allocate(date, minutes);
        left -= minutes;
      }
      // 余量：按粒度逐份发给排名靠前的日期，直到发完或没有余量可放。
      var index = 0;
      while (left > 0 && !exhausted && index < participants.length) {
        final date = participants[index];
        if (visited >= input.maxAllocationStates) {
          exhausted = true;
          break;
        }
        visited++;
        final headroom = _headroomOf(
          ledger: ledger,
          input: input,
          task: task,
          date: date,
          alreadyPlanned: planned,
          allocatedNow: allocated,
        );
        final step = left < granularity ? left : granularity;
        final minutes = step < headroom ? step : headroom;
        if (minutes <= 0) {
          index++;
          continue;
        }
        allocated[date] = (allocated[date] ?? 0) + minutes;
        ledger = ledger.allocate(date, minutes);
        left -= minutes;
        // **必须前进到下一天**：否则余量会一次又一次地发给同一天，
        // 直到它被填满为止——那正是"余数全落在排名第一那天"的成因。
        //
        // 实测（`DIAG13`）：本应给 10-05、10-06 各 +5，却给 10-05 加了两次，
        // 得到 `[60, 50, 50, 50]` 而不是 `[55, 55, 50, 50]`。
        index++;
        if (left < granularity) break;
      }
      budgets[task.id] = TaskDayBudget(
        taskId: task.id,
        minutesByLocalDate: allocated,
        allocatedMinutes: allocated.values.fold<int>(
          0,
          (sum, value) => sum + value,
        ),
        shortageMinutes: left,
      );
      continue;
    }

    // `even`：在所有候选日之间摊（先每个日期各 1 个片段，再回头）；
    // 普通任务：先填满排名第一的日期，再轮到下一个 —— 它没有"任务自身均匀"这个目标。
    final cycle = participants;

    var placedAnything = true;
    while (remainingToAllocate > 0 && placedAnything && !exhausted) {
      placedAnything = false;
      for (final date in cycle) {
        if (remainingToAllocate <= 0) break;
        if (visited >= input.maxAllocationStates) {
          exhausted = true;
          break;
        }
        visited++;
        final headroom = _headroomOf(
          ledger: ledger,
          input: input,
          task: task,
          date: date,
          alreadyPlanned: planned,
          allocatedNow: allocated,
        );
        if (headroom <= 0) continue;
        // **一天可以承担任意多分钟**：`maxChunkMinutes` 限制的是**单个片段**的长度
        // （`PlanValidator.chunkAboveMaximum`），不是"一天的总量"——总量由当天许可容量
        // 与任务自己的 `maxMinutesPerLocalDay` 约束，而两者都已经算在 `headroom` 里。
        //
        // 第一版这里额外加了一个 `maxChunkMinutes` 的每日上限，于是"每天余 120、任务要
        // 240"只分到 90×2=180（实测），而计划并没有这条约束。
        // 每轮只放**一个片段**的量，因此同一天被轮到时自然形成多个独立片段。
        final wanted = chunkMinutes < remainingToAllocate
            ? chunkMinutes
            : remainingToAllocate;
        final minutes = wanted < headroom ? wanted : headroom;
        if (minutes <= 0) continue;
        allocated[date] = (allocated[date] ?? 0) + minutes;
        ledger = ledger.allocate(date, minutes);
        remainingToAllocate -= minutes;
        placedAnything = true;
      }
    }

    budgets[task.id] = TaskDayBudget(
      taskId: task.id,
      minutesByLocalDate: allocated,
      allocatedMinutes: allocated.values.fold<int>(
        0,
        (sum, value) => sum + value,
      ),
      shortageMinutes: remainingToAllocate,
    );
  }

  // ── 结果状态（计划 §3.6 第 6 条：达限**不得**声称无解）──────────────────────
  final totalShortage = budgets.values.fold<int>(
    0,
    (sum, budget) => sum + budget.shortageMinutes,
  );
  final outcome = exhausted
      ? SearchOutcomeKind.budgetExhausted
      : (totalShortage > 0
            ? SearchOutcomeKind.hardInfeasible
            : SearchOutcomeKind.solved);

  return DayAllocationPlan(
    budgetsByTaskId: budgets,
    finalLedger: ledger,
    outcome: outcome,
    visitedStateCount: visited,
  );
}

/// 任务之间的分配顺序（计划 §3.4 第 1、2 条）。
///
/// 每一层都用**成对**判据固定，顺序为：
/// 1. 连续任务先于可拆分任务；
/// 2. 合法日期更少者先；
/// 3. 截止更早者先；
/// 4. 截止压力更高者先（同样截止下"需求 ÷ 可用容量"更大者）；
/// 5. 优先级更高者先；
/// 6. ID 更小者先（**稳定键**，不使用 `hashCode`）。
int compareTasksForAllocation(
  SchedulableTask a,
  SchedulableTask b,
  DayAllocationInput input,
  List<DateTime> allDates,
) {
  final aContinuous = a.splitMode == TaskSplitMode.continuous;
  final bContinuous = b.splitMode == TaskSplitMode.continuous;
  if (aContinuous != bContinuous) return aContinuous ? -1 : 1;

  final aDates = _eligibleDates(a, input, allDates).length;
  final bDates = _eligibleDates(b, input, allDates).length;
  if (aDates != bDates) return aDates.compareTo(bDates);

  final aDue = a.dueAtUtc;
  final bDue = b.dueAtUtc;
  if (aDue != null && bDue != null && aDue != bDue) {
    return aDue.compareTo(bDue);
  }
  if ((aDue == null) != (bDue == null)) return aDue == null ? 1 : -1;

  final aPressure = _deadlinePressure(a, input, allDates);
  final bPressure = _deadlinePressure(b, input, allDates);
  if (aPressure != bPressure) return bPressure.compareTo(aPressure);

  final byPriority = b.priority.index.compareTo(a.priority.index);
  if (byPriority != 0) return byPriority;

  return a.id.compareTo(b.id);
}

/// 截止压力：目标分钟 ÷ 截止之前仍可承接的分钟（千分比，整数）。
///
/// 只用于**排序**，不参与任何硬判定；没有截止时记 0（压力最低）。
int _deadlinePressure(
  SchedulableTask task,
  DayAllocationInput input,
  List<DateTime> allDates,
) {
  final dueAt = task.dueAtUtc;
  if (dueAt == null) return 0;
  var capacity = 0;
  for (final date in _eligibleDates(task, input, allDates)) {
    capacity += input.ledger.forDate(date).remainingMinutes;
  }
  if (capacity <= 0) return 1 << 20;
  return (task.requiredMinutes * 1000) ~/ capacity;
}

/// 该任务**可以**放的那些本地日期（计划 §3.4 第 1 条：合法日期最少的任务先分配）。
///
/// 判据只有三条，且都是硬约束：允许星期、截止、当天仍有余量。
/// 片段形状与休息在日内阶段判定——跨日阶段把它们算进来会让"合法日期"随粒度变化，
/// 而那正是"两个模块对同一约束给出不同结果"的来源。
List<DateTime> _eligibleDates(
  SchedulableTask task,
  DayAllocationInput input,
  List<DateTime> allDates,
) {
  final dueAt = task.dueAtUtc;
  final availableFrom = task.availableFromUtc;
  final planned = input.alreadyPlannedByTask[task.id] ?? const {};
  final dates = <DateTime>[];
  for (final date in allDates) {
    if (!task.allowsWeekday(date.weekday)) continue;
    // ── 截止与最早开始：用**账本携带的 UTC 边界**，不再猜日键与时区的关系 ────────
    //
    // 判据（见 `docs/testing/day-allocation-engine-contract.md` §5.3）：
    //
    // ```text
    // 排除当且仅当  dayStartUtc >= dueAtUtc      // 这一天整段都在截止之后
    // 排除当且仅当  dayEndUtc   <= availableFromUtc
    // ```
    //
    // **不得**用 `DateTime(y, m, d ± 1)` 或 `DateTime.utc(y, m, d) + 24h` 当边界：
    // 前者把日键当本地零点、后者当 UTC 零点，两者都不是"这一天在目标时区下的
    // 真实边界"，而正确答案只有时区数据库知道。
    //
    // 实测（Task 6 六轮失败的根因）：`Asia/Shanghai` + 截止 `10-07T16:00Z`
    // （本地 10-08 零点）时，把起点算成 UTC 零点会让 10-05／10-06 的起点比截止
    // 早 40 小时，于是"应当可用"的日子被排除、"应当被截止排除"的日子被保留。
    final bounds = input.ledger.forDate(date);
    final dayStart = bounds.startUtc ?? _utcMidnight(date);
    final dayEnd =
        bounds.endUtc ??
        _utcMidnight(DateTime(date.year, date.month, date.day + 1));
    if (dueAt != null && !dayStart.isBefore(dueAt)) continue;
    if (availableFrom != null && !dayEnd.isAfter(availableFrom)) {
      continue;
    }
    final headroom = _headroomOf(
      ledger: input.ledger,
      input: input,
      task: task,
      date: date,
      alreadyPlanned: planned,
      allocatedNow: const {},
    );
    if (headroom <= 0) continue;
    dates.add(date);
  }
  return dates;
}

/// 分配片段的大小：`min(任务最小片段, 任务最大片段)` 向上取整到粒度。
///
/// 它是"这一天至少要承担一份"的量，因此 `K = 需求 ÷ 片段大小` 就是参与日期数
/// （计划 §3.4 第 6 条）。取**最小**片段而不是最大片段：用最大片段会让 K 偏小，
/// 于是同样的目标只落在更少的天上——那正是"工作日越来越挤"的形状。
int _allocationChunkMinutes(SchedulableTask task, int granularityMinutes) {
  final minChunk = task.minChunkMinutes <= 0
      ? granularityMinutes
      : task.minChunkMinutes;
  final maxChunk = task.maxChunkMinutes <= 0 ? minChunk : task.maxChunkMinutes;
  final base = minChunk < maxChunk ? minChunk : maxChunk;
  final rounded =
      ((base + granularityMinutes - 1) ~/ granularityMinutes) *
      granularityMinutes;
  return rounded <= 0 ? granularityMinutes : rounded;
}

/// 按"放入后的日负载"给候选日期排序（计划 §3.4 第 3、4、5、6 条）。
///
/// 判据逐级为：
/// 1. **放入后的负载率**（越低越好）——比较的是放入后的量，不是原始空闲；
/// 2. **超目标水位的量**（越少越好）；
/// 3. 该任务当天已有的分钟（**只有 `even` 任务**用这一级，见下）；
/// 4. **稳定轮换键**（计划 §3.4 第 7 条）；
/// 5. 本地日期（最后的稳定键，绝不用 `hashCode`）。
///
/// ## 为什么 `even` 才看第三级
///
/// 计划 §3.4 第 5 条要求 `even` 任务**同时**最小化"任务自身日分钟差异"与
/// "全局日负载差异"，并规定**全局负载略优先**。因此任务自身的量只作为
/// **第二级之后**的判据：先把全局负载比完，平了再看任务自己的日分钟。
/// 把两者相加会让"任务均匀"补偿"全局过载"。
List<DateTime> _rankEligibleDates({
  required DayAllocationInput allocationInput,
  required List<DateTime> eligible,
  required SchedulableTask task,
  required DayCapacityLedger ledger,
  required Map<DateTime, int> alreadyPlanned,
  required AllocationRotation rotation,
  required int targetPermille,
}) {
  final balanceAware = task.distributionPolicy == TaskDistributionPolicy.even;
  final entries = <({DateTime date, List<int> key})>[];
  for (final date in eligible) {
    final headroom = _headroomOf(
      ledger: ledger,
      input: allocationInput,
      task: task,
      date: date,
      alreadyPlanned: alreadyPlanned,
      allocatedNow: const {},
    );
    if (headroom <= 0) continue;
    final snapshot = ledger.forDate(date);
    final projected =
        snapshot.usedMovableMinutes +
        snapshot.allocatedMinutes +
        (alreadyPlanned[date] ?? 0) +
        _projectionStep(task, headroom);
    final projectedPermille = _permille(
      projected,
      snapshot.licensedCapacityMinutes,
    );
    final overTarget = projectedPermille > targetPermille
        ? projectedPermille - targetPermille
        : 0;
    entries.add((
      date: date,
      key: [
        projectedPermille,
        overTarget,
        if (balanceAware) alreadyPlanned[date] ?? 0,
        rotation.rotationRank(date),
        rotation.rotationOffset,
        date.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay,
      ],
    ));
  }
  entries.sort((a, b) => _compareKeys(a.key, b.key));
  return [for (final entry in entries) entry.date];
}

/// 分配给一个片段时**假设放多少分钟**（"放入之后"的语义，计划 §3.4 第 3 条）。
///
/// 判据是"放进一个片段之后这一天会变成什么样"，因此步长应当是**这一段实际会放的量**，
/// 而不是固定一个最小片段：
///
/// - 连续任务：整块（否则它永远排不进）；
/// - 可拆分任务：按最大片段算（一个片段实际能有多长）——
///   计划 §3.4 第 6 条要的正是"K 天各承担一份**片段**"。
///
/// **第一版取的是 `minChunkMinutes`**，于是七天各余 90 分钟时，
/// 每次只投影 30 分钟 ⇒ 同一批日期永远看起来最空 ⇒ 150 分钟全落在**两天**上
/// （实测"选择 5 天"的用例得到 2 天）。步长必须反映"这一段会占多少"。
int _projectionStep(SchedulableTask task, int headroom) {
  final step = task.splitMode == TaskSplitMode.continuous
      ? task.requiredMinutes
      : task.maxChunkMinutes;
  final effective = step <= 0 ? headroom : step;
  return effective < headroom ? effective : headroom;
}

/// 手写夹具未提供时区边界时的退化：把日键当作 UTC 日零点。
///
/// **生产路径不会走到这里**：`buildDayCapacityLedger` 总是显式填
/// `startUtc` / `endUtc`。这个缺省只让"只想描述某天容量"的单元测试夹具
/// 仍然可用，代价是那些夹具不能表达跨时区的截止语义。
DateTime _utcMidnight(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

/// 这一天该任务还能新增多少分钟。
///
/// 同时受三个上限约束，取最小值：
/// 1. 账本剩余的许可容量（`DayCapacitySnapshot.remainingMinutes`）；
/// 2. 该任务自己的单日上限 `maxMinutesPerLocalDay`；
/// 3. 该任务当天**已排**的分钟所占的份额。
int _headroomOf({
  required DayCapacityLedger ledger,
  required DayAllocationInput input,
  required SchedulableTask task,
  required DateTime date,
  required Map<DateTime, int> alreadyPlanned,
  required Map<DateTime, int> allocatedNow,
}) {
  final snapshot = ledger.forDate(date);
  final ledgerRemaining = snapshot.remainingMinutes;
  final perDayLimit = task.maxMinutesPerLocalDay;
  if (perDayLimit == null) return ledgerRemaining;
  final used = (alreadyPlanned[date] ?? 0) + (allocatedNow[date] ?? 0);
  final quotaRemaining = perDayLimit - used;
  final capped = quotaRemaining < ledgerRemaining
      ? quotaRemaining
      : ledgerRemaining;
  return capped < 0 ? 0 : capped;
}

/// 选出"放入后目标最优"的日期（计划 §3.4 第 3、4、5 条 + 第 6 条）。
///
/// ## 判据是**放入之后**的量，不是放入之前的空闲
///
/// 计划 §3.4 第 3 条明确："日期选择比较'放入后'的最终负载率，不比较原始空闲分钟"。
/// 用原始空闲会让一个"空闲 600、但已有 590 分钟负载"的日子看起来比
/// "空闲 100、负载 0"的日子更空。
///
/// ## 为什么是两次比较而不是一个分数
///
/// 计划 §3.4 第 5 条要求 `even` 任务**同时**最小化"任务自身日分钟差异"与
/// "全局日负载差异"，并规定"全局负载略优先"。因此 `taskBalanceAware` 只影响
/// **第二个**比较键：先在全局负载上比，平了再看任务自己的日分钟。
/// 把两者相加会让"任务均匀"补偿"全局过载"，而那正是要避免的。
/// 字典序比较两个键（负数表示 [a] 更优）。
int _compareKeys(List<int> a, List<int> b) {
  final length = a.length < b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) {
    final order = a[index].compareTo(b[index]);
    if (order != 0) return order;
  }
  return a.length.compareTo(b.length);
}

int _permille(int numerator, int licensed) {
  if (licensed <= 0) return numerator <= 0 ? 0 : 1001;
  if (numerator <= 0) return 0;
  return (numerator * 1000 + licensed - 1) ~/ licensed;
}

/// 目标水位（计划 §3.3）：`clamp(ceil(totalProjected × 1000 / totalLicensed), 0, 1000)`。
///
/// **比较多个方案时必须用同一个输入推导出的水位**，因此它在一次分配开始时算一次。
int _targetUtilizationPermille(
  DayCapacityLedger ledger,
  DayAllocationInput input,
  List<DateTime> allDates,
) {
  var projected = 0;
  var licensed = 0;
  for (final date in allDates) {
    final snapshot = ledger.forDate(date);
    licensed += snapshot.licensedCapacityMinutes;
    projected += snapshot.usedMovableMinutes + snapshot.allocatedMinutes;
  }
  for (final task in input.tasks) {
    final planned = input.alreadyPlannedByTask[task.id];
    if (planned == null) continue;
    for (final minutes in planned.values) {
      projected += minutes;
    }
  }
  if (licensed <= 0) return 0;
  final value = (projected * 1000 + licensed - 1) ~/ licensed;
  if (value < 0) return 0;
  return value > 1000 ? 1000 : value;
}

/// 按周期轮换的稳定日期顺序（计划 §3.4 第 7 条）。
///
/// ```text
/// taskSeed       = SHA-256(UTF-8(taskId)) 的前 8 字节，按**大端**解释为无符号整数
/// cycleOrdinal   = floor(daysBetween(1970-01-05, cycleStartLocalDate) / 7)
/// rotationOffset = (taskSeed + cycleOrdinal) mod 7
/// rotationRank   = (localDate.weekday - 1 - rotationOffset) mod 7
/// ```
///
/// 排序时**先按 rotationRank、再按本地日期**，于是：
/// - 同一周期逐值稳定（`taskSeed` 与 `cycleOrdinal` 都是确定的）；
/// - 周期推进时起始星期轮转，不会每周永久排除同一星期。
///
/// **不使用 Dart 的 `hashCode`，也不使用随机数**（计划 §3.4 第 7 条末句）：
/// `hashCode` 在不同运行之间不保证一致，会直接破坏"相同输入逐值相同"。
final class AllocationRotation {
  const AllocationRotation._(this.rotationOffset);

  /// **空 token 的偏移恒为 0**（见 [AllocationRotation.empty]）。
  factory AllocationRotation.forTask({
    required String? taskId,
    DateTime? cycleStartLocalDate,
  }) {
    // **没有身份就没有轮换**（`taskId == null`）：偏移恒为 0，于是"轮换位次"
    // 退化成星期序号，日期选择回到"余量降序 → 日期升序"。
    //
    // 注意**不能**用空串去算摘要：`SHA-256("")` 是一个真实的非零值，
    // 那会给出一个莫名其妙的固定偏移（实测 `taskId: ''` 得到偏移 4），
    // 而"没有身份"应当是一个**显式的退化**，不是一个巧合的常数。
    if (taskId == null) return const AllocationRotation._(0);
    final seed = _taskSeed(taskId);
    final cycle = cycleStartLocalDate == null
        ? 0
        : _cycleOrdinal(cycleStartLocalDate);
    return AllocationRotation._((seed + cycle) % 7);
  }

  /// 没有身份时的退化实例（偏移 0）。纯函数调用点与测试夹具用它。
  static const AllocationRotation empty = AllocationRotation._(0);

  /// `0..6`：本周期的起始星期偏移。
  final int rotationOffset;

  /// 该日期在轮换顺序里的位次（`0..6`，越小越先被选中）。
  int rotationRank(DateTime localDate) {
    final value = (localDate.weekday - 1 - rotationOffset) % 7;
    // Dart 的 `%` 对负数返回负数，必须规范化为 `((v % 7) + 7) % 7`（计划 §3.4 第 7 条）。
    return ((value % 7) + 7) % 7;
  }

  /// `SHA-256(UTF-8(taskId))` 的前 8 字节按**大端**解释为无符号整数。
  ///
  /// 只用前 8 字节而不是整个摘要：轮换只需要 `mod 7`，
  /// 而"取前 8 字节"是计划写死的算法，换成别的取法会让同一周期跨实现不一致。
  static int _taskSeed(String taskId) {
    final digest = sha256.convert(utf8.encode(taskId)).bytes;
    var value = 0;
    for (var index = 0; index < 8; index++) {
      value = (value << 8) | digest[index];
    }
    return value;
  }

  /// 距 `1970-01-05`（**周一**）过去了几个完整周。
  ///
  /// 用 UTC 日序号做整数除法：`_localMondayIndex` 已经把日期归一到本地自然日，
  /// 因此这里不会引入时区偏移。
  static int _cycleOrdinal(DateTime cycleStartLocalDate) {
    final start = DateTime.utc(
      cycleStartLocalDate.year,
      cycleStartLocalDate.month,
      cycleStartLocalDate.day,
    );
    final epoch = DateTime.utc(1970, 1, 5);
    final days = start.difference(epoch).inDays;
    // 向下取整（`~/` 对负数向零取整，因此负数要单独处理）。
    return days >= 0 ? days ~/ 7 : -((-days + 6) ~/ 7);
  }
}
