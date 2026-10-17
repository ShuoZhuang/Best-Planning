import 'dart:math' as math;

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_eligibility.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/candidate_scorer.dart';
import 'package:personal_planner/scheduling/day_allocation.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/plan_quality_validator.dart';
import 'package:personal_planner/scheduling/schedule_objective.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/preferred_time_scorer.dart';
import 'package:personal_planner/scheduling/pressure_calculator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/task_placement_diagnostics.dart';

abstract interface class ScheduleEngine {
  ScheduleProposal generate(ScheduleProblem problem);
}

final class DeterministicScheduleEngine implements ScheduleEngine {
  DeterministicScheduleEngine(this._zones, {this.maxAllocationStates = 10000})
    : _availabilityBuilder = AvailabilityBuilder(_zones),
      _validator = PlanValidator(_zones);

  final int maxAllocationStates;

  /// 算法版本。任何会改变排程结果的改动都必须提升该值，否则历史计划无法按
  /// 当时的算法复现（设计 §5.1）。版本 2 引入同一任务的片段间休息，并把续排
  /// 容量按休息预算计算（只统计候选之后仍可承接后续片段的时间）。
  /// 版本 3 把休息推广到任意两个非生活任务块之间。
  /// 版本 4 取消任务类型区分：所有任务块之间一律保留休息。
  /// 版本 5 让候选排序以软约束总分为首键（与设计 §5.2 第 7 步一致），
  /// 覆盖度退为同分时的次级依据。
  /// 版本 6 把"大于零但小于最小可排片段"的远期目标抬到可排的最小量，
  /// 使 §5.3 的均匀推进量不再落空。
  /// 版本 7 注入同任务连续性与类别切换成本两个因子（此前从未被引擎设置）。
  /// 版本 8 注入移动成本：`ScheduleProblem.existingBlocks`（已确认但未锁定的块）
  /// 被占用时计一次移动代价。
  /// 版本 9 注入任务期望时段因子（此前 `CandidateScoringContext` 的该字段从未被
  /// 引擎设置，恒为 0）。
  /// 版本 10（1.7.1）三处会改变输出：① `AvailabilityBuilder` 不再按每日上限截断候选，
  /// 因此候选集覆盖全天真实空闲；② 每日可移动上限改为在选块时统一判定
  /// （`_exceedsMovableDailyLimit`），不再靠"少看见一些空档"实现；③ `even` 策略的周期目标
  /// 改由容量感知的按日均分器给出每日预算，且**不再有两轮全局放开配额**。
  /// 三处都会改变同一输入得到的分块位置，因此必须抬版本，否则无法区分"算法变了"与"输入变了"。
  ///
  /// 版本 11（1.8.0）新增**最小化改动**那一步（规范 §11.4 第 3、4 条）：生成结束前把
  /// **还能回到原位**的块放回原位。于是"被移动的块数"与"总位移分钟"这两个量第一次真的被
  /// 优化，而不是只靠单块评分里那个移动惩罚项间接影响。同一输入的分块位置因此会变
  /// （更少、更近），必须抬版本。
  /// 版本 12 统一稳定身份／块级延后／局部级联／方案级坏空档比较。
  /// 版本 13 让睡眠进入统一硬占用集合，并做"当天优先"的级联。
  ///
  /// 版本 14（2026-10-12 故障修复）三处都会改变同一输入得到的块集合：
  /// ① **历史块不再计入前向计划** —— 已结束的确认块既不再进 `lockedBlocks`，
  ///    也不再计入 `scheduledByTask`，因此"本次还剩多少"与旧版本不同；
  /// ② **粒度与短余量契约统一** —— 候选生成改用 `problem.rules.granularityMinutes`
  ///    构造（此前固定 5 分钟），且最终校验接受与生成一致的短余量；
  /// ③ 进行中块被识别为硬占用（此前落入可移动集合，会被局部改进搬走）。
  ///
  /// 版本 15（2026-10-13「可见空闲却报容量不足」专项）三处都会改变同一输入的块集合：
  /// ① **规划窗口之外的任务不再进入本次目标** —— 装配层按
  ///    `classifyTaskForPlanningWindow` 分类，`availableFromUtc` 不早于窗口终点的普通任务
  ///    被静默排除（它此前会带着目标分钟进入问题却产不出候选，被报成"可用时间不足"）；
  /// ② **未来周期实例不再作为普通任务泄漏** —— 装配层按 `findCyclesByTaskIds` 把
  ///    **全部**已生成实例从普通输入里剥离，只由周期输入加回本周那一份。修复前只删
  ///    "本周实例"，`ensureCycles` 为滚动七天补出来的下周实例因此留在普通输入里，
  ///    成为一条同名、不同 id、本次窗口根本不覆盖的幽灵任务；
  /// ③ **按日预算不再被截止之后的日子吃掉** —— `_capacityByLocalDate` 只统计
  ///    任务截止之前的本地日。修复前均分器按七日窗口摊量，而候选生成按 `dueAtUtc` 过滤，
  ///    于是截止之后的三天白拿一份预算，真正能排的四天每天只分到"目标 ÷ 7 天"，
  ///    一个最小片段都凑不出来 ⇒ 任务排入 0 分钟或只排进去一部分。
  ///    实测：210 分钟、截止周日、七日窗口 ⇒ 修复前排入 120 并报"达到每日上限"，
  ///    修复后排满 210。
  ///
  /// 版本 16（2026-10-13「日历、计划预览与排程完整性修复」§2.1／§2.2）三处都会改变
  /// 同一输入得到的块集合：
  /// ① **候选按"当前剩余量"逐轮重新生成** —— `CandidateGenerator.generate` 新增必填的
  ///    `remainingMinutes`，引擎每成功放置一块就以新的剩余量重算候选。修复前候选集在
  ///    进入放置循环**之前**只生成一次（且用 `task.requiredMinutes` 判定短余量），
  ///    于是 100 分钟的任务只能排出 `30+30+30`，最后那 10 分钟永远看不见（R3）；
  /// ② **最终校验按同任务的整组块判定"唯一短尾"** —— `validatePlannedChunkSet` 取代
  ///    逐块检查成为集合合法性的唯一依据，因此 `30+30+30+10` 这类合法短尾第一次真的
  ///    被接受（R4）；
  /// ③ **每日上限在放置阶段不再被第二遍整段放开** —— 第二遍只放宽"最终余量凑不出片段"
  ///    这一条软性偏好，`maxMinutesPerLocalDay` 恢复为计划 §Global Constraints 要求的硬约束
  ///    （实测：每天 30 分钟额度、任务要 210 分钟 ⇒ 修复前排出七个 30 分钟块）。
  /// ## 算法 17（容量感知分层排程，2026-10-16 计划）
  ///
  /// 相对 16 的变化全部集中在"**先分配跨日预算，再在日内放置**"这条主线上：
  ///
  /// ① **逐日规则**：`DailySchedulingPolicy` 按本地日解析，日期敏感字段
  ///    （每日上限、粒度、休息间隔、生活配额）不再复制窗口首日；
  /// ② **单一容量账本**：`DayCapacityLedger` 是"某天还能放多少"的唯一来源，
  ///    放置、诊断、改进三处读同一份口径（`usedMovableMinutes` **包含锁定块**）；
  /// ③ **全局跨日分配**：`allocateTaskDays` 先按方案级字典序目标把每个任务的
  ///    分钟摊到 K 个日期上（K 满足 `K × chunk ≤ 目标`），引擎只在这些预算内放置；
  /// ④ **预算在改进阶段同样生效**：`_improve` 不再能把块搬去超预算的日子；
  /// ⑤ **截止优先于形状**：分配顺序先看截止，再看"连续/可切"，
  ///    避免无截止的连续任务抢走有截止任务唯一的窗口。
  ///
  /// 黄金用例（`golden_week.json`）的块与缺口在 16 → 17 之间**完全不变**，
  /// 这正是这次升级想要的结论：新架构复现了旧行为，同时把口径收敛到一处。
  ///
  /// ## 算法 18：既有块的身份（Task 8 的 ID 族修复）
  ///
  /// 相对 17 只改一件事，但它**改变输出**：未锁定的既有计划块携带**原 id**
  /// 作为起点进入排程。
  ///
  /// 修复前引擎为所有块重新起名（`block:<taskId>:<micros>:<dur>`），而
  /// `referenceBlocks` 的键是确认计划的 persistedId——两边不同族，于是
  /// `minimizeChangedBlocks` 的 `referenceBlocks.containsKey(block.id)` 永远为 false，
  /// 那一步在真实装配下是**空操作**，"尽量少改动"只在函数级测试里成立。
  ///
  /// 因此必须抬版本：同一份输入现在会产出**不同的块 id 集合**（既有块保留原 id，
  /// 不再重新生成）。历史计划要按当时的算法复现，就必须能区分这两个版本。
  static const String algorithmVersion = '18';
  static const int localImprovementOperationBudget = 200;

  final TimeZoneDatabase _zones;
  final AvailabilityBuilder _availabilityBuilder;
  final PlanValidator _validator;
  final CandidateScorer _candidateScorer = const CandidateScorer();
  final PressureCalculator _pressureCalculator = const PressureCalculator();

