import 'dart:math' as math;

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/candidate_scorer.dart';
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
  static const String algorithmVersion = '9';
  static const int localImprovementOperationBudget = 200;

  final TimeZoneDatabase _zones;
  final AvailabilityBuilder _availabilityBuilder;
  final PlanValidator _validator;
  final CandidateGenerator _candidateGenerator = const CandidateGenerator();
  final CandidateScorer _candidateScorer = const CandidateScorer();
  final PressureCalculator _pressureCalculator = const PressureCalculator();

  @override
  ScheduleProposal generate(ScheduleProblem problem) {
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

    for (final task in tasks) {
      var remaining = math.max(
        0,
        targets[task.id]! - (scheduledByTask[task.id] ?? 0),
      );
      final candidates = _candidateGenerator
          .generate(task, slots)
          .where(
            (candidate) =>
                task.dueAtUtc == null ||
                !candidate.endUtc.isAfter(task.dueAtUtc!),
          )
          .toList();

      while (remaining > 0) {
        final ranked = <_RankedCandidate>[];
        for (final candidate in candidates) {
          if (candidate.durationMinutes > remaining ||
              _overlapsAny(candidate.range, blocks) ||
              _violatesRestGap(problem, task, candidate, blocks)) {
            continue;
          }
          final leftover = remaining - candidate.durationMinutes;
          if (task.splitMode == TaskSplitMode.splittable &&
              leftover > 0 &&
              leftover < task.minChunkMinutes) {
            continue;
          }
          final score = _scoreCandidate(
            problem,
            task,
            candidate,
            blocks,
            targets[task.id]!,
          );
          if (score.isEligible) {
            ranked.add(
              _RankedCandidate(
                candidate,
                score.totalScore!,
                candidate.durationMinutes +
                    math.min(
                      leftover,
                      _continuationCapacity(
                        task,
                        slots,
                        [...blocks, _temporaryBlock(task.id, candidate)],
                        notBefore: _restReadyAt(problem, task, candidate),
                      ),
                    ),
              ),
            );
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
        remaining -= selected.durationMinutes;
        scheduledByTask.update(
          task.id,
          (value) => value + selected.durationMinutes,
          ifAbsent: () => selected.durationMinutes,
        );
      }
    }

    _improve(problem, slots, blocks, targets);
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
        unscheduled.add(
          UnscheduledTask(taskId: task.id, shortageMinutes: shortage),
        );
      }
    }

    final conflicts = [..._validator.validate(problem, blocks)];
    for (final item in unscheduled) {
      conflicts.add(
        PlanningConflict(
          code: ConflictCode.insufficientCapacity,
          taskId: item.taskId,
          shortageMinutes: item.shortageMinutes,
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
        sameTaskAdjacent: _sameTaskOnSameDay(
          problem,
          task,
          candidate,
          blocks,
        ),
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
      ).totalScore!;
      final alternatives = _candidateGenerator
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
        final score = _scoreCandidate(
          problem,
          task,
          candidate,
          others,
          targets[task.id]!,
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
