import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 一个候选被**哪一条硬约束**拒绝（1.8.0，计划 §2.3 Task 5 Step 1）。
///
/// 它是**结构化的**：只说违反了哪条规则，不写任何用户文案。
/// 文案由 `explanations.dart` 与预览层从 `UnscheduledReasonCode` 翻译——
/// 两层各写一套"差不多的判定"必然漂移，而漂移的后果是"引擎按 A 拒绝、界面按 B 解释"。
///
/// 与 UI 无关还有第二个理由：诊断器要把这些拒绝映射成"这段时间为什么没被使用"
/// （[GapExclusionCode]），那是**位置**语义，而这里说的是**候选**语义。
enum CandidateRejectionCode {
  /// 候选时长超过本次的剩余量（排进去就排多了）。
  durationExceedsRemaining,

  /// 候选时长超过它所在**空档**的可用长度。
  ///
  /// 它与 [durationExceedsRemaining] 是两件事：前者是"任务只剩这么多了"，
  /// 后者是"这段时间装不下这个片段"。诊断器为每段空档试各种时长，因此只有它能
  /// 说明"这段空档每一个合法片段都放不下"——那正是 [GapExclusionCode.shorterThanRequiredChunk]。
  exceedsGapCapacity,

  /// 与已有块重叠。
  ///
  /// 具体是谁挡住了它由 [CandidateEligibilityRejection.blockingKind] 说明。
  overlapsExistingBlock,

  /// 均匀分布任务的**本日新增预算**不足（计划 §2.1：不放宽，由均分器改分给其它日子）。
  exceedsEvenDailyBudget,

  /// 超过任务自己声明的单日上限 `maxMinutesPerLocalDay`。
  exceedsDailyTaskLimit,

  /// 超过全局每日可移动上限 `dailyMovableTaskLimitMinutes`。
  exceedsDailyMovableLimit,

  /// 片段之间的休息间隔不足。
  violatesRequiredBreak,

  /// 排完之后剩下的分钟数**凑不出一个合法片段**（`allowUnschedulableLeftover` 的判据）。
  leavesUnschedulableLeftover,
}

/// 挡住候选的那一类占用。用于把"重叠"还原成用户能理解的具体来源
/// （固定日程／保护时间／锁定块）——三类处置不同，混成一句"被占住"等于没说。
enum BlockingKind { fixedSchedule, protectedTime, lockedBlock }

/// 一条结构化的候选拒绝：**哪个候选**、**违反了哪条规则**，不写 UI 文案。
final class CandidateEligibilityRejection {
  const CandidateEligibilityRejection({
    required this.candidate,
    required this.code,
    this.blockingKind,
  });

  final SchedulingCandidate candidate;
  final CandidateRejectionCode code;

  /// 仅 [CandidateRejectionCode.overlapsExistingBlock] 有值。
  final BlockingKind? blockingKind;
}

/// 均匀分布任务"本日还能新增多少分钟"的策略。
///
/// 返回 `null` 表示该任务不受按日预算约束（不是均分任务）。返回非负整数时，
/// 候选时长超过它就是一次 [CandidateRejectionCode.exceedsEvenDailyBudget]。
///
/// **为什么是回调而不是 `EvenDistributionPlan`**：放置循环算预算时用的是"计划预算 −
/// 当前已在该日放下的分钟"，而诊断器要在**最终块集合**上重算同一个量。把这条差异
/// 收进一个回调，判定本体就只有一份。
typedef CandidateBudgetPolicy = int? Function(SchedulingCandidate candidate);

/// 判定一个候选是否满足**全部**硬约束所需要的、与放置状态有关的那一部分。
///
/// 它由建立 [CandidateEligibilityContext] 的调用方提供，因此判定函数本身不需要认识
/// `ScheduleEngine`、也不需要重算任何表。
final class CandidateEligibilityContext {
  const CandidateEligibilityContext({
    required this.problem,
    required this.task,
    required this.remainingMinutes,
    required this.blocks,
    required this.movableMinutesByDate,
    required this.plannedMinutesForTaskByDate,
    required this.policies,
    this.budgetPolicy,
    required this.allowUnschedulableLeftover,
    this.relaxedDailyTaskLimit = false,
  });

  final ScheduleProblem problem;