  @override
  ScheduleProposal generate(ScheduleProblem problem) {
    // **候选生成器的粒度来自规则**（1.8.0，冻结决策 §1.4）：`problem.rules` 是
    // 粒度、短余量与网格的**唯一事实源**。修复前这里是字段初始化里的
    // `const CandidateGenerator()`（默认 5 分钟），于是用户把粒度配成 10 分钟时，
    // 引擎仍在 5 分钟网格上放置片段，而 `AvailabilityBuilder` 与窗口起点按 10 分钟走 ——
    // 同一条规则在三个地方各算一遍。
    final chunkGenerator = CandidateGenerator(
      granularityMinutes: problem.rules.granularityMinutes,
    );
    // **详细分析只算一次**（1.8.0 专项 §2.3）：`slots` 是它的转发结果，
    // 容量证据与候选生成因此读的是**同一批空闲**。修复前"候选用的空闲"与
    // "归因用的空闲"各算一遍，于是两者可以互相矛盾，而用户无从判断哪一个是真的。
    final availability = _availabilityBuilder.analyze(
      _availabilityInput(problem, problem.planningWindow),
    );
    // ── 逐日容量账本：**唯一**的容量事实源（算法 17，计划 Task 3）──────────────
    //
    // 它在放置**之前**从"唯一一份 `AvailabilityAnalysis` + 基线块"构造一次，
    // 之后引擎、诊断器与容量分析器都只读它。修复前这三者各算一套"这天还剩多少"，
    // 于是"界面说还有 90 分钟、引擎说只剩 20 分钟"这种自相矛盾完全可能。
    //
    // **基线是锁定块**：它们是"这一天已经用掉多少"的事实。本次生成新排进去的块
    // 由放置循环自己维护的增量表负责（`movableMinutesByDate`），不混进账本——
    // 账本一旦可变，同一份输入就会得到两个答案。
    // **逐日规则只查一次表**（算法 17）：放置循环对每个候选都要读当天的休息间隔、
    // 每日上限与粒度，而候选数是"起点 × 时长"展开的。见 `PolicyLookupCache`。
    final policies = PolicyLookupCache.forProblem(problem);
    final ledger = buildDayCapacityLedger(
      problem: problem,
      availability: availability,
      baselineBlocks: problem.lockedBlocks,
      zones: _zones,
    );
    final slots = availability.slots;
    final targets = {
      for (final task in problem.tasks) task.id: _targetFor(problem, task),
    };
    final tasks = [...problem.tasks]
      ..sort((a, b) => _compareTasks(a, b, slots, targets));
    // ── 起点：锁定块 + **未锁定的既有块**（Task 8 的 ID 族修复）──────────────────
    //
    // 既有块必须以**原 id** 作为起点进入排程。否则引擎会为它重新起名
    // （`block:<taskId>:<micros>:<dur>`），而真实装配里 `referenceBlocks` 的键是
    // persistedId（`<提案 id>:<引擎 id>`）——两边不同族，于是
    // `minimizeChangedBlocks` 的 `referenceBlocks.containsKey(block.id)` 永远为 false，
    // 那一步在真实装配下是**空操作**，"尽量少改动"只在函数级测试里成立。
    //
    // 采纳判据只有四条，**全部与身份无关**（id 只用于匹配，不参与评分或可行性）：
    // · 任务仍在本次输入里（被跳过/已完成的任务不该继续占位）；
    // · 不与锁定块重复；
    // · 仍完整落在某个可用时段内——可用时段已扣掉固定日程、保护时间、睡眠与
    //   课程过渡，因此这一条同时覆盖那三类硬占用；
    // · 累计不超过该任务的目标分钟。
    //
    // 不合法的一律不采纳：它由放置循环重新安排并拿到新 id。那条路径才是"移走"，
    // 而采纳路径是"原地保留"，两者在提案里由 `continuedFromId` 区分。
    final adopted = _adoptableExistingBlocks(
      problem: problem,
      slots: slots,
      targets: targets,
    );
    final blocks = [...problem.lockedBlocks, ...adopted]..sort(_compareBlocks);
    final explanations = <PlanExplanation>[];
    final scheduledByTask = <String, int>{};
    for (final block in blocks) {
      scheduledByTask.update(
        block.taskId,
        (value) => value + block.durationMinutes,
        ifAbsent: () => block.durationMinutes,
      );
    }

    // ── 均匀分布任务：**先撤掉上一轮那份可移动的安排**（计划 §3.3）──────────────
    //
    // 计划 §3.3 明确要求："若旧确认计划已经不均匀，稳定性惩罚不能阻止本次重排恢复均匀；
    // 稳定性只在同等均匀度的候选之间生效。"
    //
    // `problem.lockedBlocks` 里同时装着**真锁定**的块和"上一轮确认计划里未锁定"的块，
    // 而引擎把两者一视同仁地当成既有事实（`scheduledByTask` 与 `blocks` 都用它）。
    // 对均匀分布任务，那份未锁定的既有安排会把上轮的偏斜**冻结**下来：实测中周五已有的
    // 90 分钟让 210 分钟排成 `0/90/80/40`，而不是 `50/50/55/55`——正是用户报告的聚拢。
    //
    // 因此这里先把均匀分布任务的**未锁定**旧块撤出 `blocks`，并把它们的分钟从
    // `scheduledByTask` 里扣回，于是 `target` 重新等于"本次要摊开的全部分钟"，由均分器按容量
    // 重新分配。**真锁定的块一律保留**（用户明确锁住的东西不可移动）。
    //
    // 扣回而不是直接忽略，是因为 `scheduledByTask` 决定了"还剩多少要排"；不扣会让目标偏小，
    // 结果少排。
    final evenTaskIds = {
      for (final task in problem.tasks)
        if (task.distributionPolicy == TaskDistributionPolicy.even) task.id,
    };
    if (evenTaskIds.isNotEmpty) {
      final removed = <PlannedBlock>[];
      blocks.removeWhere((block) {
        final movable =
            evenTaskIds.contains(block.taskId) &&
            (!block.locked ||
                problem.pinnedUnlockedBlockIds.contains(block.id));
        if (movable && !block.locked) removed.add(block);
        return movable && !block.locked;
      });
      for (final block in removed) {
        scheduledByTask.update(
          block.taskId,
          (value) => value - block.durationMinutes < 0
              ? 0
              : value - block.durationMinutes,
        );
      }
    }

    // ── 拒绝证据：**只在当前轮次里存在**（计划 §2.3 Task 5 Step 2）─────────────
    //
    // 修复前这里有一份**跨轮次累计**的 `rejectionEvidence`（每个任务一张按 code 去重的表），
    // 最终的 `unscheduled` 直接读它。那条路径有个结构性缺陷：循环里每一次拒绝都是
    // "**试**一个候选"的副产物——判据不成立时先记一条，该候选随后仍可能被选中
    // （`allowUnschedulableLeftover` 的第二遍就是这么做的）。于是一条在成功放置**之前**、
    // 按**当时**剩余量算出来的拒绝会一路活到最终结论里，甚至因为
    // `unscheduledReasonPriority` 里的位次更高而盖过真正的最终约束（R5）。
    //
    // 现在最终原因**只**由 `diagnoseTaskPlacement` 在最终块集合上重新诊断得出，
    // 放置循环里的拒绝是纯粹的局部变量，成功选择候选后自然销毁。

    // 每日可移动上限的判定表。**增量维护**：`blocks` 每变一次就在这里加一笔，
    // 于是判定从"每个候选扫一遍所有块"退化为一次 Map 查表。
    // 见 `_exceedsMovableDailyLimit` 的说明（取消候选截断后这一项曾是主要开销）。
    final movableMinutesByDate = _movableMinutesByDate(problem, blocks);
    final taskMinutesByDate = <String, Map<DateTime, int>>{};
    void chargeTaskMinutes(PlannedBlock block) {
      final byDate = taskMinutesByDate.putIfAbsent(
        block.taskId,
        () => <DateTime, int>{},
      );
      final date = _localDate(block.startUtc, problem.timeZoneId);
      byDate[date] = (byDate[date] ?? 0) + block.durationMinutes;
    }

    for (final block in blocks) {
      chargeTaskMinutes(block);
    }

    void chargeMovable(PlannedBlock block) {
      final date = _localDate(block.startUtc, problem.timeZoneId);
      movableMinutesByDate[date] =
          (movableMinutesByDate[date] ?? 0) + block.durationMinutes;
    }

    // ── 均匀分布：先算"每天多少分钟"，日内选点才交给评分（计划 §3.1 / §3.2）──────
    //
    // **这一步必须在放置之前**：候选评分里的同任务连续性、精力匹配与旧计划稳定性都只看
    // "这一天内部哪个位置更好"，一旦让它们参与"选哪一天"，就会出现用户实测的
    // `35 / 125 / 50 / 0`（计划 §2.3）。
    final allocationPlan = allocateTaskDays(
      DayAllocationInput(
        tasks: problem.tasks,
        ledger: ledger,
        alreadyPlannedByTask: {
          for (final task in problem.tasks)
            task.id: _plannedMinutesByLocalDate(
              problem,
              task,
              problem.lockedBlocks,
            ),
        },
        timeZoneId: problem.timeZoneId,
        cycleStartByTask: _cycleStartsByTask(problem),
        granularityMinutes: problem.rules.granularityMinutes,
        targetMinutesByTask: {
          for (final task in problem.tasks)
            task.id: math.max(
              0,
              targets[task.id]! - (scheduledByTask[task.id] ?? 0),
            ),
        },
        alreadyScheduledMinutesByTask: {
          for (final task in problem.tasks)
            task.id: scheduledByTask[task.id] ?? 0,
        },
        maxAllocationStates: maxAllocationStates,
      ),
    );

    for (final task in tasks) {
      var remaining = math.max(
        0,
        targets[task.id]! - (scheduledByTask[task.id] ?? 0),
      );
      final taskBudget = allocationPlan.budgetFor(task.id);
      final budgetMinutesByDate = taskBudget?.minutesByLocalDate ?? const {};

      while (remaining > 0) {
        // ── 每一轮都用**当前**剩余量重新生成候选（计划 §2.1 / Task 4 Step 4）──────
        //
        // 顺序与既有实现一致：截止过滤 → 均匀分布按日预算过滤 → 重叠 → 每日上限 →
        // 每日可移动上限 → 休息间隔 → 最终余量判据 → 评分。
        //
        // **候选集不再跨轮复用**。`slots` 与 `evenPlans` 是循环外的静态输入
        // （Task 4 Step 5：不重建 `AvailabilityAnalysis`、不重算本周目标），
        // 因此"重新生成"只是同一批空档上的一次时长枚举，代价可控。
        final roundGenerated = chunkGenerator.generate(
          task,
          slots,
          remainingMinutes: remaining,
        );
        // ── 截止过滤 + 按日预算剪枝 ──────────────────────────────────────────────
        //
        // **按日预算剪枝是"等价剪枝"**（计划 Issue 4a）：均分器已经把每日分钟定死，
        // 而放置循环只消费仍有余量的日期（`_evenBudgetRemaining`）。某日本次预算为 0，
        // 它的候选无论保留与否都**永远不会被选中**；剪掉它们只省掉"必被跳过"的评分开销。
        //
        // 取消每日上限对候选时间轴的截断后（Task 2），候选数明显变多：
        // 实测规模用例 1632 ms → 3255 ms（恰好两倍，计划 Step 4a 的阈值就是两倍）。
        //
        // 保留条件用 `additionalMinutesByLocalDate` 是否**存在**该日，而不是它当前的剩余量：
        // 剩余量会随放置递减，用剩余量做过滤会让同一份候选集在循环中变化，破坏确定性。
        final roundCandidates = roundGenerated
            .where(
              (candidate) =>
                  task.dueAtUtc == null ||
                  !candidate.endUtc.isAfter(task.dueAtUtc!),
            )
            .where(
              (candidate) =>
                  budgetMinutesByDate.isEmpty ||
                  budgetMinutesByDate.containsKey(candidate.localDate),
            )
            .toList();
        if (roundCandidates.isEmpty) {
          // **不能让 `while` 空转**：这一轮一个可选候选都没有，
          // 再转下去只会得到同一份空集合（剩余量没变）。
          // 原因的归因不在循环里做——它由最终诊断（`diagnoseTaskPlacement`）按
          // 最终块集合给出（计划 §2.3）。
          break;
        }
        // ── 均匀分布任务：按日预算放置（1.7.1 计划 Task 4 Step 3）──────────────
        //
        // `distributionPolicy == even` 的任务**不使用**下面那套"两轮放开配额"。原因：
        // 两轮策略的第二轮是**全局解禁**，它能把一天堆到 125 分钟——那正是用户实测的缺陷
        // （计划 §2.1）。均匀分布的正确处置是"某日放不下就把它放不下的部分重新分给还有余量的
        // 日期"，这件事已经由均分器按容量做完（计划 §3.1 第 4 条），因此这里只消费预算。
        //
        // **每日上限（`maxMinutesPerLocalDay`）不在这套"两轮"里**：它是计划
        // §Global Constraints 明确列出的硬约束（"不得为了消除告警而绕过"）。
        // 第二遍要放宽的是**另一件事**——"最终余量凑不出片段"（见 `allowUnschedulableLeftover`）。
        // 修复前 `relaxedDailyQuota = evenPlan != null || pass == 1` 让 `_exceedsDailyQuota`
        // 在第二遍**整段返回 false**，于是任务自己声明的每日上限在放置阶段形同不存在
        // （实测：每天 30 分钟额度、任务要 210 分钟 ⇒ 排出七个 30 分钟块）。
        var ranked = <_RankedCandidate>[];
        // **只有 `even` 任务放宽每日可移动上限**。
        //
        // 原因：`even` 任务的每日分钟已由分配器按**许可容量**算定（预算本身就是
        // 额度约束），再叠一层"每日可移动上限"是对同一件事的重复限制，会把
        // 预先算好的预算卡掉。实测（`recurring_planning_test`
        // 「均匀分布不会把 180 分钟全堆到周日」）：若对所有任务都收紧，
        // 该 even 任务**一个块都排不进去**（`blocks.length == 0`）。
        //
        // 而**普通任务必须严格检查上限**——那正是 `movable_daily_limit_test`
        // 「锁定块占用可移动额度」钉住的规则（锁定 300 + 上限 360 ⇒ 最多再排 60）。
        //
        // 因此判据回到"是不是 even"，而不是"有没有预算"。
        final relaxedDailyQuota =
            task.distributionPolicy == TaskDistributionPolicy.even;
        final budgetPlan = taskBudget;
        // **"最终余量凑不出片段"只排除那些候选，不排除整件事**（1.8.0，冻结决策 §1.4）。
        //
        // 修复前这里是**无条件 `continue`**：一个 12 分钟的任务选 10 分钟会留下 2 分钟，
        // 而 2 分钟不足一个粒度（5）⇒ 候选被拒 ⇒ 一个候选都不选 ⇒
        // 实测 `scheduled=0 shortage=12 reasons=[minimumChunkTooLarge]`。
        // 但用户真正要的是"能排的 10 分钟排进去，剩下 2 分钟如实报缺口"。
        //
        // 处置因此分两层：
        //   · 第一遍：优先选"排完之后剩下的还能构成片段"的候选（例如 100 分钟的 30/35…）；
        //   · 若第一遍一个都没有（例如 12 分钟只剩下 2），**放宽这一条**，
        //     把能排的那一段排进去 —— 剩下的真实缺口由 `unscheduled` 如实汇报。
        var allowUnschedulableLeftover = false;
        for (
          var pass = 0;
          pass < (budgetPlan == null ? 2 : 1) && ranked.isEmpty;
          pass++
        ) {
          allowUnschedulableLeftover = budgetPlan != null || pass == 1;
          // **判定只有一份实现**：放置循环与最终诊断都调
          // `evaluateCandidateEligibility`（`candidate_eligibility.dart`）。
          // 两处各写一套"看起来差不多"的硬约束判断，就必然漂移——而漂移的后果是
          // "引擎排得下、诊断说排不下"（或反过来），用户看到的原因与事实不符。
          final context = CandidateEligibilityContext(
            problem: problem,
            task: task,
            remainingMinutes: remaining,
            blocks: blocks,
            policies: policies,
            movableMinutesByDate: movableMinutesByDate,
            plannedMinutesForTaskByDate:
                taskMinutesByDate[task.id] ?? const <DateTime, int>{},
            budgetPolicy: budgetPlan == null
                ? null
                : (candidate) => _budgetRemaining(
                    candidate,
                    budgetPlan,
                    taskMinutesByDate[task.id] ?? const <DateTime, int>{},
                  ),
            allowUnschedulableLeftover: allowUnschedulableLeftover,
            relaxedDailyTaskLimit: relaxedDailyQuota,
          );
          for (final candidate in roundCandidates) {
            // **每一条拒绝都留证据**，而不是只记最后一条。同一个候选可能同时违反多条约束
            // （例如既超过今日配额、又和固定日程重叠），只记一条会让原因随遍历顺序变化。
            // 这里的拒绝是**当前轮的局部数据**：它只用来决定"这个候选要不要跳过"，
            // 最终原因由 `diagnoseTaskPlacement` 在最终块集合上重新诊断（计划 §2.3）。
            final rejections = evaluateCandidateEligibility(context, candidate);
            if (!isCandidateAcceptable(context, rejections)) continue;
            final score = _scoreCandidate(
              problem,
              task,
              candidate,
              blocks,
              targets[task.id]!,
              problem.tasks,
            );
            if (score.isEligible) {
              ranked.add(
                _RankedCandidate(
                  candidate,
                  score.totalScore!,
                  candidate.durationMinutes +
                      math.min(
                        remaining - candidate.durationMinutes,
                        _continuationCapacity(task, slots, [
                          ...blocks,
                          _temporaryBlock(task.id, candidate),
                        ], notBefore: _restReadyAt(problem, task, candidate)),
                      ),
                ),
              );
            }
          }
        }
        if (ranked.isEmpty) break;
        ranked.sort(_compareRankedCandidates);
        final selected = ranked.first.candidate;
        final explanationCode = _explanationCode(
          problem,
          task,
          selected,
          blocks,
        );
        final block = PlannedBlock(
          id: _blockId(task.id, selected),
          taskId: task.id,
          range: selected.range,
          explanationCode: explanationCode,
        );
        blocks.add(block);
        chargeMovable(block);
        chargeTaskMinutes(block);
        remaining -= selected.durationMinutes;
        scheduledByTask.update(
          task.id,
          (value) => value + selected.durationMinutes,
          ifAbsent: () => selected.durationMinutes,
        );
      }
    }

    _improve(
      problem,
      slots,
      blocks,
      targets,
      chunkGenerator,
      allocationPlan,
      ledger,
    );
    // FR-CAL-05 的"不锁定"那一支：被手动拖动、但用户没有选择锁定的块，在**本次生成**里
    // 必须按锁定对待（因此上面的 `_improve` 跳过了它），否则局部改进会立刻把它搬回去，
    // 用户看到的就是"拖了没用"。生成结束后再把这些块的 `locked` 改回 false 输出，于是它
    // **落在用户放的位置、但落地为未锁定**，后续重排可以移动它——两条分支的差别到此是真实
    // 且可观察的。
    if (problem.pinnedUnlockedBlockIds.isNotEmpty) {
      for (var index = 0; index < blocks.length; index++) {
        final block = blocks[index];
        if (block.locked && problem.pinnedUnlockedBlockIds.contains(block.id)) {
          blocks[index] = PlannedBlock(
            id: block.id,
            taskId: block.taskId,
            range: block.range,
            explanationCode: block.explanationCode,
          );
        }
      }
    }
    blocks.sort(_compareBlocks);
    for (final block in blocks) {
      final code = block.explanationCode;
      if (code == null) continue;
      explanations.add(
        PlanExplanation(
          code: code,
          parameters: {
            'taskId': block.taskId,
            'startUtc': block.startUtc.toIso8601String(),
            'durationMinutes': block.durationMinutes,
          },
        ),
      );
    }

    // ── 最小化改动（1.8.0，规范 §11.4 第 3、4 条）──────────────────────────────
    //
    // 生成是"从零排一遍"，引擎因此不知道哪些块**本来就在合适的位置**。用户按一次
    // "延后 30 分钟"，引擎可能顺手把一整天重排一遍——而规范要的是"少动"：
    // 先比被移动的块数，再比总位移分钟。
    //
    // 这一步把**还能回到原位**的块放回原位，每一步都过验证器，因此它只可能减少改动、
    // 不可能制造新冲突。它**必须排在最终诊断之前**（计划 §2.3 / Task 5 Step 3 的顺序）：
    // 诊断问的是"最终块集合上还有没有合法位置"，而最小化改动会改变块的位置，
    // 因此诊断必须看到最小化之后的集合。
    final minimized = minimizeChangedBlocks(
      problem: problem,
      blocks: blocks,
      dayStartUtc: _dayBoundary(problem, before: true),
      dayEndUtc: _dayBoundary(problem, before: false),
      validator: _validator,
    );
    blocks
      ..clear()
      ..addAll(minimized.blocks);
    blocks.sort(_compareBlocks);

    // ── 最终诊断：**只看最终块集合**（计划 §2.3 / Task 5 Step 3）──────────────────
    //
    // 执行顺序是固定的，不可调换：
    // 初次放置 → `_improve` → provenance/stability 处理 → 排序 →
    // 计算最终 shortage → `diagnoseTaskPlacement` → `unscheduled`/`conflicts`。
    //
    // **最终原因不得读放置循环里的任何中间数据**：循环里每一次拒绝都是"**试**一个候选"
    // 的副产物，它按**当时**的剩余量算出来，而那次尝试可能并没有被采纳。用旧轮次的证据
    // 解释最终缺口，就会给出用户无法据以行动、甚至与事实矛盾的说法（R5）。
    final unscheduled = <UnscheduledTask>[];
    // **每件有缺口任务的最终诊断随提案走**（计划 §2.3）：预览的"查看未使用空档"要的是
    // 每段空档**为什么用不上**，而那只有最终诊断说得出来。它只进内存提案——
    // 不写日志、不写遥测、不进数据库（`ScheduleProposal.placementDiagnostics` 的说明）。
    final placementDiagnostics = <String, TaskPlacementDiagnostics>{};
    // 被识别为**无法解释的排程异常**的任务（§2.5 第三条不变量）。
    //
    // 判据只有一条：按**最终块集合**看，仍然存在一个可采纳的合法候选，而缺口依然大于零
    // （`hasEligibleCandidate && shortage > 0`）。它不是"容量不足"——
    // 用户要做的不是腾时间，而是重新生成并把问题报上来。
    final unexplainedTaskIds = <String>{};
    for (final task in [
      ...problem.tasks,
    ]..sort((a, b) => a.id.compareTo(b.id))) {
      final scheduled = blocks
          .where((block) => block.taskId == task.id)
          .fold<int>(0, (sum, block) => sum + block.durationMinutes);
      final shortage = math.max(0, targets[task.id]! - scheduled);
      if (shortage <= 0) continue;
      final diagnostics = diagnoseTaskPlacement(
        problem: problem,
        task: task,
        remainingMinutes: shortage,
        availability: availability,
        ledger: ledger,
        finalBlocks: blocks,
        zones: _zones,
      );
      if (diagnostics.hasEligibleCandidate) {
        unexplainedTaskIds.add(task.id);
      }
      // 诊断在**调用处**入账：`diagnoseTaskPlacement` 是被诊断任务的唯一来源，
      // 因此"提案里的诊断"与"引擎真的诊断过"不会各说一套。
      placementDiagnostics[task.id] = diagnostics;
      unscheduled.add(
        UnscheduledTask(
          taskId: task.id,
          shortageMinutes: shortage,
          primaryReason: diagnostics.reasons.first,
          // "展开查看其他限制"读的是**同一份最终诊断**的全部证据，
          // 不再是跨轮次累计的拒绝记录。
          reasons: diagnostics.reasons,
        ),
      );
    }

    // **容量缺口只有一个结构化来源**（1.8.0，冻结决策 §1.5）：`unscheduled`。
    //
    // 修复前这里还会为每个 `UnscheduledTask` 再补一条
    // `ConflictCode.insufficientCapacity`，而预览又把它翻成一句独立的文案 ——
    // 于是同一件事在页面上说两到三遍（截图里的"可用时间不足"＋"「蓝桥杯竞赛课」还缺 76 分钟"，
    // 见 R6）。`insufficientCapacity` 这个枚举值保留，但它现在只由
    // `PlanApplicationService` 在 `completeOnly` 模式下**作为返回结果**构造
    // （用于告诉调用者"需要明确允许部分计划"），不再由引擎写进 `proposal.conflicts`。
    final conflicts = [
      // **准入期的阻断冲突由装配层给出、引擎原样并入**（1.8.0 专项 §1.7）：
      // 它们在排程开始之前就已经成立（例如任务自己的时间边界自相矛盾），
      // 排程层只负责让它们随提案走到预览，**绝不重新判定一遍**——
      // 两处各判一次就意味着两份规则迟早漂移。
      ...problem.admissionConflicts,
      ..._validator.validate(problem, blocks),
    ];
    // ── 无法解释的零安排 ⇒ 提升为**阻断**问题（1.8.0 专项 §2.4 / §5 A13）─────────
    //
    // 计划 §2.3 Task 5 Step 6：`hasEligibleCandidate && shortage > 0` 必须**同时**产生
    // `unexplainedSchedulingFailure`（上面 `unscheduled` 里那条主原因）与
    // `ConflictCode.schedulingInvariantViolation`（这里这条冲突）。
    // `classifyProposal()` 因此返回 `blocked`，而 `PlanApplicationService.apply()`
    // 在 validator 之前就检查 `proposal.conflicts`——`allowPartial` 也绕不过去。
    //
    // **只能有一条用户可见问题**：预览层会把这一条 blocker 与 `unscheduled` 里那条
    // **合成一条**呈现（见 `buildPreviewIssues`）。这里不再补第二条
    // `insufficientCapacity` 冲突——那是"同一件事说两三遍"的旧形态，冻结决策 §1.5 已经禁掉。
    for (final taskId in unexplainedTaskIds.toList()..sort()) {
      conflicts.add(
        PlanningConflict(
          code: ConflictCode.schedulingInvariantViolation,
          taskId: taskId,
        ),
      );
    }
    final scheduledMinutes = blocks.fold<int>(
      0,
      (sum, block) => sum + block.durationMinutes,
    );
    final unscheduledMinutes = unscheduled.fold<int>(
      0,
      (sum, task) => sum + task.shortageMinutes,
    );
    return ScheduleProposal(
      proposalId: 'proposal:${problem.inputHash}:$algorithmVersion',
      inputHash: problem.inputHash,
      algorithmVersion: algorithmVersion,
      // **生成时的窗口随提案走**（1.8.0，冻结决策 §1.3）：预览装配层要在生成**之后**
      // 按同一个边界过滤两侧的块，而那时 `ScheduleProblem` 已经不在手里了。
      planningWindow: problem.planningWindow,
      blocks: blocks,
      unscheduled: unscheduled,
      conflicts: conflicts,
      explanations: explanations,
      placementDiagnostics: placementDiagnostics,
      metrics: ProposalMetrics(
        isFullyFeasible: conflicts.isEmpty && unscheduled.isEmpty,
        scheduledMinutes: scheduledMinutes,
        unscheduledMinutes: unscheduledMinutes,
      ),
    );
  }

