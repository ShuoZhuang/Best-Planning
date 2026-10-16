import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_eligibility.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 一件任务在**本次规划**里的容量证据（1.8.0，「可见空闲却报容量不足」专项 §1.6 / §2.3）。
///
/// ## 为什么需要它
///
/// 修复前引擎只用一个 `longestSlot` 与若干候选数就断定"可用时间不足"。用户看到的却是
/// 日历上大片的空档——因为那个数字与"这件任务真正能用的容量"是两件事：
///
/// | 名称 | 定义 | 用途 |
/// | --- | --- | --- |
/// | [calendarGapMinutes] | 窗口扣除固定日程、保护时间、睡眠、锁定块并按粒度对齐后的空闲**并集** | 日历层面还有多少空档 |
/// | [taskWindowMinutes] | 在日历空闲上继续应用任务的最早开始、截止、允许星期后的并集 | 这件任务能在哪些时段尝试 |
/// | [taskPlaceableMinutes] | 上面那些时段里满足连续/可拆分、最小/最大片段与粒度的可放置分钟 | 任务形状能利用多少容量 |
/// | [remainingPlaceableMinutes] | 再扣除**本次提案中已被其它任务占用**的部分后的可放置分钟 | 当前缺口的直接容量证据 |
///
/// **分钟按区间并集计算**，绝不把相互重叠的候选时长相加——候选是按"起点 × 时长"展开的，
/// 同一段空闲会产生成百上千个候选，直接累加会把容量放大到没有意义。
///
/// ## 不变量（实现后必须满足，由测试钉住）
///
/// ```text
/// 0 <= remainingPlaceableMinutes
///    <= taskPlaceableMinutes
///    <= taskWindowMinutes
///    <= calendarGapMinutes
/// ```
///
/// 任何一条失败都必须让测试失败，**不得**用 `clamp` 静默掩盖。
final class TaskCapacityEvidence {
  const TaskCapacityEvidence({
    required this.calendarGapMinutes,
    required this.taskWindowMinutes,
    required this.taskPlaceableMinutes,
    required this.remainingPlaceableMinutes,
    required this.largestTaskWindowGapMinutes,
    required this.largestRemainingGapMinutes,
    required this.dailyLimitRemainingMinutes,
  });

  /// 规划窗口内**真实空闲**的分钟并集（`AvailabilityAnalysis.calendarGapMinutes`）。
  final int calendarGapMinutes;

  /// 日历空闲再按任务的最早开始、截止与允许星期裁剪后的分钟并集。
  final int taskWindowMinutes;

  /// [taskWindowMinutes] 中满足片段形状（连续／可拆分、最小／最大片段、粒度）的可放置分钟。
  final int taskPlaceableMinutes;

  /// 再扣除本次提案中**已被其它任务占用**的部分后的可放置分钟。
  ///
  /// 这就是"当前缺口的直接容量证据"：`insufficientCapacity` 只能在这个数字
  /// **小于缺口**时使用。
  final int remainingPlaceableMinutes;

  /// [taskWindowMinutes] 里最长的一段**连续**可用区间（分钟）。
  ///
  /// 连续任务排不下时，用户要知道的是"最长的一段有多长"，而不是总容量：
  /// 前者改拆分方式或截止时间，后者才要腾时间。
  final int largestTaskWindowGapMinutes;

  /// [remainingPlaceableMinutes] 里最长的一段连续可用区间（分钟）。
  final int largestRemainingGapMinutes;

  /// 每日可移动上限在本次规划里还剩多少分钟（`0` 表示根本用不上这条规则）。
  ///
  /// 取**逐日剩余量的最大值**：`dailyLimitReached` 的用户文案是"当天/本次剩余上限 Y 分钟"，
  /// 而"今天已经满了、明天还有"是最常见的形状——报最大值才是那条规则真正给出的余量。
  final int dailyLimitRemainingMinutes;
}