  /// **逐日规则的缓存**（算法 17）：判定对每个候选都要读当天的休息间隔与每日上限，
  /// 而候选规模是"起点 × 时长"展开的。见 [PolicyLookupCache]。
  final PolicyLookupCache policies;
  final SchedulableTask task;

  /// 本次放置的剩余量。候选时长按它封顶，因此它同时是"排多了"的判据。
  final int remainingMinutes;

  /// 判定重叠、休息与每日上限时看到的**全部**块。
  ///
  /// 放置循环传"到目前为止的块"，诊断器传"最终块集合"——两者问的是同一个问题：
  /// 这个候选放得下去吗？
  final List<PlannedBlock> blocks;

  /// 全局每日可移动上限的判定表（按候选起点所属**本地日期**汇总未锁定块）。
  final Map<DateTime, int> movableMinutesByDate;

  /// **本任务**按本地日期已经占用的分钟（`maxMinutesPerLocalDay` 的判据）。
  final Map<DateTime, int> plannedMinutesForTaskByDate;

  /// 见 [CandidateBudgetPolicy]。
  final CandidateBudgetPolicy? budgetPolicy;

  /// 是否放宽"最终余量凑不出片段"这一条（放置循环第二遍与均分任务为真）。
  ///
  /// **放宽只影响"这一轮要不要继续找别的候选"，不影响"这个候选合不合法"**：
  /// 因此放宽时仍然返回那条拒绝，由调用方决定是否跳过——
  /// 诊断器据此如实报告，而放置循环据此决定 `continue`。
  final bool allowUnschedulableLeftover;

  /// 是否**整段不判定**任务自己的每日上限（`maxMinutesPerLocalDay`）。
  ///
  /// 它存在的理由只有一个：均分任务（`TaskDistributionPolicy.even`）的每日分钟已经由
  /// 均分器按容量定死，放置阶段只消费那份预算（`budgetPolicy`），再看一次任务自己的
  /// 上限就是**同一件事判两遍**。诊断器不传它（默认 `false`），因为诊断问的是最终事实。
  final bool relaxedDailyTaskLimit;
}

/// **唯一的**候选硬约束判定（计划 §2.3 Task 5 Step 1）。
///
/// 返回**所有**命中的拒绝，而不是第一条：一个候选可能同时超过当日配额又与固定日程重叠，
/// 只看第一条会让"为什么排不下"随遍历顺序变化。主原因由
/// `primaryUnscheduledReason` 按固定优先级从全部证据里选，因此同样的输入永远得到同样的说法。
///
/// **评分高低不是拒绝原因**：软约束（精力、期望时段、连续性……）只影响分值，
/// 绝不出现在这里。把它们当硬约束正是"日历上明明有空档却报可用时间不足"的成因之一。
///
/// 判定顺序与引擎放置循环逐条对齐（截止时间与星期由候选生成阶段完成，见
/// `CandidateGenerator.generate`），因此这里不重复它们。
List<CandidateEligibilityRejection> evaluateCandidateEligibility(
  CandidateEligibilityContext context,
  SchedulingCandidate candidate, {
  DateTime? gapEndUtc,
}) {
  final rejections = <CandidateEligibilityRejection>[];
  void reject(CandidateRejectionCode code, {BlockingKind? blockingKind}) {
    rejections.add(
      CandidateEligibilityRejection(
        candidate: candidate,
        code: code,
        blockingKind: blockingKind,
      ),
    );
  }

  // ① 时长超过本次剩余量。
  if (candidate.durationMinutes > context.remainingMinutes) {
    reject(CandidateRejectionCode.durationExceedsRemaining);
  }

  // ①' 时长超过所在空档的可用长度。放置循环里候选本来就按空档裁剪过，因此这一条
  // 只会由诊断器（它显式试各种时长）命中——但判据仍然写在这里，不复制第二套。
  if (gapEndUtc != null && candidate.endUtc.isAfter(gapEndUtc)) {
    reject(CandidateRejectionCode.exceedsGapCapacity);
  }

  // ② 与已有块重叠。三类来源分开报，因为处置不同（挪时间／改保护时间／解锁）。
  final blocker = _blockingKind(candidate.range, context);
  if (blocker != null) {
    reject(CandidateRejectionCode.overlapsExistingBlock, blockingKind: blocker);
  }

  // ③ 均匀分布任务的按日新增预算。
  final budget = context.budgetPolicy?.call(candidate);
  if (budget != null && candidate.durationMinutes > budget) {
    reject(CandidateRejectionCode.exceedsEvenDailyBudget);
  }

  // ④ 任务自己的单日上限。
  final quota = context.task.maxMinutesPerLocalDay;
  if (!context.relaxedDailyTaskLimit &&
      quota != null &&
      (context.plannedMinutesForTaskByDate[candidate.localDate] ?? 0) +
              candidate.durationMinutes >
          quota) {
    reject(CandidateRejectionCode.exceedsDailyTaskLimit);
  }

  // ⑤ 全局每日可移动上限——**按候选所属本地日取当天规则**（算法 17，计划 Task 3 Step 5）。
  //
  // 修复前这里读 `problem.rules.dailyMovableTaskLimitMinutes`，也就是**窗口首日**的那一份。
  // 用户给周末配了更高的上限时，整周仍然套用周一的值——用户看到的是"周末明明空着，
  // 却只排进和周中一样多的量"（计划 §1.2 第 1 条）。
  //
  // `candidate.localDate` 由 `AvailabilitySlot.localDate` 传来，已经是**本地**日期
  // （`AvailabilityBuilder` 按本地日切片），因此这里不需要再做一次时区换算。
  // **走缓存**：这个判定对每个候选都要跑，而候选数是"起点 × 时长"展开的。
  final movableLimit = context.policies.dailyMovableLimitFor(
    candidate.localDate,
    context.problem,
  );
  if (movableLimit < LocalTimeRange.minutesPerDay &&
      (context.movableMinutesByDate[candidate.localDate] ?? 0) +
              candidate.durationMinutes >
          movableLimit) {
    reject(CandidateRejectionCode.exceedsDailyMovableLimit);
  }

  // ⑥ 片段间休息。
  if (_violatesBreak(context, candidate)) {
    reject(CandidateRejectionCode.violatesRequiredBreak);
  }

  // ⑦ 排完之后剩下的分钟凑不出一个合法片段。
  final leftover = context.remainingMinutes - candidate.durationMinutes;
  if (context.task.splitMode == TaskSplitMode.splittable &&
      leftover > 0 &&
      _leftoverAllowance(context, candidate, leftover) <= 0) {
    reject(CandidateRejectionCode.leavesUnschedulableLeftover);
  }

  return rejections;
}