  int _targetFor(ScheduleProblem problem, SchedulableTask task) {
    final dueAt = task.dueAtUtc;
    if (dueAt == null || !dueAt.isAfter(problem.planningWindow.endUtc)) {
      return task.requiredMinutes;
    }
    final capacity = CapacityModel.estimate(
      nowUtc: problem.planningWindow.startUtc,
      horizonEndUtc: problem.planningWindow.endUtc,
      dueAtUtc: dueAt,
      // **必须裁剪到规划窗口之内**：`CapacityModel` 会请求
      // `[now, effectiveHorizonEnd]` 与 `[effectiveHorizonEnd, evaluatedUntil]`
      // 两个子区间，而 `evaluatedUntil` 是**截止时间**——它可能远在窗口之外
      // （规模用例里有截止在 13 天后的任务）。
      //
      // 两件事同时被这个裁剪修好：
      //
      // 1. **缺日**：逐日策略只覆盖窗口涉及的日期，不裁剪的区间会在
      //    `AvailabilityBuilder` 里碰上缺日的 `StateError`。
      // 2. **远期任务的节奏被算歪**（算法 17 修掉的真实缺陷）：修复前
      //    `capacityForRange` 只在**已经算好的** `analysis.slots` 里筛，
      //    于是"窗口之外的 23 天"被当成有容量的时间（实测 `after=22080`）。
      //    一个 120 分钟、截止在 30 天后的任务因此算出 `pacedNow = 28`，
      //    被抬到最小片段 30 —— 只排 30 分钟。而**窗口之外根本没有可排时段**，
      //    把那部分算进"截止前总容量"会让近期推进量被系统性低估。
      //    裁剪之后 `after = 0`，同一个任务按"这一周有多少容量"推进，
      //    一周内排满 120。
      //
      // **裁剪的是"分析范围"，不是"任务语义"**：目标分钟仍然由
      // `PressureCalculator` 按截止距离算，变的只是"用哪一段时间估容量"。
      capacityForRange: (start, end) {
        final clippedStart = start.isBefore(problem.planningWindow.startUtc)
            ? problem.planningWindow.startUtc
            : start;
        final clippedEnd = end.isAfter(problem.planningWindow.endUtc)
            ? problem.planningWindow.endUtc
            : end;
        if (!clippedEnd.isAfter(clippedStart)) return 0;
        return _availabilityBuilder
            .build(
              _availabilityInput(
                problem,
                TimeRange(startUtc: clippedStart, endUtc: clippedEnd),
              ),
            )
            .fold<int>(0, (sum, slot) => sum + slot.durationMinutes);
      },
    );
    return _ensurePlaceable(
      _pressureCalculator.calculate(task, capacity).targetMinutes,
      problem,
      task,
    );
  }