/// 从**已经算好的**空闲分析、任务与已选块计算容量证据（纯函数）。
///
/// 契约：
/// - 不查数据库、不读 UI、**不读系统时钟**（"现在"由 `planningWindow.startUtc` 表达）；
/// - 所有分钟均 `>= 0`；
/// - 输入顺序不影响输出（区间先排序再合并）；
/// - **每日上限与粒度一律从 [ledger] / 逐日策略取**，不在本函数内部另算一套口径
///   （算法 17，计划 Task 3 Step 4：`analyzeTaskCapacity` 接同一账本，
///   删除内部重复计算每日总上限的路径）。
TaskCapacityEvidence analyzeTaskCapacity({
  required SchedulableTask task,
  required ScheduleProblem problem,
  required AvailabilityAnalysis availability,
  required DayCapacityLedger ledger,
  required List<PlannedBlock> allBlocks,
  required TimeZoneDatabase zones,
}) {
  final dueAtUtc = task.dueAtUtc;

  // ── 第一层：日历空闲（已经是并集，按本地日切过片）───────────────────────────
  final calendarGapMinutes = availability.calendarGapMinutes;

  // ── 第二层：任务窗口 ────────────────────────────────────────────────────────
  //
  // 依次裁三件事，顺序无关（都是区间求交）：最早开始、截止、允许星期。
  // 裁剪后的区间**重新合并**：两段被同一段保护时间切开的空闲在裁掉保护时间之前
  // 并不相邻（空闲里本来就没有保护时间），但不同 slot 之间可能因为粒度对齐而
  // 首尾相接，合并它们才能让 `largestTaskWindowGapMinutes` 说的是真实的连续长度。
  //
  // **粒度按 slot 所属本地日取**：同一次分析里可能混着工作日与周末的片段
  // （用户可以给周末配更细或更粗的网格），用一份粒度会给其中一类算错形状。
  final taskWindowRanges = <TimeRange>[];
  final granularityByRange = <TimeRange, int>{};
  for (final slot in availability.slots) {
    if (!task.allowsWeekday(slot.localDate.weekday)) continue;
    final dayGranularity = problem
        .policyForLocalDate(slot.localDate)
        .resolvedRules
        .granularityMinutes;
    var range = slot.range;
    final availableFrom = task.availableFromUtc;
    if (availableFrom != null && availableFrom.isAfter(range.startUtc)) {
      if (!range.endUtc.isAfter(availableFrom)) continue;
      range = TimeRange(startUtc: availableFrom, endUtc: range.endUtc);
    }
    if (dueAtUtc != null) {
      if (!dueAtUtc.isAfter(range.startUtc)) continue;
      if (range.endUtc.isAfter(dueAtUtc)) {
        range = TimeRange(startUtc: range.startUtc, endUtc: dueAtUtc);
      }
    }
    if (!range.endUtc.isAfter(range.startUtc)) continue;
    taskWindowRanges.add(range);
    granularityByRange[range] = dayGranularity;
  }
  final mergedWindow = _mergeRanges(taskWindowRanges);
  final taskWindowMinutes = _sumMinutes(mergedWindow);
  final largestTaskWindowGapMinutes = _largestMinutes(mergedWindow);

  // ── 第三层：可放置分钟 ──────────────────────────────────────────────────────
  //
  // 逐段判断"这一段的形状能不能放下至少一个片段"，只把**能放下**的分钟计入。
  // 见 `_placeableMinutes` 的说明：连续任务只认完整的一段，可拆分任务按最小片段与粒度切。
  final taskPlaceableMinutes = _placeableMinutes(
    ranges: mergedWindow,
    task: task,
    granularity: _granularityOf(problem, mergedWindow.firstOrNull),
  );

  // ── 第四层：扣除其它任务已经占用的部分 ──────────────────────────────────────
  //
  // 只扣**其它任务**的块：本任务自己在确认计划里的块由调用方决定是否计入
  // `allBlocks`（引擎传的是"本次生成到目前为止的全部块"，其中包含本任务先前放置的块 ——
  // 那些分钟已经算在 `scheduledByTask` 里，不该在这里再扣一次）。
  //
  // 休息间隔：两段排得太近会违反 `breakMinutes`，因此占用区间向两侧各扩
  // `breakMinutes / 2`，等价于"两个块之间要留出 breakMinutes"。
  final otherRanges = <TimeRange>[];
  for (final block in allBlocks) {
    if (block.taskId == task.id) continue;
    // 缓冲分钟同样按**候选所属本地日**取（同一条逐日纪律）。
    final buffer = Duration(
      minutes:
          problem
              .policyForLocalDate(
                localDateOf(block.startUtc, problem.timeZoneId, zones),
              )
              .resolvedRules
              .breakMinutes ~/
          2,
    );
    final expanded = _expand(block.range, buffer);
    for (final range in mergedWindow) {
      final overlap = _intersection(expanded, range);
      if (overlap != null) otherRanges.add(overlap);
    }
  }
  final freeAfterOthers = _subtract(mergedWindow, _mergeRanges(otherRanges));
  final remainingPlaceableMinutes = _placeableMinutes(
    ranges: freeAfterOthers,
    task: task,
    granularity: _granularityOf(problem, freeAfterOthers.firstOrNull),
  );
  final largestRemainingGapMinutes = _largestMinutes(freeAfterOthers);

  return TaskCapacityEvidence(
    calendarGapMinutes: calendarGapMinutes,
    taskWindowMinutes: taskWindowMinutes,
    taskPlaceableMinutes: taskPlaceableMinutes,
    remainingPlaceableMinutes: remainingPlaceableMinutes,
    largestTaskWindowGapMinutes: largestTaskWindowGapMinutes,
    largestRemainingGapMinutes: largestRemainingGapMinutes,
    dailyLimitRemainingMinutes: dailyLimitRemainingFrom(
      problem: problem,
      ledger: ledger,
    ),
  );
}