/// 一个候选**会不会被采纳**（放置循环的 `continue` 判据）。
///
/// 它只把 [CandidateRejectionCode.leavesUnschedulableLeftover] 在
/// [CandidateEligibilityContext.allowUnschedulableLeftover] 为真时放行——见该字段的说明。
bool isCandidateAcceptable(
  CandidateEligibilityContext context,
  List<CandidateEligibilityRejection> rejections,
) {
  for (final rejection in rejections) {
    if (rejection.code == CandidateRejectionCode.leavesUnschedulableLeftover &&
        context.allowUnschedulableLeftover) {
      continue;
    }
    return false;
  }
  return true;
}

/// **按本地日期缓存的逐日规则**（算法 17）。
///
/// ## 为什么必须有缓存
///
/// `evaluateCandidateEligibility` 对**每一个候选**都要读当天的休息间隔与每日上限，
/// 而候选规模是"起点 × 时长"展开的（规模夹具里单次生成就有几十万次判定）。
/// 每次都走 `problem.policyForLocalDate(date)` 会重复做三件事：归一化日期、
/// 构造 `DateTime`、查表——单项都很便宜，乘上候选数就是量级差异
/// （实测：`scale_smoke_test` 的时间预算因此从 ~60 秒涨到 85 秒）。
///
/// ## 为什么不把缓存放进 `ScheduleProblem`
///
/// 值对象保持"纯数据 + 显式校验"；缓存是**调用方**的优化，放在每次生成构造一次的
/// 上下文里，生命周期与"这一次生成"完全一致，不会跨输入泄漏。
///
/// [PolicyLookupCache.forProblem] 只读取 [ScheduleProblem.dailyPolicies]，
/// **缺日仍然抛 [StateError]**（由 `policyForLocalDate` 负责），因此缓存不会
/// 把"缺日"变成"回退首日"。
final class PolicyLookupCache {
  PolicyLookupCache._({
    required Map<DateTime, int> breakMinutesByDate,
    required Map<DateTime, int> movableLimitByDate,
    required Map<DateTime, int> granularityByDate,
  }) : _breakMinutes = breakMinutesByDate,
       _movableLimit = movableLimitByDate,
       _granularity = granularityByDate;