  /// **可用时间输入的唯一构造点**（算法 17，计划 §5.1「硬占用区间的唯一来源」）。
  ///
  /// 生成主路径与"按截止估算容量"这条路径都调它，因此两处的硬占用集合、
  /// 逐日策略与粒度**不可能各算一套口径**。修复前它们各写一遍 `AvailabilityInput`，
  /// 于是"目标算出来的容量"与"候选真正能用的容量"可以互相矛盾。
  ///
  /// [window] 必须是 [problem] 规划窗口的**子区间**：逐日策略只覆盖窗口涉及的日期，
  /// 而子区间的本地日集合必然是窗口本地日集合的子集。反过来（传入超出窗口的区间）
  /// 会在 `AvailabilityBuilder` 里因为缺日而抛 [StateError]——这是有意的，
  /// 缺日必须响亮地失败，而不是悄悄回退到窗口首日。
  AvailabilityInput _availabilityInput(
    ScheduleProblem problem,
    TimeRange window,
  ) => AvailabilityInput(
    planningWindow: window,
    timeZoneId: problem.timeZoneId,
    rules: problem.rules,
    // **逐日策略是可用时间层的唯一规则来源**（计划 Task 2 Step 5）：
    // 粒度与睡眠从此按空闲段所属的本地日取，而不是窗口首日。
    dailyPolicies: problem.dailyPolicies,
    fixedIntervals: problem.fixedIntervals.map((item) => item.range).toList(),
    protectedIntervals: problem.protectedIntervals
        .map((item) => item.range)
        .toList(),
    lockedBlocks: problem.lockedBlocks.map((item) => item.range).toList(),
    // "拖动了但没锁定"的块占住视觉空白、且计入当日可移动预算（见该字段的说明）。
    chargedMovableBlocks: [
      for (final block in problem.lockedBlocks)
        if (problem.pinnedUnlockedBlockIds.contains(block.id)) block.range,
    ],
  );

  /// 把"大于零但小于最小可排片段"的目标抬到真正可排的最小量（不超过任务剩余时长）。
  ///
  /// 设计 §5.3 的均匀推进量 `pacedNow` 可能低于 `minChunkMinutes`，而候选生成不会
  /// 产出比最小片段更短的块，于是目标虽为正却一个片段也放不下——远端任务因此整周
  /// 排入 0 分钟（实测：截止在 30 天后的 120 分钟任务 `scheduled=0`、`shortage=28`），
  /// FR-SCHED-02 要求的"为避免未来拥堵所需的近期投入"落空。目标一旦大于零即表示
  /// 需要开始投入，因此抬到确实可排的最小量。
  ///
  /// 连续任务只有"整块"一种候选，其最小可排量就是任务剩余时长——即要么整体排入，
  /// 要么一个也排不进；这是不可拆分任务的固有取舍，不额外处理。
  int _ensurePlaceable(
    int target,
    ScheduleProblem problem,
    SchedulableTask task,
  ) {
    if (target <= 0) return 0;
    if (target >= task.requiredMinutes) return task.requiredMinutes;
    final granularity = problem.rules.granularityMinutes;
    final minimumPlaceable = task.splitMode == TaskSplitMode.continuous
        ? task.requiredMinutes
        : ((task.minChunkMinutes + granularity - 1) ~/ granularity) *
              granularity;
    if (target >= minimumPlaceable) return target;
    return math.min(minimumPlaceable, task.requiredMinutes);
  }

  int _compareTasks(
    SchedulableTask a,
    SchedulableTask b,
    List<AvailabilitySlot> slots,
    Map<String, int> targets,
  ) {
    final aSlack = _effectiveSlack(a, slots, targets[a.id]!);
    final bSlack = _effectiveSlack(b, slots, targets[b.id]!);
    final slackOrder = aSlack.compareTo(bSlack);
    if (slackOrder != 0) return slackOrder;
    final priorityOrder = b.priority.index.compareTo(a.priority.index);
    if (priorityOrder != 0) return priorityOrder;
    final dueOrder = _compareNullableDates(a.dueAtUtc, b.dueAtUtc);
    if (dueOrder != 0) return dueOrder;
    return a.id.compareTo(b.id);
  }

  int _effectiveSlack(
    SchedulableTask task,
    List<AvailabilitySlot> slots,
    int target,
  ) {
    if (task.dueAtUtc == null) return 1 << 30;
    final capacity = slots
        .where((slot) => !slot.endUtc.isAfter(task.dueAtUtc!))
        .fold<int>(0, (sum, slot) => sum + slot.durationMinutes);
    return capacity - target;
  }

