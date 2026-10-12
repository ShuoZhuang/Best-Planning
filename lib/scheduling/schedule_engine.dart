import 'dart:math' as math;

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/candidate_scorer.dart';
import 'package:personal_planner/scheduling/even_distribution_allocator.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/preferred_time_scorer.dart';
import 'package:personal_planner/scheduling/pressure_calculator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

abstract interface class ScheduleEngine {
  ScheduleProposal generate(ScheduleProblem problem);
}

final class DeterministicScheduleEngine implements ScheduleEngine {
  DeterministicScheduleEngine(this._zones)
    : _availabilityBuilder = AvailabilityBuilder(_zones),
      _validator = PlanValidator(_zones);

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
  static const String algorithmVersion = '14';
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
    final slots = _availabilityBuilder.build(
      AvailabilityInput(
        planningWindow: problem.planningWindow,
        timeZoneId: problem.timeZoneId,
        rules: problem.rules,
        fixedIntervals: problem.fixedIntervals
            .map((item) => item.range)
            .toList(),
        protectedIntervals: problem.protectedIntervals
            .map((item) => item.range)
            .toList(),
        lockedBlocks: problem.lockedBlocks.map((item) => item.range).toList(),
        // "拖动了但没锁定"的块占住时间、且计入当日可移动预算（见该字段的说明）。
        chargedMovableBlocks: [
          for (final block in problem.lockedBlocks)
            if (problem.pinnedUnlockedBlockIds.contains(block.id)) block.range,
        ],
      ),
    );
    final targets = {
      for (final task in problem.tasks) task.id: _targetFor(problem, task),
    };
    final tasks = [...problem.tasks]
      ..sort((a, b) => _compareTasks(a, b, slots, targets));
    final blocks = [...problem.lockedBlocks]..sort(_compareBlocks);
    final explanations = <PlanExplanation>[];
    final scheduledByTask = <String, int>{};
    for (final block in problem.lockedBlocks) {
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

    // ── 拒绝证据的收集（路线图 Task 12A Step 6 第 3 条）──────────────────────
    //
    // 每个任务一份，按 `UnscheduledReasonCode` 去重。**刻意不记"最后一次"**：那取决于候选遍历
    // 顺序，换个排序就换个说法；用户看到的失败原因会因此随无关改动漂移。
    // 排程结束后由 `primaryUnscheduledReason` 按固定优先级从**全部**证据里选主原因。
    final rejectionEvidence =
        <String, Map<UnscheduledReasonCode, UnscheduledReason>>{};
    void recordRejection(String taskId, UnscheduledReason reason) {
      (rejectionEvidence[taskId] ??= {})[reason.code] = reason;
    }

    // 每日可移动上限的判定表。**增量维护**：`blocks` 每变一次就在这里加一笔，
    // 于是判定从"每个候选扫一遍所有块"退化为一次 Map 查表。
    // 见 `_exceedsMovableDailyLimit` 的说明（取消候选截断后这一项曾是主要开销）。
    final movableMinutesByDate = _movableMinutesByDate(problem, blocks);
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
    final evenPlans = <String, EvenDistributionPlan>{
      for (final task in problem.tasks)
        if (task.distributionPolicy == TaskDistributionPolicy.even)
          task.id: allocateEvenDistribution(
            EvenDistributionInput(
              targetMinutes: math.max(
                0,
                targets[task.id]! - (scheduledByTask[task.id] ?? 0),
              ),
              granularityMinutes: problem.rules.granularityMinutes,
              minChunkMinutes: task.minChunkMinutes,
              capacityMinutesByLocalDate: _capacityByLocalDate(
                task,
                slots,
                problem.rules.granularityMinutes,
              ),

              alreadyPlannedMinutesByLocalDate: _plannedMinutesByLocalDate(
                problem,
                task,
                problem.lockedBlocks,
              ),
            ),
          ),
    };

    for (final task in tasks) {
      var remaining = math.max(
        0,
        targets[task.id]! - (scheduledByTask[task.id] ?? 0),
      );
      final evenPlanForTask = evenPlans[task.id];
      final generated = chunkGenerator.generate(task, slots);
      // ── 按日预算剪枝（计划 Issue 4a 允许的"等价剪枝"）─────────────────────────
      //
      // 取消每日上限对候选时间轴的截断后（Task 2），候选数明显变多：实测规模用例
      // 1632 ms → 3255 ms（恰好两倍，计划 Step 4a 的阈值就是两倍）。
      //
      // 对被分配器定过预算的任务，**只保留"所属本地日仍有新增预算"的候选**。
      // 这是**等价剪枝，不可能改变最优日分配**：均分器已经把每日分钟定死，而下面的放置循环
      // 只消费仍有余量的日期（`_evenBudgetRemaining`）。某日本次预算为 0，则它的候选
      // 无论保留与否都**永远不会被选中**；剪掉它们只省掉"必被跳过"的评分与拒绝记录开销。
      //
      // 注意保留条件用 `additionalMinutesByLocalDate` 是否**存在**该日，而不是它当前的剩余量：
      // 剩余量会随放置递减，用剩余量做过滤会让同一份候选集在循环中变化，破坏确定性。
      final allCandidates = evenPlanForTask == null
          ? generated
          : [
              for (final candidate in generated)
                if (evenPlanForTask.additionalMinutesByLocalDate.containsKey(
                  candidate.localDate,
                ))
                  candidate,
            ];
      // ── 先分辨"根本没得排"的三种情况，再进入放置循环 ────────────────────────
      //
      // 这三条必须在候选为空时给出**不同**的说法，否则用户看到的永远是笼统的"可用时间不足"，
      // 而三种情况的处置完全不同：等一等（还没到开始时间）、改截止时间、腾出/放宽时段。
      if (allCandidates.isEmpty) {
        final availableFrom = task.availableFromUtc;
        if (availableFrom != null &&
            !availableFrom.isBefore(problem.planningWindow.endUtc)) {
          recordRejection(
            task.id,
            UnscheduledReason(
              code: UnscheduledReasonCode.availableTimeNotReached,
              requiredMinutes: remaining,
              constraintLabel: '最早开始时间',
            ),
          );
        } else if (task.splitMode == TaskSplitMode.continuous) {
          // 连续任务要求一次做完 `requiredMinutes`。可用时段被切碎到每一段都短于它时，
          // 真实原因是"找不到足够长的连续空档"，而不是"总容量不足"——前者改拆分方式或
          // 截止时间就能解决，后者要靠腾时间。
          final longest = _longestSlotMinutes(slots);
          recordRejection(
            task.id,
            UnscheduledReason(
              code: UnscheduledReasonCode.continuousGapTooShort,
              requiredMinutes: remaining,
              availableMinutes: longest,
              constraintLabel: '连续时长',
            ),
          );
        } else {
          recordRejection(
            task.id,
            UnscheduledReason(
              code: UnscheduledReasonCode.insufficientCapacity,
              requiredMinutes: remaining,
            ),
          );
        }
      }
      // 截止前的窗口装不下任何一段 ⇒ 这是一个**独立**的原因，不是笼统的容量不足：
      // 处置是"把截止时间往后挪或缩短任务"，而容量不足的处置是"腾出时间"。
      if (allCandidates.isNotEmpty) {
        final withinDeadline = allCandidates
            .where(
              (candidate) =>
                  task.dueAtUtc == null ||
                  !candidate.endUtc.isAfter(task.dueAtUtc!),
            )
            .toList();
        if (withinDeadline.isEmpty) {
          final longest = allCandidates
              .map((candidate) => candidate.durationMinutes)
              .reduce(math.max);
          recordRejection(
            task.id,
            UnscheduledReason(
              code: UnscheduledReasonCode.deadlineWindowTooShort,
              requiredMinutes: task.minChunkMinutes,
              availableMinutes: longest,
              constraintLabel: '截止时间',
            ),
          );
        }
      }
      final candidates = allCandidates
          .where(
            (candidate) =>
                task.dueAtUtc == null ||
                !candidate.endUtc.isAfter(task.dueAtUtc!),
          )
          .toList();
      // 有候选、但全部被截止时间挡掉（上面已记过 `deadlineWindowTooShort`）时不再补兜底
      // 证据：两条都记会让"截止窗口不足"这个更具体的原因被笼统原因淹没。
      if (candidates.isEmpty && rejectionEvidence[task.id] == null) {
        recordRejection(
          task.id,
          UnscheduledReason(
            code: UnscheduledReasonCode.insufficientCapacity,
            requiredMinutes: remaining,
          ),
        );
      }

      while (remaining > 0) {
        // ── 均匀分布任务：按日预算放置（1.7.1 计划 Task 4 Step 3）──────────────
        //
        // `distributionPolicy == even` 的任务**不使用**下面那套"两轮放开配额"。原因：
        // 两轮策略的第二轮是**全局解禁**，它能把一天堆到 125 分钟——那正是用户实测的缺陷
        // （计划 §2.1）。均匀分布的正确处置是"某日放不下就把它放不下的部分重新分给还有余量的
        // 日期"，这件事已经由均分器按容量做完（计划 §3.1 第 4 条），因此这里只消费预算。
        var ranked = <_RankedCandidate>[];
        final evenPlan = evenPlans[task.id];
        var relaxedDailyQuota = evenPlan != null;
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
        // 这与既有的"两轮放开每日配额"是同一个手法，只是放宽的是另一条软性偏好。
        var allowUnschedulableLeftover = false;
        for (
          var pass = 0;
          pass < (evenPlan == null ? 2 : 1) && ranked.isEmpty;
          pass++
        ) {
          relaxedDailyQuota = evenPlan != null || pass == 1;
          allowUnschedulableLeftover = evenPlan != null || pass == 1;
          for (final candidate in candidates) {
            // **每一条拒绝都留证据**，而不是只记最后一条。同一个候选可能同时违反多条约束
            // （例如既超过今日配额、又和固定日程重叠），只记一条会让原因随遍历顺序变化。
            // 这里逐条判定并各自记录，主原因最后由固定优先级决定。
            if (candidate.durationMinutes > remaining) {
              recordRejection(
                task.id,
                UnscheduledReason(
                  code: UnscheduledReasonCode.minimumChunkTooLarge,
                  requiredMinutes: candidate.durationMinutes,
                  availableMinutes: remaining,
                ),
              );
              continue;
            }
            if (_overlapsAny(candidate.range, blocks)) {
              recordRejection(
                task.id,
                const UnscheduledReason(
                  code: UnscheduledReasonCode.lockedPlanOccupied,
                  constraintLabel: '已有计划块或固定日程',
                ),
              );
              continue;
            }
            if (evenPlan != null) {
              // 均匀分布任务只消费按日预算。预算不足即跳过——**不放宽**，
              // 因为"放不下的部分已由均分器重新分给其他日期"。
              final budget = _evenBudgetRemaining(
                problem,
                task,
                candidate,
                evenPlan,
                blocks,
              );
              if (candidate.durationMinutes > budget) {
                recordRejection(
                  task.id,
                  UnscheduledReason(
                    code: UnscheduledReasonCode.dailyLimitReached,
                    requiredMinutes: candidate.durationMinutes,
                    availableMinutes: budget,
                    constraintLabel: '本日均匀份额',
                  ),
                );
                continue;
              }
            }
            if (_exceedsDailyQuota(
              problem,
              task,
              candidate,
              blocks,
              relaxed: relaxedDailyQuota,
            )) {
              recordRejection(
                task.id,
                UnscheduledReason(
                  code: UnscheduledReasonCode.dailyLimitReached,
                  requiredMinutes: candidate.durationMinutes,
                  availableMinutes: task.maxMinutesPerLocalDay,
                ),
              );
              continue;
            }
            if (_exceedsMovableDailyLimit(
              problem,
              candidate,
              movableMinutesByDate,
            )) {
              recordRejection(
                task.id,
                UnscheduledReason(
                  code: UnscheduledReasonCode.dailyLimitReached,
                  requiredMinutes: candidate.durationMinutes,
                  availableMinutes: problem.rules.dailyMovableTaskLimitMinutes,
                ),
              );
              continue;
            }
            if (_violatesRestGap(problem, task, candidate, blocks)) {
              recordRejection(
                task.id,
                const UnscheduledReason(
                  code: UnscheduledReasonCode.requiredBreakUnavailable,
                  constraintLabel: '片段间休息',
                ),
              );
              continue;
            }
            final leftover = remaining - candidate.durationMinutes;
            // **最终余量的判据必须与短余量宽免同口径**（1.8.0，冻结决策 §1.4）。
            //
            // 判据问的是"**剩下的这段还能不能构成一个合法片段**"：
            // 宽免额度（粒度下的剩余量）为 0 才说明真的凑不出片段 ——
            // 例如剩 2 分钟、粒度 5 分钟。见上面 [allowUnschedulableLeftover] 的说明：
            // 这一条只排除该候选，且第二遍会放宽，因此"能排的 10 分钟"不会被丢掉。
            final leftoverAllowance = shortRemainderAllowance(
              requiredMinutes: leftover,
              granularityMinutes: problem.rules.granularityMinutes,
            );
            if (task.splitMode == TaskSplitMode.splittable &&
                leftover > 0 &&
                leftoverAllowance <= 0) {
              recordRejection(
                task.id,
                UnscheduledReason(
                  code: UnscheduledReasonCode.minimumChunkTooLarge,
                  requiredMinutes: leftover,
                  availableMinutes: task.minChunkMinutes,
                  constraintLabel: '最终余量不足一个片段',
                ),
              );
              if (!allowUnschedulableLeftover) continue;
            }
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
                        leftover,
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
        remaining -= selected.durationMinutes;
        scheduledByTask.update(
          task.id,
          (value) => value + selected.durationMinutes,
          ifAbsent: () => selected.durationMinutes,
        );
      }
    }

    _improve(problem, slots, blocks, targets, chunkGenerator);
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

    final unscheduled = <UnscheduledTask>[];
    for (final task in [
      ...problem.tasks,
    ]..sort((a, b) => a.id.compareTo(b.id))) {
      final scheduled = blocks
          .where((block) => block.taskId == task.id)
          .fold<int>(0, (sum, block) => sum + block.durationMinutes);
      final shortage = math.max(0, targets[task.id]! - scheduled);
      if (shortage > 0) {
        final evidence = [...?rejectionEvidence[task.id]?.values];
        unscheduled.add(
          UnscheduledTask(
            taskId: task.id,
            shortageMinutes: shortage,
            primaryReason: primaryUnscheduledReason(evidence),
            reasons: evidence,
          ),
        );
      }
    }

    // ── 最小化改动（1.8.0，规范 §11.4 第 3、4 条）──────────────────────────────
    //
    // 生成是"从零排一遍"，引擎因此不知道哪些块**本来就在合适的位置**。用户按一次
    // "延后 30 分钟"，引擎可能顺手把一整天重排一遍——而规范要的是"少动"：
    // 先比被移动的块数，再比总位移分钟。
    //
    // 这一步把**还能回到原位**的块放回原位，每一步都过验证器，因此它只可能减少改动、
    // 不可能制造新冲突。放在这里（冲突检查之前）是刻意的：如果它真的引入了冲突，
    // 下面的 `validate` 会如实报出来，而不是被静默吞掉。
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

    // **容量缺口只有一个结构化来源**（1.8.0，冻结决策 §1.5）：`unscheduled`。
    //
    // 修复前这里还会为每个 `UnscheduledTask` 再补一条
    // `ConflictCode.insufficientCapacity`，而预览又把它翻成一句独立的文案 ——
    // 于是同一件事在页面上说两到三遍（截图里的"可用时间不足"＋"「蓝桥杯竞赛课」还缺 76 分钟"，
    // 见 R6）。`insufficientCapacity` 这个枚举值保留，但它现在只由
    // `PlanApplicationService` 在 `completeOnly` 模式下**作为返回结果**构造
    // （用于告诉调用者"需要明确允许部分计划"），不再由引擎写进 `proposal.conflicts`。
    final conflicts = [..._validator.validate(problem, blocks)];
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
      capacityForRange: (start, end) => _availabilityBuilder
          .build(
            AvailabilityInput(
              planningWindow: TimeRange(startUtc: start, endUtc: end),
              timeZoneId: problem.timeZoneId,
              rules: problem.rules,
              fixedIntervals: problem.fixedIntervals
                  .map((item) => item.range)
                  .toList(),
              protectedIntervals: problem.protectedIntervals
                  .map((item) => item.range)
                  .toList(),
              lockedBlocks: problem.lockedBlocks
                  .map((item) => item.range)
                  .toList(),
            ),
          )
          .fold<int>(0, (sum, slot) => sum + slot.durationMinutes),
    );
    return _ensurePlaceable(
      _pressureCalculator.calculate(task, capacity).targetMinutes,
      problem,
      task,
    );
  }

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

  /// 把 [candidate] 放进它所属的那个**本地日**之后，该日会不会超过任务自己声明的单日上限
  /// （路线图 §3.4 "均匀分布"、Task 8 Step 5）。
  ///
  /// 判据是"**这一天总共**排了多少"，而不是"这一段多长"：`maxMinutesPerLocalDay` 是从周期目标
  /// 摊出来的每日配额（例如 180÷7 ≈ 26 分钟），它约束的是一天的总量。因此必须把该日已经排进去
  /// 的分钟（含锁定块与本次循环先前选中的块）一起算上——否则引擎仍然会把整周的量堆进同一天，
  /// 而"均匀分布"就只是一个界面上存在、结果上无效的选项。
  ///
  /// **[relaxed] 的含义见 [generate] 里的两轮说明**：配额是"摊开"的偏好，不是容量的真相。
  bool _exceedsDailyQuota(
    ScheduleProblem problem,
    SchedulableTask task,
    SchedulingCandidate candidate,
    List<PlannedBlock> blocks, {
    required bool relaxed,
  }) {
    if (relaxed) return false;
    final quota = task.maxMinutesPerLocalDay;
    if (quota == null) return false;
    final zoneId = problem.timeZoneId;
    final localDate = candidate.localDate;
    var planned = 0;
    for (final block in blocks) {
      if (block.taskId != task.id) continue;
      final local = _zones.toLocal(block.startUtc, zoneId);
      if (local.year == localDate.year &&
          local.month == localDate.month &&
          local.day == localDate.day) {
        planned += block.durationMinutes;
      }
    }
    return planned + candidate.durationMinutes > quota;
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
  Map<DateTime, int> _movableMinutesByDate(
    ScheduleProblem problem,
    List<PlannedBlock> blocks,
  ) {
    final result = <DateTime, int>{};
    for (final block in blocks) {
      final movable =
          !block.locked || problem.pinnedUnlockedBlockIds.contains(block.id);
      if (!movable) continue;
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
  Map<DateTime, int> _capacityByLocalDate(
    SchedulableTask task,
    List<AvailabilitySlot> slots,
    int granularity,
  ) {
    final eligibleDates = _eligibleLocalDates(task, slots);
    final rangesByDate = <DateTime, List<TimeRange>>{};
    for (final slot in slots) {
      if (!eligibleDates.contains(slot.localDate)) continue;
      if (!task.allowsWeekday(slot.localDate.weekday)) continue;
      (rangesByDate[slot.localDate] ??= []).add(slot.range);
    }
    final result = <DateTime, int>{};
    for (final entry in rangesByDate.entries) {
      final sorted = [...entry.value]
        ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
      var total = 0;
      DateTime? cursor;
      DateTime? end;
      for (final range in sorted) {
        if (cursor == null) {
          cursor = range.startUtc;
          end = range.endUtc;
          continue;
        }
        if (!range.startUtc.isAfter(end!)) {
          if (range.endUtc.isAfter(end)) end = range.endUtc;
          continue;
        }
        total += end.difference(cursor).inMinutes;
        cursor = range.startUtc;
        end = range.endUtc;
      }
      if (cursor != null) total += end!.difference(cursor).inMinutes;
      // 向下取整到粒度：不足一个粒度的碎片放不下任何片段。
      result[entry.key] = (total ~/ granularity) * granularity;
    }
    return result;
  }

  /// 可用时段真正覆盖到的本地日集合。
  ///
  /// **不能用"窗口起止各取本地日再逐日推进"**：窗口起点是 `planningStartUtc`，它在本地日
  /// 内部（例如周四 20:00），若把它的 `localDate` 当成第一天，窗口边界之外的半天会被算进来。
  /// 因此这里反过来——以 `AvailabilityBuilder` 实际产出的 `slot.localDate` 为准，
  /// 它已经按本地日切好片。
  Set<DateTime> _eligibleLocalDates(
    SchedulableTask task,
    List<AvailabilitySlot> slots,
  ) => {for (final slot in slots) slot.localDate};

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
  int _evenBudgetRemaining(
    ScheduleProblem problem,
    SchedulableTask task,
    SchedulingCandidate candidate,
    EvenDistributionPlan plan,
    List<PlannedBlock> blocks,
  ) {
    final date = candidate.localDate;
    final budget = plan.additionalMinutesByLocalDate[date] ?? 0;
    if (budget <= 0) return 0;
    var consumed = 0;
    for (final block in blocks) {
      if (block.taskId != task.id) continue;
      final blockDate = _localDate(block.startUtc, problem.timeZoneId);
      if (blockDate == date) consumed += block.durationMinutes;
    }
    return budget - consumed;
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
      final alternatives = candidates
          .generate(task, slots)
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
        if (_validator.validate(problem, trial).isEmpty) {
          blocks[blockIndex] = replacement;
          break;
        }
      }
    }
  }

  DateTime _localDate(DateTime instantUtc, String zoneId) {
    final local = _zones.toLocal(instantUtc, zoneId);
    return DateTime(local.year, local.month, local.day);
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

/// 可用时段里**最长的一段**有多少分钟。
///
/// 只用于把"连续任务排不下"这件事说清楚：一个要求一次做完 60 分钟的任务，在最长空档只有
/// 30 分钟的周里，真实原因是"没有足够长的连续空档"，而不是"总容量不足"——两者对用户意味着
/// 完全不同的下一步（改拆分方式／改截止时间 vs 腾出时间）。
int _longestSlotMinutes(List<AvailabilitySlot> slots) {
  if (slots.isEmpty) return 0;
  var longest = 0;
  for (final slot in slots) {
    final minutes = slot.range.durationMinutes;
    if (minutes > longest) longest = minutes;
  }
  return longest;
}

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