  /// 为一次生成预计算三条日期敏感规则，**每个日期只算一次**。
  ///
  /// 构造时对每个日期调用 `policyForLocalDate`：缺日与键不一致这两件事只在
  /// 那一路里被校验，绕过它就等于绕过装配不变量。之后查询只剩一次哈希。
  factory PolicyLookupCache.forProblem(ScheduleProblem problem) {
    final breakMinutes = <DateTime, int>{};
    final movableLimit = <DateTime, int>{};
    final granularity = <DateTime, int>{};
    for (final entry in problem.dailyPolicies.entries) {
      final rules = problem.policyForLocalDate(entry.key).resolvedRules;
      breakMinutes[entry.key] = rules.breakMinutes;
      movableLimit[entry.key] = rules.dailyMovableTaskLimitMinutes;
      granularity[entry.key] = rules.granularityMinutes;
    }
    return PolicyLookupCache._(
      breakMinutesByDate: breakMinutes,
      movableLimitByDate: movableLimit,
      granularityByDate: granularity,
    );
  }

  final Map<DateTime, int> _breakMinutes;
  final Map<DateTime, int> _movableLimit;
  final Map<DateTime, int> _granularity;

  /// [localDate] 当天的粒度。
  ///
  /// **入参必须是已经归一的本地日期**（`AvailabilitySlot.localDate` 就是）。
  /// 这里**刻意不做归一化**：规模夹具里单次生成有 249 万个候选判定，而
  /// `normalizeLocalDate` 会为每一次查询新分配一个 `DateTime`——实测那一步把
  /// 放置阶段从 **9.4 秒**推到 **79.6 秒**。
  int granularityFor(DateTime localDate, ScheduleProblem problem) =>
      _granularity[localDate] ?? problem.rules.granularityMinutes;

  /// [localDate] 当天的休息间隔。
  int breakMinutesFor(DateTime localDate, ScheduleProblem problem) =>
      _breakMinutes[localDate] ?? problem.rules.breakMinutes;

  /// [localDate] 当天的可移动任务上限。
  int dailyMovableLimitFor(DateTime localDate, ScheduleProblem problem) =>
      _movableLimit[localDate] ?? problem.rules.dailyMovableTaskLimitMinutes;
}

/// 一段区间**最少**要有多长才能产出一个候选（`0` 表示这段区间里什么也排不进）。
///
/// - 连续任务：必须一次做完 `remainingMinutes`；
/// - 剩余量本身就短于最小片段：唯一合法时长由 [shortRemainderAllowance] 给出；
/// - 否则：`minChunkMinutes` 向上取整到粒度。
int minimumPlacementMinutes({
  required SchedulableTask task,
  required int remainingMinutes,
  required int granularityMinutes,
}) {
  if (task.splitMode == TaskSplitMode.continuous) return remainingMinutes;
  if (remainingMinutes < task.minChunkMinutes) {
    return shortRemainderAllowance(
      requiredMinutes: remainingMinutes,
      granularityMinutes: granularityMinutes,
    );
  }
  return _roundUp(task.minChunkMinutes, granularityMinutes);
}

BlockingKind? _blockingKind(
  TimeRange range,
  CandidateEligibilityContext context,
) {
  BlockingKind? kind;
  for (final block in context.blocks) {
    if (!block.range.overlaps(range)) continue;
    // 固定日程**优先**：同样的重叠若既来自固定日程又来自锁定块（课表占住的一段同时
    // 是用户的锁定块），先报固定日程——它是用户无法解锁的那一类。
    final current = _classifyBlock(block, context.problem);
    if (kind == null || current == BlockingKind.fixedSchedule) kind = current;
  }
  return kind;
}

/// 一个块属于哪一类占用：固定日程 > 保护时间 > 锁定块。
///
/// 保护时间**按区间判定**而不是按块 id：保护时间不是计划块，它只以
/// `problem.protectedIntervals` 的形式存在，而引擎自己排出的块可能与它重叠
/// （`_improve` 之后尤其如此）。按区间判定问的才是"这段时间为什么不能用"。
BlockingKind _classifyBlock(PlannedBlock block, ScheduleProblem problem) {
  if (problem.lockedBlocks.any((item) => item.id == block.id)) {
    return BlockingKind.lockedBlock;
  }
  for (final interval in problem.fixedIntervals) {
    if (interval.range.overlaps(block.range)) return BlockingKind.fixedSchedule;
  }
  for (final interval in problem.protectedIntervals) {
    if (interval.range.overlaps(block.range)) {
      return BlockingKind.protectedTime;
    }
  }
  return BlockingKind.lockedBlock;
}