  CandidateScore _scoreCandidate(
    ScheduleProblem problem,
    SchedulableTask task,
    SchedulingCandidate candidate,
    List<PlannedBlock> blocks,
    int targetMinutes,
    List<SchedulableTask> pendingTasks,
  ) {
    final plannedLifeMinutes = _plannedLifeMinutes(problem.tasks, blocks);
    return _candidateScorer.score(
      candidate,
      CandidateScoringContext(
        task: task,
        slotEnergyLevel: _energyAt(problem, candidate),
        preferredTimeScore: _preferredTimeScore(problem, task, candidate),
        deadlineRiskPermille: task.dueAtUtc == null ? 0 : 1000,
        progressPressurePermille: task.requiredMinutes == 0
            ? 0
            : targetMinutes * 1000 ~/ task.requiredMinutes,
        lifeQuotaTargetMinutes: problem.rules.weeklyLifeQuotaMinutes,
        plannedLifeMinutes: plannedLifeMinutes,
        fragmentationPenaltyPermille: _fragmentation(task, candidate),
        unusableGapPenaltyPermille: _unusableGapPermille(
          candidate,
          blocks,
          pendingTasks,
        ),
        sameTaskAdjacent: _sameTaskOnSameDay(problem, task, candidate, blocks),
        categorySwitch: _neighboursAnotherTask(
          problem,
          task,
          candidate,
          blocks,
        ),
        movesExistingBlock: _movesExistingBlock(problem, task, candidate),
        hardConstraintsSatisfied:
            !_overlapsAny(candidate.range, blocks) &&
            (task.dueAtUtc == null ||
                !candidate.endUtc.isAfter(task.dueAtUtc!)),
      ),
    );
  }

  /// 最小化改动那一步用的"当天"边界（1.8.0，规范 §11.4）。
  ///
  /// **取参照块自己所在的那一天**（按问题自己的时区算），而不是规划窗口的首尾：
  /// 窗口可能横跨七天，而"少动"这件事是**逐个本地日**判断的——
  /// 用七天的窗口会让"原位是否空着"的判断掺进别的日子。
  ///
  /// 参照为空（没有确认计划）时退化为规划窗口本身：那种情况下没有任何块有"调整前"，
  /// 最小化改动是空操作，边界取什么都不影响结果。
  DateTime _dayBoundary(ScheduleProblem problem, {required bool before}) {
    final references = problem.referenceBlocks.values;
    if (references.isEmpty) {
      return before
          ? problem.planningWindow.startUtc
          : problem.planningWindow.endUtc;
    }
    var earliest = references.first;
    var latest = references.first;
    for (final instant in references) {
      if (instant.isBefore(earliest)) earliest = instant;
      if (instant.isAfter(latest)) latest = instant;
    }
    final local = _zones.toLocal(earliest, problem.timeZoneId);
    final dayStart = _zones.localMidnightToUtc(
      DateTime.utc(local.year, local.month, local.day),
      problem.timeZoneId,
    );
    final dayEnd = _zones.localMidnightToUtc(
      DateTime.utc(local.year, local.month, local.day + 1),
      problem.timeZoneId,
    );
    if (!before) {
      // 参照块跨越多个本地日时，"当天"取到**最晚那一天的结束**：
      // 与 `dayStart` 一起构成一个能容纳全部参照块的窗口，而不是把它们截断。
      final localLatest = _zones.toLocal(latest, problem.timeZoneId);
      return _zones.localMidnightToUtc(
        DateTime.utc(localLatest.year, localLatest.month, localLatest.day + 1),
        problem.timeZoneId,
      );
    }
    return dayStart.isBefore(dayEnd)
        ? dayStart
        : problem.planningWindow.startUtc;
  }

  /// 计算设计 §5.4「任务期望时段」因子。
  ///
  /// 因子本身的语义、插值方式以及午夜与 24:00 边界的处理实现在
  /// `preferred_time_scorer.dart` 的纯函数中——那里是可直接单测的位置；这里只负责
  /// 把问题与权重折算成它需要的参数。
  int _preferredTimeScore(
    ScheduleProblem problem,
    SchedulableTask task,
    SchedulingCandidate candidate,
  ) {
    final weights = _candidateScorer.weights;
    return preferredTimeScore(
      window: task.preferredWindow,
      candidateRange: candidate.range,
      localDate: candidate.localDate,
      timeZoneId: problem.timeZoneId,
      zones: _zones,
      minimumScore: weights.minimumPreferredTime,
      maximumScore: weights.maximumPreferredTime,
    );
  }

  /// **任务自己声明的每日上限**的判定核心：把"这一天该任务已经排了多少"做成一张表，
  /// 再由 [candidate] 问"加进去会不会超"。
  ///
  /// **放置循环不再调用它，而是调用 `candidate_eligibility.dart` 的
  /// `evaluateCandidateEligibility`**（计划 §2.3 Task 5 Step 1）：每日上限的判据必须
  /// 与最终诊断共用同一份实现，否则"引擎排得下、诊断说排不下"迟早发生。
  ///
  /// **为什么仍然保留一个查表版本**：局部改进（`_improve`）需要一个"当日已排分钟"的
  /// 不同视角——放置阶段看"到目前为止的全部块"，改进阶段看"除当前这一块以外的块"。
  /// 若两处各写一遍判据，就会再次漂移（`_exceedsMovableDailyLimit` 的注释里记着同一条教训）。
  bool _exceedsDailyQuotaFromTable({
    required SchedulableTask task,
    required SchedulingCandidate candidate,
    required Map<DateTime, int> plannedMinutesForTaskByDate,
  }) {
    final quota = task.maxMinutesPerLocalDay;
    if (quota == null) return false;
    final planned = plannedMinutesForTaskByDate[candidate.localDate] ?? 0;
    return planned + candidate.durationMinutes > quota;
  }

  /// 该任务按本地日期已经占用的分钟（只统计**该任务**的块）。
  Map<DateTime, int> _taskMinutesByLocalDate(
    ScheduleProblem problem,
    SchedulableTask task,
    List<PlannedBlock> blocks,
  ) {
    final result = <DateTime, int>{};
    for (final block in blocks) {
      if (block.taskId != task.id) continue;
      final date = _localDate(block.startUtc, problem.timeZoneId);
      result[date] = (result[date] ?? 0) + block.durationMinutes;
    }
    return result;
  }

  /// **每日可移动任务上限的统一判定**（1.7.1 计划 §2.4 / Task 2 Step 4）。
  ///
  /// 这条规则此前只由两处间接实现：`AvailabilityBuilder` 把上限当成"最多保留多少分钟候选"
  /// 从清晨开始消费（已删除），以及 `PlanValidator` 在整份提案上做最终校验。前者用"少看见一些
  /// 空档"来实现一条本该在**结果**上校验的规则，于是候选可见性依赖空档顺序，且用户看到的空闲
  /// 与引擎能选的空闲不一致。
  ///
  /// 现在在**选块时**检查它，初次放置与局部改进共用同一个函数——两处各写一遍必然会漂移，
  /// 而漂移的后果是"初次遵守、改进后超限"。
  ///
  /// ## 口径必须与 `PlanValidator` 一致
  ///
  /// 按候选起点所属**本地日期**汇总，与 `PlanValidator` 逐个字段对齐：
  /// - 只算**未锁定**块；
  /// - 但生成过程中为了固定位置而临时标成 `locked`、且 id 位于
  ///   `problem.pinnedUnlockedBlockIds` 的块**仍然计入**——否则会出现
  ///   "引擎认为没超、恢复 `locked: false` 后 `PlanValidator` 报 `dailyLimitExceeded`"，
  ///   把一次合法提案判为无效。
  /// - **上限不小于一天时整条规则不生效**，直接返回：这条短路同时是规模用例的救命稻草，
  ///   因为默认上限是 360 而规模用例里多数任务所在的日子早已排满。
  bool _exceedsMovableDailyLimit(
    ScheduleProblem problem,
    SchedulingCandidate candidate,
    Map<DateTime, int> movableMinutesByDate,
  ) {
    final limit = problem.rules.dailyMovableTaskLimitMinutes;
    if (limit >= LocalTimeRange.minutesPerDay) return false;
    final planned = movableMinutesByDate[candidate.localDate] ?? 0;
    return planned + candidate.durationMinutes > limit;
  }

  /// 按本地日期汇总**未锁定**（含生成期间被临时固定）块的分钟数。
  ///
  /// **在候选循环之外算一次**。此前每个候选都要线性扫一遍 `blocks` 才能算出同一个数字，
  /// 总成本是 `候选数 × 块数`；取消候选截断后候选数上升，这一项直接变成规模用例的主要开销
  /// （实测 1.6 秒 → 3.3 秒）。这里把"看块"的部分挪到循环外，判定退化为一次 Map 查表。
  ///
  /// 调用方必须在**每次 `blocks` 变化后**重新调用它，否则判定会用到过期数字。
  /// 按本地日期汇总**计入每日可移动上限**的任务块分钟。
  ///
  /// ## 为什么**包含锁定块**
  ///
  /// 计划把它写得很死（§术语表 + Task 3 验收式）：
  ///
  /// > **日已用量** `usedMovableMinutes`：当前基线里当日所有**计入可移动上限**的
  /// > 任务块分钟，**包含锁定/钉住的任务块**，不含固定和保护日程。
  /// >
  /// > `remainingMinutes = min(max(0, calendarGap − allocated),
  /// > max(0, licensed − used − allocated))`
  ///
  /// 因此锁定额度与可移动额度是**同一份**额度：锁定 300 分钟会占掉上限 360 里的 300。
  ///
  /// 修复前这里**跳过锁定块**，于是 `_exceedsMovableDailyLimit` 只统计本轮新排的块，
  /// 上限对锁定时间完全失效。实测（`movable_daily_limit_test`）：
  /// 锁定 300 + 上限 360 时，引擎仍然排下了 300 分钟的可移动任务，
  /// 当天合计 600 分钟——**超过上限 360**，而计划要求最多 60。
  ///
  /// **与账本同源**：账本的 `usedMovableMinutes` 用的是同一份块集合与同一个
  /// "锁定也计入"口径，两处因此给出同一个数字。
  ///
  /// 调用方必须在**每次 `blocks` 变化后**重新调用它，否则判定会用到过期数字。
  Map<DateTime, int> _movableMinutesByDate(
    ScheduleProblem problem,
    List<PlannedBlock> blocks,
  ) {
    final result = <DateTime, int>{};
    for (final block in blocks) {
      final date = _localDate(block.startUtc, problem.timeZoneId);
      result[date] = (result[date] ?? 0) + block.durationMinutes;
    }
    return result;
  }