/// 取 [range] 所属本地日的粒度；[range] 为空时退回窗口首日的粒度。
///
/// 单独一个函数是为了让"退回"这件事只有一处：粒度是**日期敏感**的，而
/// "没有任何区间时用哪一份"必须有明确答案，不能靠调用点各自决定。
int _granularityOf(ScheduleProblem problem, TimeRange? range) => problem
    .policyForLocalDate(range?.startUtc ?? problem.planningWindow.startUtc)
    .resolvedRules
    .granularityMinutes;

/// 每日可移动上限在本次规划里**还剩**多少分钟（逐日余量的最大值）。
///
/// ## 口径来自账本，不再自己算一遍（算法 17，计划 Task 3 Step 4）
///
/// 修复前这里自己遍历 `allBlocks` 汇总未锁定块、再读窗口首日的上限——
/// 那是**第三份**"每日上限用了多少"的实现（另外两份在引擎与 `PlanValidator`）。
/// 现在它只读 [DayCapacityLedger]：账本的 `remainingMinutes` 已经同时表达了
/// "视觉空白还剩多少"与"许可容量还剩多少"，而 `usedMovableMinutes` 就是这一天的已用量。
///
/// **上限不小于一天时整条规则不生效**（返回 0），与引擎的短路判据一致。
int dailyLimitRemainingFrom({
  required ScheduleProblem problem,
  required DayCapacityLedger ledger,
}) {
  var maximum = 0;
  var sawAny = false;
  for (final snapshot in ledger.snapshots) {
    final limit = problem
        .policyForLocalDate(snapshot.localDate)
        .resolvedRules
        .dailyMovableTaskLimitMinutes;
    if (limit >= LocalTimeRange.minutesPerDay) continue;
    sawAny = true;
    final remaining = limit - snapshot.usedMovableMinutes;
    if (remaining > maximum) maximum = remaining;
  }
  // 整条规则在所有日期上都不生效 ⇒ 返回 0（"这条规则一点没用上"）。
  if (!sawAny) return 0;
  return maximum < 0 ? 0 : maximum;
}