bool _violatesBreak(
  CandidateEligibilityContext context,
  SchedulingCandidate candidate,
) {
  // **按候选所属本地日取休息规则**（算法 17，计划 Task 3 Step 5）。
  // 修复前读窗口首日的 `problem.rules.breakMinutes`：用户给周末配了更长的休息时，
  // 整周仍然按周一的间隔判定。走缓存，理由同每日上限。
  final breakMinutes = context.policies.breakMinutesFor(
    candidate.localDate,
    context.problem,
  );
  if (breakMinutes <= 0) return false;
  for (final block in context.blocks) {
    if (_gapMinutes(block.range, candidate.range) < breakMinutes) return true;
  }
  return false;
}

int _leftoverAllowance(
  CandidateEligibilityContext context,
  SchedulingCandidate candidate,
  int leftover,
) => shortRemainderAllowance(
  requiredMinutes: leftover,
  // 同一条纪律：粒度也按候选所属本地日取。
  granularityMinutes: context.policies.granularityFor(
    candidate.localDate,
    context.problem,
  ),
);

/// 两个区间的间隔分钟数；重叠或首尾相接时为 0。
int _gapMinutes(TimeRange a, TimeRange b) {
  if (a.overlaps(b)) return 0;
  if (!a.endUtc.isAfter(b.startUtc)) {
    return b.startUtc.difference(a.endUtc).inMinutes;
  }
  return a.startUtc.difference(b.endUtc).inMinutes;
}

/// 按**本地日期**汇总未锁定（含生成期间被临时钉住）块的分钟数。
///
/// 口径与 `PlanValidator` 逐字段对齐：
/// - 只算**未锁定**块；
/// - 但生成过程中为了固定位置而临时标成 `locked`、且 id 位于
///   `pinnedUnlockedBlockIds` 的块**仍然计入**——否则会出现"引擎认为没超，
///   恢复 `locked: false` 后 `PlanValidator` 报 `dailyLimitExceeded`"。
///
/// 放置循环、局部改进与诊断器**共用这一个函数**：三处各算一遍就意味着三套口径，
/// 而它们必须给出同一个答案。
Map<DateTime, int> movableMinutesByLocalDate({
  required ScheduleProblem problem,
  required TimeZoneDatabase zones,
  required List<PlannedBlock> blocks,
}) {
  final result = <DateTime, int>{};
  for (final block in blocks) {
    final movable =
        !block.locked || problem.pinnedUnlockedBlockIds.contains(block.id);
    if (!movable) continue;
    final date = localDateOf(block.startUtc, problem.timeZoneId, zones);
    result[date] = (result[date] ?? 0) + block.durationMinutes;
  }
  return result;
}

/// 该任务按本地日期已经占用的分钟（只统计**该任务**的块）。
Map<DateTime, int> taskMinutesByLocalDate({
  required ScheduleProblem problem,
  required SchedulableTask task,
  required TimeZoneDatabase zones,
  required List<PlannedBlock> blocks,
}) {
  final result = <DateTime, int>{};
  for (final block in blocks) {
    if (block.taskId != task.id) continue;
    final date = localDateOf(block.startUtc, problem.timeZoneId, zones);
    result[date] = (result[date] ?? 0) + block.durationMinutes;
  }
  return result;
}

/// 一个 UTC 时刻属于哪个**本地日**（时间部分为 0）。
///
/// 本地日必须由 [TimeZoneDatabase] 换算，不能把 UTC 时刻直接截成日期：
/// 东八区 2026-10-08T16:30Z 属于本地 10-09，截 UTC 会把它记到"前一天"。
DateTime localDateOf(
  DateTime instantUtc,
  String timeZoneId,
  TimeZoneDatabase zones,
) {
  final local = zones.toLocal(instantUtc, timeZoneId);
  return DateTime(local.year, local.month, local.day);
}

int _roundUp(int value, int step) => ((value + step - 1) ~/ step) * step;