  /// 每个本地日期能承接多少分钟：把该日的可用时段取**并集**后求和。
  ///
  /// 取并集是必要的：候选是按"起点 × 时长"展开的，同一段空闲会被重复计入很多次，
  /// 直接累加候选时长会把容量放大到没有意义。
  ///
  /// **只统计计划窗口覆盖到的本地日**：窗口可能是"周四 20:00 到下周一 00:00"这种形状，
  /// 于是第一天（周四）只有半个晚上可用。若不限制，窗口边界所在的**前一天**（因为 UTC 与
  /// 本地日错位而出现）也会被当成一个可选日期，白白吃掉一份预算——实测 `210 ÷ 8 天`
  /// 而不是 `÷ 4 天`。
  ///
  /// **也必须只统计任务自己的截止时间之前的本地日**（1.8.0，"可见空闲却报容量不足"专项）。
  ///
  /// 这一条是那场故障的直接成因：均分器按**七日规划窗口**摊量，而候选生成按
  /// `dueAtUtc` 过滤。当任务截止在本周内（周期目标的"本周末"就是这种形状）时，
  /// 窗口里**截止之后的那几天**照样分到一份预算——它们永远产不出候选，于是：
  /// · 可分配量被那几天白吃掉一块 ⇒ 真正能排的几天只拿到"目标 ÷ 7 天"；
  /// · 每个日期都不到一个最小片段时，放置循环一个候选都选不出来 ⇒
  ///   `scheduled = 0` 或"只排进去一部分"，而用户看到的日历明明白白还有大片空档。
  ///
  /// 实测（本专项回归夹具）：210 分钟、截止周日、七日窗口 ⇒ 均分给出**每天 30 分钟**，
  /// 其中三天在截止之后；引擎只排进 120 分钟，剩下 90 分钟被报成 `dailyLimitReached`。
  /// 只按截止筛掉那三天之后，同样的输入一次排满 210。
  /// 该任务在这些块上按本地日期已经占用的分钟。
  ///
  /// 均分器的 `alreadyPlannedMinutesByLocalDate` 用它：那些分钟已经占了这一天的一部分，
  /// 均分器要算的是"还差多少"，不是"从零开始"。
  Map<DateTime, int> _plannedMinutesByLocalDate(
    ScheduleProblem problem,
    SchedulableTask task,
    List<PlannedBlock> blocks,
  ) {
    final result = <DateTime, int>{};
    for (final block in blocks) {
      if (block.taskId != task.id) continue;
      final date = _localDate(block.startUtc, problem.timeZoneId);
      result[date] = (result[date] ?? 0) + block.durationMinutes;
    }
    return result;
  }

  /// 候选所属本地日还剩多少**新增**预算。
  ///
  /// 从计划的 `additionalMinutesByLocalDate` 减去"本次生成已在该日放下的分钟"，后者由当前
  /// `blocks` 里该任务的块推算——**不留可变状态**，因此同样的输入必然得到同样的结果
  /// （排程器的确定性要求）。
  int _budgetRemaining(
    SchedulingCandidate candidate,
    TaskDayBudget budget,
    Map<DateTime, int> taskMinutesByDate,
  ) {
    final allowed = budget.minutesByLocalDate[candidate.localDate] ?? 0;
    if (allowed <= 0) return 0;
    return allowed - (taskMinutesByDate[candidate.localDate] ?? 0);
  }

  /// 同一任务在该候选所在本地日是否已有其它片段。
  /// 设计 §9.4 的"同一任务片段的连续性"：把同一任务的片段聚合在同一天内，
  /// 比分散到多天更利于连续推进。注意本规则与片段间休息并不冲突——休息要求
  /// 片段之间留出间隔，连续性只要求它们落在同一天。
  bool _sameTaskOnSameDay(
    ScheduleProblem problem,
    SchedulableTask task,
    SchedulingCandidate candidate,
    List<PlannedBlock> blocks,
  ) => blocks.any(
    (block) =>
        block.taskId == task.id &&
        _localDate(block.startUtc, problem.timeZoneId) == candidate.localDate,
  );

  /// 该候选是否会导致"已确认但未锁定"的时间块被迫移动。
  ///
  /// 设计 §5.4 的"移动已确认但未锁定的时间块 0 至 -700"：已确认的计划应尽量稳定。
  /// 提案是按锁定块重新生成的，未锁定的已确认块不会自动延续，因此：
  ///
  /// - 候选与某次已确认块的位置**完全一致** → 那次确认得以原样保留，**不计**代价；
  /// - 本任务已有确认块、而候选与任何一次都不完全一致 → 那些块要移动，计一次代价
  ///   （部分重叠同样算移动：它并不是保留原安排，而是与它冲突）；
  /// - 候选占用了**其它任务**已确认块的位置 → 那个块必须让位，同样计一次代价。
  ///
  /// 已锁定的块不出现在 `existingBlocks` 中：它们由硬约束冻结，候选落不上去。
  bool _movesExistingBlock(
    ScheduleProblem problem,
    SchedulableTask task,
    SchedulingCandidate candidate,
  ) {
    final existing = problem.existingBlocks;
    if (existing.isEmpty) return false;
    if (existing.any(
      (block) =>
          block.taskId != task.id && block.range.overlaps(candidate.range),
    )) {
      return true;
    }
    final own = existing.where((block) => block.taskId == task.id).toList();
    if (own.isEmpty) return false;
    return !own.any((block) => block.range == candidate.range);
  }

  /// 候选在时间上紧邻的片段是否属于其它任务。
  ///
  /// 设计 §9.4 的"相邻任务的类别切换成本"：取候选之前最近的片段与之后最近的
  /// 片段作为相邻活动，任一属于其它任务且落在同一本地日内即计一次切换。
  /// 不引入额外的时间阈值——"相邻"即"中间没有其它片段的那个"。
  bool _neighboursAnotherTask(
    ScheduleProblem problem,
    SchedulableTask task,
    SchedulingCandidate candidate,
    List<PlannedBlock> blocks,
  ) {
    PlannedBlock? predecessor;
    PlannedBlock? successor;
    for (final block in blocks) {
      if (block.endUtc.isAfter(candidate.startUtc)) {
        if (successor == null || block.startUtc.isBefore(successor.startUtc)) {
          successor = block;
        }
      } else if (predecessor == null ||
          block.endUtc.isAfter(predecessor.endUtc)) {
        predecessor = block;
      }
    }
    bool switchesFrom(PlannedBlock? block) =>
        block != null &&
        block.taskId != task.id &&
        _localDate(block.startUtc, problem.timeZoneId) == candidate.localDate;
    return switchesFrom(predecessor) || switchesFrom(successor);
  }

  int _fragmentation(SchedulableTask task, SchedulingCandidate candidate) {
    if (task.splitMode == TaskSplitMode.continuous ||
        task.maxChunkMinutes <= task.minChunkMinutes) {
      return 0;
    }
    return (task.maxChunkMinutes - candidate.durationMinutes) *
        1000 ~/
        (task.maxChunkMinutes - task.minChunkMinutes);
  }

  /// 这次放置会留下的**无法利用的短空档**深度，折算成千分比（1.8.0，规范 §11.4 第 6 条）。
  ///
  /// **与 `_fragmentation` 是两件不同的事**：那个惩罚"这一块比最大片段短多少"（块的形状），
  /// 这个惩罚"这次放置让谁也放不进去的缝有多深"（空档的可用性）。
  ///
  /// **用固定窗口而不是全量扫描**，理由是**可比较性**：每个候选都只看"自己的位置 ＋ 左右各
  /// 两段邻块"，于是这一项反映的是"这一个候选有多碎"，而不是"当前计划整体有多碎"。
  /// 全量扫描会把一天里早已存在的坏空档也算进来——那是常量，对比较候选毫无用处。
  ///
  /// 深度取**最深的那一段缝**占"最小片段"的比例：缝越接近最小片段，说明这次放置越是
  /// "差一点点就能用"，越该被罚。
  int _unusableGapPermille(
    SchedulingCandidate candidate,
    List<PlannedBlock> blocks,
    List<SchedulableTask> pendingTasks,
  ) {
    final smallestChunk = _smallestPendingChunk(pendingTasks);
    if (smallestChunk == null) return 0;
    final wasted = _wastedGapMinutes(candidate, blocks, smallestChunk);
    if (wasted <= 0) return 0;
    // 折算成千分比：以"最小片段"为一个完整单位。
    // 一段 29 分钟（最小片段 30）的缝因此得 966，几乎吃满；一段 1 分钟得 33。
    return (wasted * 1000 ~/ smallestChunk).clamp(0, 1000);
  }

  /// 候选块两侧被浪费的分钟数（只算短于 [smallestChunk] 的缝）。见 [_unusableGapPermille]。
  static int _wastedGapMinutes(
    SchedulingCandidate candidate,
    List<PlannedBlock> blocks,
    int smallestChunk,
  ) {
    // 负向扫描：只看**开始时刻早于候选**的块，取其中结束最晚的一个；
    // 正向扫描：只看**开始时刻不早于候选结束**的块，取其中开始最早的一个。
    // 用"结束最晚／开始最早"而不是"最近的一个"：相邻块可能互相重叠，只取一个会算错缝。
    DateTime? leftEnd;
    DateTime? rightStart;
    for (final block in blocks) {
      // **候选自己可能就在 `blocks` 里**：局部改进阶段传进来的 `others` 已经排除了它，
      // 但放置阶段不会。把自己当成邻居会让缝算成零或负值，从而**每**次都吃到满额惩罚
      // ——那正是"golden week"那条用例变红的原因（缺口 30 → 90）。
      if (block.id == candidate.id) continue;
      if (block.range.overlaps(candidate.range)) continue;
      if (!block.startUtc.isAfter(candidate.startUtc)) {
        if (leftEnd == null || block.endUtc.isAfter(leftEnd)) {
          leftEnd = block.endUtc;
        }
        continue;
      }
      if (rightStart == null || block.startUtc.isBefore(rightStart)) {
        rightStart = block.startUtc;
      }
    }

    var wasted = 0;
    if (leftEnd != null && leftEnd.isBefore(candidate.startUtc)) {
      wasted += _wastedMinutes(
        candidate.startUtc.difference(leftEnd).inMinutes,
        smallestChunk,
      );
    }
    if (rightStart != null && rightStart.isAfter(candidate.endUtc)) {
      wasted += _wastedMinutes(
        rightStart.difference(candidate.endUtc).inMinutes,
        smallestChunk,
      );
    }
    return wasted;
  }

  /// 一段 `gap` 分钟的缝**浪费掉多少分钟**。
  ///
  /// **不是"缺口越大越浪费"，而是"缺口越大越浪费"**——两者方向一致，但第一版把它写反了：
  /// 当时算的是"还差多少才够一个最小片段"（`smallestChunk - gap`），于是**越短**的缝罚得越重。
  /// `golden week` 那条用例当场把它抓出来：引擎宁可不要 10 分钟的休息，也不肯留一段
  /// "浪费更多"的缝，于是两个块贴在一起、缺口从 30 变成 90。
  ///
  /// 现在算的是**真浪费**：一段 29 分钟（最小片段 30）的缝浪费 29 分钟，一段 1 分钟的缝
  /// 只浪费 1 分钟，而达到最小片段长度的缝浪费 0（它完全可以放下一块）。
  static int _wastedMinutes(int gap, int smallestChunk) =>
      gap >= smallestChunk ? 0 : gap;

  /// 还没排完的任务里**最小**的片段长度；没有可排任务时返回 `null`。
  ///
  /// 与 `unusable_gap.dart` 的 `_smallestChunkMinutes` 同一条判据（用 `minChunkMinutes`
  /// 而不是剩余时长、用 `min` 而不是 `max`），只是那边是"给定块集合求坏空档"的纯函数、
  /// 这边是评分路径上的快速判定。两处都只认**没排完的**任务。
  static int? _smallestPendingChunk(List<SchedulableTask> pendingTasks) {
    int? smallest;
    for (final task in pendingTasks) {
      if (task.requiredMinutes <= 0) continue;
      final chunk = task.minChunkMinutes <= 0 ? 1 : task.minChunkMinutes;
      if (smallest == null || chunk < smallest) smallest = chunk;
    }
    return smallest;
  }