/// 一段区间的**可放置分钟**。
///
/// 判据与 `CandidateGenerator._candidateDurations` **同源**（都读
/// [shortRemainderAllowance] 与 `granularityMinutes`），因为它回答的正是
/// "候选生成在这段里能不能产出东西"。
///
/// - **连续任务**：只有整段长度不小于 `requiredMinutes` 才算可放置，且放置量就是
///   `requiredMinutes`（一次做完，没有"多出来的部分"）。这与候选生成的
///   `[requiredMinutes]` 单元素集一致。
/// - **可拆分任务**：每段按最小片段切分。剩余量短于最小片段时（短余量），
///   唯一合法时长由 [shortRemainderAllowance] 给出——**不重复那份公式**，直接调用它。
int _placeableMinutes({
  required List<TimeRange> ranges,
  required SchedulableTask task,
  required int granularity,
}) {
  if (task.requiredMinutes <= 0) return 0;
  if (task.splitMode == TaskSplitMode.continuous) {
    var total = 0;
    for (final range in ranges) {
      if (range.durationMinutes >= task.requiredMinutes) {
        total += task.requiredMinutes;
      }
    }
    return total;
  }
  final maximum = task.maxChunkMinutes < task.requiredMinutes
      ? task.maxChunkMinutes
      : task.requiredMinutes;
  final isShortRemainder = task.requiredMinutes < task.minChunkMinutes;
  final minimum = isShortRemainder
      ? shortRemainderAllowance(
          requiredMinutes: task.requiredMinutes,
          granularityMinutes: granularity,
        )
      : _roundUp(task.minChunkMinutes, granularity);
  final maximumAligned = _roundDown(maximum, granularity);
  if (minimum <= 0 || maximumAligned <= 0 || minimum > maximumAligned) return 0;

  var total = 0;
  for (final range in ranges) {
    // 一段里能放几个"最小片段"就是这段的可放置量；但**不能超过任务还需要的分钟**
    // （最后一段的余量受 `maximum` 约束，由 `maximumAligned` 已经表达）。
    final chunkCount = range.durationMinutes ~/ minimum;
    if (chunkCount <= 0) continue;
    final usable = chunkCount * minimum;
    total += usable < range.durationMinutes ? usable : range.durationMinutes;
  }
  // 可放置量不可能超过任务本身需要的分钟：`maxChunkMinutes` 限制的是**单个片段**，
  // 不是总量，而总量上限由任务剩余量给出。
  return total < task.requiredMinutes ? total : task.requiredMinutes;
}

List<TimeRange> _mergeRanges(List<TimeRange> ranges) {
  if (ranges.isEmpty) return const [];
  final sorted = [...ranges]..sort((a, b) => a.startUtc.compareTo(b.startUtc));
  final merged = <TimeRange>[];
  var current = sorted.first;
  for (final next in sorted.skip(1)) {
    if (!next.startUtc.isAfter(current.endUtc)) {
      current = TimeRange(
        startUtc: current.startUtc,
        endUtc: next.endUtc.isAfter(current.endUtc)
            ? next.endUtc
            : current.endUtc,
      );
      continue;
    }
    merged.add(current);
    current = next;
  }
  merged.add(current);
  return merged;
}

/// `base` 减去 `cuts`（两者都必须是已合并、互不重叠的升序列表）。
List<TimeRange> _subtract(List<TimeRange> base, List<TimeRange> cuts) {
  if (base.isEmpty) return const [];
  if (cuts.isEmpty) return base;
  final output = <TimeRange>[];
  for (final range in base) {
    var cursor = range.startUtc;
    for (final cut in cuts) {
      if (!cut.endUtc.isAfter(cursor)) continue;
      if (!cut.startUtc.isBefore(range.endUtc)) break;
      if (cut.startUtc.isAfter(cursor)) {
        output.add(TimeRange(startUtc: cursor, endUtc: cut.startUtc));
      }
      if (cut.endUtc.isAfter(cursor)) cursor = cut.endUtc;
    }
    if (cursor.isBefore(range.endUtc)) {
      output.add(TimeRange(startUtc: cursor, endUtc: range.endUtc));
    }
  }
  return output;
}

TimeRange _expand(TimeRange range, Duration buffer) => TimeRange(
  startUtc: range.startUtc.subtract(buffer),
  endUtc: range.endUtc.add(buffer),
);

TimeRange? _intersection(TimeRange a, TimeRange b) {
  final start = a.startUtc.isAfter(b.startUtc) ? a.startUtc : b.startUtc;
  final end = a.endUtc.isBefore(b.endUtc) ? a.endUtc : b.endUtc;
  return end.isAfter(start) ? TimeRange(startUtc: start, endUtc: end) : null;
}

int _sumMinutes(List<TimeRange> ranges) =>
    ranges.fold<int>(0, (sum, range) => sum + range.durationMinutes);

int _largestMinutes(List<TimeRange> ranges) => ranges.isEmpty
    ? 0
    : ranges
          .map((range) => range.durationMinutes)
          .reduce((a, b) => a > b ? a : b);

int _roundUp(int value, int step) => ((value + step - 1) ~/ step) * step;
int _roundDown(int value, int step) => (value ~/ step) * step;