  int _continuationCapacity(
    SchedulableTask task,
    List<AvailabilitySlot> slots,
    List<PlannedBlock> blockers, {
    DateTime? notBefore,
  }) {
    var capacity = 0;
    for (final slot in slots) {
      final dueAt = task.dueAtUtc;
      final slotEnd = dueAt != null && dueAt.isBefore(slot.endUtc)
          ? dueAt
          : slot.endUtc;
      if (!slotEnd.isAfter(slot.startUtc)) continue;
      final cuts =
          blockers
              .where((block) => block.range.overlaps(slot.range))
              .map(
                (block) => (
                  start: block.startUtc.isAfter(slot.startUtc)
                      ? block.startUtc
                      : slot.startUtc,
                  end: block.endUtc.isBefore(slotEnd) ? block.endUtc : slotEnd,
                ),
              )
              .where((cut) => cut.end.isAfter(cut.start))
              .toList()
            ..sort((a, b) => a.start.compareTo(b.start));
      var cursor = slot.startUtc;
      // 只统计 notBefore 之后仍然可用的容量：候选之前的空闲段无法承接本任务
      // 的后续片段，把它们计入"可续排容量"会高估该候选的价值，并诱导引擎
      // 为了腾出一段用不上的空隙而把片段推后（实测会把间隔推成 30 分钟并白丢容量）。
      if (notBefore != null && notBefore.isAfter(cursor)) {
        cursor = notBefore.isAfter(slotEnd) ? slotEnd : notBefore;
      }
      for (final cut in cuts) {
        if (cut.start.isAfter(cursor)) {
          capacity += _usableSegmentMinutes(task, cursor, cut.start);
        }
        if (cut.end.isAfter(cursor)) cursor = cut.end;
      }
      if (cursor.isBefore(slotEnd)) {
        capacity += _usableSegmentMinutes(task, cursor, slotEnd);
      }
    }
    return capacity;
  }

  int _usableSegmentMinutes(
    SchedulableTask task,
    DateTime start,
    DateTime end,
  ) {
    final minutes = end.difference(start).inMinutes;
    if (task.splitMode == TaskSplitMode.continuous) {
      return minutes >= task.requiredMinutes ? task.requiredMinutes : 0;
    }
    return minutes >= task.minChunkMinutes ? minutes : 0;
  }

  EnergyLevel? _energyAt(
    ScheduleProblem problem,
    SchedulingCandidate candidate,
  ) {
    final midpoint = candidate.startUtc.add(
      Duration(minutes: candidate.durationMinutes ~/ 2),
    );
    final local = _zones.toLocal(midpoint, problem.timeZoneId);
    final minute = local.hour * 60 + local.minute;
    final windows =
        problem.preferences.enabled &&
            problem.preferences.preferredEnergyWindows != null
        ? problem.preferences.preferredEnergyWindows!
        : problem.rules.energyWindows;
    for (final window in windows) {
      if (!_matchesDay(window.dayKind, local.weekday)) continue;
      if (_containsLocalMinute(window.range, minute)) return window.level;
    }
    return null;
  }

  String _explanationCode(
    ScheduleProblem problem,
    SchedulableTask task,
    SchedulingCandidate candidate,
    List<PlannedBlock> blocks,
  ) {
    if (task.isLifeTask &&
        _plannedLifeMinutes(problem.tasks, blocks) <
            problem.rules.weeklyLifeQuotaMinutes) {
      return 'life_quota_gap';
    }
    if (task.dueAtUtc != null) return 'deadline_and_progress';
    final energy = _energyAt(problem, candidate);
    if ((task.energyLevel == TaskEnergyLevel.high &&
            energy == EnergyLevel.high) ||
        (task.energyLevel == TaskEnergyLevel.medium &&
            energy == EnergyLevel.medium) ||
        (task.energyLevel == TaskEnergyLevel.low &&
            energy == EnergyLevel.low)) {
      return 'energy_match';
    }
    return 'priority';
  }

  void _improve(
    ScheduleProblem problem,
    List<AvailabilitySlot> slots,
    List<PlannedBlock> blocks,
    Map<String, int> targets,
    CandidateGenerator candidates,
    DayAllocationPlan allocationPlan,
    DayCapacityLedger allocationLedger,
  ) {
    final tasks = {for (final task in problem.tasks) task.id: task};
    var operations = 0;
    for (
      var blockIndex = 0;
      blockIndex < blocks.length &&
          operations < localImprovementOperationBudget;
      blockIndex++
    ) {
      final block = blocks[blockIndex];
      if (block.locked) continue;
      final task = tasks[block.taskId];
      if (task == null) continue;
      final currentCandidate = SchedulingCandidate(
        id: block.id,
        taskId: block.taskId,
        range: block.range,
        localDate: _localDate(block.startUtc, problem.timeZoneId),
      );
      final others = [...blocks]..removeAt(blockIndex);
      final currentScore = _scoreCandidate(
        problem,
        task,
        currentCandidate,
        others,
        targets[task.id]!,
        problem.tasks,
      ).totalScore!;
      // `_improve` 只换位置、不换时长（下面按 `item.durationMinutes == block.durationMinutes`
      // 过滤），因此它必须问候选生成器："这一块**应当覆盖多少分钟**？"答案是
      // `requiredMinutes - otherMinutes`——`others` 已经排除了当前这一块，于是这个差
      // 就是**这一块要覆盖的分钟**（其余块各自覆盖它们自己的那份）。
      //
      // 为什么不能传 `task.requiredMinutes`：那会让 100 分钟任务在排完 90 分钟之后
      // 仍以"剩余 100"生成候选，短尾块（< `minChunkMinutes`）永远生成不出来，
      // 于是改进阶段无法重新安排那块合法的 10 分钟；传 0 或负数又会直接抛
      // `ArgumentError`。`math.max(block.durationMinutes, …)` 保底：其它块已经超发时
      // 至少按当前时长生成，等时长过滤仍可工作。
      final otherMinutes = others
          .where((b) => b.taskId == task.id)
          .fold<int>(0, (sum, b) => sum + b.durationMinutes);
      final remainingForBlock = math.max(
        block.durationMinutes,
        math.min(task.requiredMinutes, task.requiredMinutes - otherMinutes),
      );
      final alternatives = candidates
          .generate(task, slots, remainingMinutes: remainingForBlock)
          .where(
            (item) =>
                item.durationMinutes == block.durationMinutes &&
                (task.dueAtUtc == null || !item.endUtc.isAfter(task.dueAtUtc!)),
          )
          .toList();
      for (final candidate in alternatives) {
        if (operations++ >= localImprovementOperationBudget) break;
        if (_overlapsAny(candidate.range, others)) continue;
        if (_violatesRestGap(problem, task, candidate, others)) continue;
        // **任务自己声明的每日上限在改进阶段同样成立**（计划 §Global Constraints：
        // "每日上限"是硬约束）。判据与放置循环**是同一个函数**，只是"当日已排分钟"
        // 取自 `others`——它已排除当前这一块，问的正是"搬过去之后那一天会不会超"。
        //
        // 少了这一条，改进阶段能把块搬到已经用满当日额度的日子上：实测一个
        // `maxMinutesPerLocalDay = 30` 的任务在放置阶段正确地排成"每天 30 分钟"，
        // 随后被 `_improve` 把其中一块搬到另一天，于是那一天有 60 分钟，
        // 而引擎的输出只由 `PlanValidator` 把关——后者校验的是**全局**每日可移动上限，
        // 不是任务自己的额度，所以这里不会有任何冲突报出来。
        if (_exceedsDailyQuotaFromTable(
          task: task,
          candidate: candidate,
          plannedMinutesForTaskByDate: _taskMinutesByLocalDate(
            problem,
            task,
            others,
          ),
        )) {
          continue;
        }
        // 局部改进也必须守每日可移动上限：`others` **已经排除了当前这一块本身**，
        // 因此这里问的正是"把它搬到候选位置后，那一天会不会超限"。
        // 少了这一条，初次放置摊开的结果会在改进阶段被重新堆回同一天。
        // 判定表按 `others` 现算：`_improve` 会改动 `blocks`，复用放置阶段那份会过期。
        if (_exceedsMovableDailyLimit(
          problem,
          candidate,
          _movableMinutesByDate(problem, others),
        )) {
          continue;
        }
        // ── **跨日预算在改进阶段同样成立**（算法 17，计划 Task 5/6）──────────────
        //
        // 少了这一条会直接抹掉跨日分配的成果：实测「150 分钟、七天各余 90、
        // 粒度 30」时，放置阶段**正确地**排出 5 天各 30 分钟
        // （10-05/06/09/10/11），随后 `_improve` 把 10-05 的那块搬到了 10-06，
        // 于是 10-06 变成 60 分钟、10-05 归零——**参与日从 5 天掉到 4 天**，
        // 而分配器给的预算明明是每天 30。
        //
        // 判据与放置循环**同一个函数**（`_budgetRemaining`）：`others` 已排除当前
        // 这一块，因此这里问的正是"搬过去之后那一天会不会超预算"。
        final budgetForTask = allocationPlan.budgetFor(task.id);
        if (budgetForTask != null) {
          final allowed =
              budgetForTask.minutesByLocalDate[candidate.localDate] ?? 0;
          var alreadyOnDay = 0;
          for (final other in others) {
            if (other.taskId != task.id) continue;
            if (_localDate(other.startUtc, problem.timeZoneId) ==
                candidate.localDate) {
              alreadyOnDay += other.durationMinutes;
            }
          }
          if (allowed <= 0 ||
              alreadyOnDay + candidate.durationMinutes > allowed) {
            continue;
          }
        }
        final score = _scoreCandidate(
          problem,
          task,
          candidate,
          others,
          targets[task.id]!,
          problem.tasks,
        );
        if (!score.isEligible || score.totalScore! <= currentScore) continue;
        final replacement = PlannedBlock(
          id: block.id,
          taskId: block.taskId,
          range: candidate.range,
          explanationCode: _explanationCode(problem, task, candidate, others),
        );
        final trial = [...others, replacement];
        if (_validator.validate(problem, trial).isNotEmpty) continue;
        // ── **方案级闸门**（算法 17，计划 Task 7 Step 5）────────────────────────
        //
        // 上面那道 `score.totalScore > currentScore` 是**候选级**判据：它只看
        // "这一块放到新位置是不是更讨喜"（精力匹配、进度、紧迫度……）。
        // 候选级更优**不等于**整份方案更优——实测的典型形状就是
        // 「局部精力分更高，却把工作日负载从 70% 推到 100%、周末仍为 20%」。
        //
        // 因此这里再比一次**整案**：把 trial 当成一份完整方案，按 profile 对应的
        // 字典序目标与当前方案比较，只有**严格更优**才接受。
        if (!_wholePlanIsBetter(
          problem: problem,
          current: blocks,
          trial: trial,
          ledger: allocationLedger,
          targets: targets,
          allocationPlan: allocationPlan,
        )) {
          continue;
        }
        blocks[blockIndex] = replacement;
        break;
      }
    }
  }

  DateTime _localDate(DateTime instantUtc, String zoneId) {
    final local = _zones.toLocal(instantUtc, zoneId);
    return DateTime(local.year, local.month, local.day);
  }

  /// 这份问题应当按哪个方案目标档位比较（计划 Task 8 Step 4）。
  ///
  /// 三档的差别只在**比较顺序**（`scheduleObjectiveStageNames`），而这正是
  /// "该不该移动已确认的块"这条纪律的落点：
  ///
  /// - **有块级调整**（`adjustment != null`）⇒ `explicitAdjustment`：
  ///   用户点名要动某一块，因此允许为此移动相邻块；
  /// - **有确认基线**（`referenceBlocks` 非空、但没有点名调整）⇒ `backgroundReplan`：
  ///   后台重排，稳定性被大幅提前，"只改善一点点就别动"；
  /// - **从零生成** ⇒ `initialGeneration`：没有基线可保，比的是方案本身的质量。
  ///
  /// 判据**只从 `ScheduleProblem` 自身派生**，不接受调用方另传一个"请按 X 档比较"：
  /// 那样两处装配可能说法不一致，而这类不一致会表现为"同一份输入在预览与落地时
  /// 给出不同方案"——本计划要消灭的正是这种双真相。
  ScheduleObjectiveProfile _objectiveProfileOf(ScheduleProblem problem) {
    if (problem.adjustment != null) {
      return ScheduleObjectiveProfile.explicitAdjustment;
    }
    if (problem.referenceBlocks.isNotEmpty) {
      return ScheduleObjectiveProfile.backgroundReplan;
    }
    return ScheduleObjectiveProfile.initialGeneration;
  }

  /// 整案比较：`trial` 是否**严格优于** `current`（计划 Task 7 Step 5）。
  ///
  /// 两道判据都必须通过：
  /// 1. **结构自洽**：`PlanQualityValidator` 无违规（唯一块 ID、任务分钟守恒、
  ///    日预算、每日硬上限、缺口是否有解释）；
  /// 2. **方案不恶化**：按 [ScheduleObjectiveProfile.initialGeneration] 的字典序
  ///    比较，`trial` 必须严格更优。
  ///
  /// 用 `initialGeneration` 而不是另外两个 profile：这个引擎做的是**生成**，
  /// 没有"已确认基线"可依。带基线的重排（`backgroundReplan`）与块级调整
  /// （`explicitAdjustment`）走 `local_repair`，它们各自传入自己的 profile。
  bool _wholePlanIsBetter({
    required ScheduleProblem problem,
    required List<PlannedBlock> current,
    required List<PlannedBlock> trial,
    required DayCapacityLedger ledger,
    required Map<String, int> targets,
    required DayAllocationPlan allocationPlan,
  }) {
    final profile = _objectiveProfileOf(problem);
    final quality = PlanQualityValidator.validate(
      problem: problem,
      blocks: trial,
      ledger: ledger,
      zones: _zones,
      targets: targets,
      allocationPlan: allocationPlan,
    );
    if (quality.isNotEmpty) return false;
    final trialObjective = evaluateScheduleObjective(
      problem: problem,
      blocks: trial,
      ledger: ledger,
      zones: _zones,
      profile: profile,
    );
    final currentObjective = evaluateScheduleObjective(
      problem: problem,
      blocks: current,
      ledger: ledger,
      zones: _zones,
      profile: profile,
    );
    return compareScheduleObjectives(
          trialObjective,
          currentObjective,
          profile,
        ) <
        0;
  }

  /// 周期实例的「周期起点本地日期」表（计划 §3.4 第 7 条）。
  Map<String, DateTime> _cycleStartsByTask(ScheduleProblem problem) {
    final result = <String, DateTime>{};
    for (final task in problem.tasks) {
      final start = _cycleStartOf(task.id);
      if (start == null) continue;
      result[task.id] = start;
    }
    return result;
  }

  /// 形状 `recurring:<templateId>:<yyyy-MM-dd>`；不匹配返回 null（不猜）。
  DateTime? _cycleStartOf(String taskId) {
    if (!taskId.startsWith('recurring:')) return null;
    final lastColon = taskId.lastIndexOf(':');
    if (lastColon <= 0 || lastColon == taskId.length - 1) return null;
    final parts = taskId.substring(lastColon + 1).split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }
}

final class _RankedCandidate {
  const _RankedCandidate(this.candidate, this.score, this.coverageMinutes);
  final SchedulingCandidate candidate;
  final int score;
  final int coverageMinutes;
}

/// 候选级排序。**软约束总分是首键**，与设计 §5.2 第 7 步"选择最高分且不破坏
/// 硬约束的候选"一致；覆盖度只作为同分时的次级依据，不再反过来压过评分。
///
/// 历史：首键曾是 `coverageMinutes`，导致"一次吃更多目标时长"压过所有软约束，
/// 评分几乎只在覆盖度打平时才起作用（实测：给"片段间距不足"加惩罚后，引擎改变
/// 了分片方式却仍排出 0 分钟间隔）。
int _compareRankedCandidates(_RankedCandidate a, _RankedCandidate b) {
  final scoreOrder = b.score.compareTo(a.score);
  if (scoreOrder != 0) return scoreOrder;
  final coverageOrder = b.coverageMinutes.compareTo(a.coverageMinutes);
  if (coverageOrder != 0) return coverageOrder;
  final startOrder = a.candidate.startUtc.compareTo(b.candidate.startUtc);
  if (startOrder != 0) return startOrder;
  final taskOrder = a.candidate.taskId.compareTo(b.candidate.taskId);
  if (taskOrder != 0) return taskOrder;
  return a.candidate.id.compareTo(b.candidate.id);
}

int _compareBlocks(PlannedBlock a, PlannedBlock b) {
  final startOrder = a.startUtc.compareTo(b.startUtc);
  if (startOrder != 0) return startOrder;
  final taskOrder = a.taskId.compareTo(b.taskId);
  if (taskOrder != 0) return taskOrder;
  return a.id.compareTo(b.id);
}

int _compareNullableDates(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

bool _overlapsAny(TimeRange range, List<PlannedBlock> blocks) =>
    blocks.any((block) => range.overlaps(block.range));

int _plannedLifeMinutes(
  List<SchedulableTask> tasks,
  List<PlannedBlock> blocks,
) {
  final lifeTaskIds = {
    for (final task in tasks)
      if (task.isLifeTask) task.id,
  };
  return blocks
      .where((block) => lifeTaskIds.contains(block.taskId))
      .fold<int>(0, (sum, block) => sum + block.durationMinutes);
}

bool _matchesDay(DayKind dayKind, int weekday) => switch (dayKind) {
  DayKind.any => true,
  DayKind.weekday => weekday >= DateTime.monday && weekday <= DateTime.friday,
  DayKind.weekend => weekday == DateTime.saturday || weekday == DateTime.sunday,
};

bool _containsLocalMinute(LocalTimeRange range, int minute) =>
    range.crossesMidnight
    ? minute >= range.startMinute || minute < range.endMinute
    : minute >= range.startMinute && minute < range.endMinute;

String _blockId(String taskId, SchedulingCandidate candidate) =>
    'block:$taskId:${candidate.startUtc.microsecondsSinceEpoch}:'
    '${candidate.durationMinutes}';

/// 从 [ScheduleProblem.existingBlocks] 里挑出**可以作为起点**的块（Task 8）。
///
/// 关键点：返回的块**原样携带它们的 id**。这是"同一块换了位置时仍能被认出"
/// 的前提——`referenceBlocks` 与 `minimizeChangedBlocks` 都以 id 匹配，
/// 而引擎自己命名的 id 与确认计划的 persistedId 不同族。
///
/// 判据见调用处注释；这里只强调两件**不做**的事：
/// - **不按 id 做任何偏好**：id 长得像什么、来自哪一版提案，都不影响采纳；
/// - **不因"已经排过"而跳过**：既有块正是"已经排过"的那一份，采纳它就是目的。
///
/// 结果按 `(startUtc, id)` 排序，保证同一份输入得到同一个起点顺序。
List<PlannedBlock> _adoptableExistingBlocks({
  required ScheduleProblem problem,
  required List<AvailabilitySlot> slots,
  required Map<String, int> targets,
}) {
  if (problem.existingBlocks.isEmpty) return const [];
  final lockedIds = {for (final block in problem.lockedBlocks) block.id};
  final adopted = <PlannedBlock>[];
  final minutesByTask = <String, int>{};
  for (final block in problem.existingBlocks) {
    if (lockedIds.contains(block.id)) continue;
    final target = targets[block.taskId];
    // 任务不在本次输入里（已完成、被跳过）⇒ 不占位。
    if (target == null) continue;
    // 必须完整落在某个可用时段内。可用时段已排除固定日程、保护时间、睡眠
    // 与课程过渡，因此这一条同时覆盖那三类硬占用。
    final stillFits = slots.any(
      (slot) =>
          slot.range.startUtc.compareTo(block.startUtc) <= 0 &&
          slot.range.endUtc.compareTo(block.endUtc) >= 0,
    );
    if (!stillFits) continue;
    final already = minutesByTask[block.taskId] ?? 0;
    if (already + block.durationMinutes > target) continue;
    minutesByTask[block.taskId] = already + block.durationMinutes;
    adopted.add(block);
  }
  adopted.sort((a, b) {
    final byStart = a.startUtc.compareTo(b.startUtc);
    return byStart != 0 ? byStart : a.id.compareTo(b.id);
  });
  return adopted;
}

PlannedBlock _temporaryBlock(String taskId, SchedulingCandidate candidate) =>
    PlannedBlock(id: 'temporary', taskId: taskId, range: candidate.range);

/// 任意两个任务块之间必须保留 `Rules.breakMinutes` 的休息
/// （需求 FR-SCHED-05 与默认值 8.4.1）。
///
/// 该规则原先是"同一任务的两段专注之间"，先推广到"任意两个非生活任务块之间"，
/// 随后按产品决策取消任务类型区分：**所有任务块一律适用**，不再有生活任务豁免。
/// 连续任务同样适用（它与另一任务是两个独立块）。已锁定块不移动，因此若用户
/// 锁定的块之间本身不足间隔，引擎不会也无法修正，只在生成新块时避免新的违规。
bool _violatesRestGap(
  ScheduleProblem problem,
  SchedulableTask task,
  SchedulingCandidate candidate,
  List<PlannedBlock> blocks,
) {
  final breakMinutes = problem.rules.breakMinutes;
  if (breakMinutes <= 0) return false;
  for (final block in blocks) {
    if (_gapMinutes(block.range, candidate.range) < breakMinutes) return true;
  }
  return false;
}

/// 该候选结束后，同一任务最早可以开始下一片段的时间；null 表示不适用。
DateTime? _restReadyAt(
  ScheduleProblem problem,
  SchedulableTask task,
  SchedulingCandidate candidate,
) {
  final breakMinutes = problem.rules.breakMinutes;
  if (breakMinutes <= 0 || task.splitMode == TaskSplitMode.continuous) {
    return null;
  }
  // 一律留出休息：返回 null 会让续排容量把候选之前的空闲段也算进来，从而高估该候选。
  return candidate.endUtc.add(Duration(minutes: breakMinutes));
}

/// 两个区间的间隔分钟数；重叠或首尾相接时为 0。
int _gapMinutes(TimeRange a, TimeRange b) {
  if (a.overlaps(b)) return 0;
  if (!a.endUtc.isAfter(b.startUtc)) {
    return b.startUtc.difference(a.endUtc).inMinutes;
  }
  return a.startUtc.difference(b.endUtc).inMinutes;
}
