import 'dart:collection';
import 'dart:math' as math;

import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/scheduling_weights.dart';

enum ScoringFactor {
  deadlineRisk,
  priority,
  progressPressure,
  energyMatch,
  preferredTime,
  lifeQuota,
  sameTaskContinuity,
  categorySwitch,
  fragmentation,
  movingExistingBlock,

  /// **无法利用的短空档**（1.8.0，规范 §11.4 第 6 条／§2.6）。
  ///
  /// 与 [fragmentation] 是**两件不同的事**：那个惩罚的是"这一块比最大片段短多少"，
  /// 也就是**块的形状**；这一个惩罚的是"这次放置会在周围留下多长的、谁也放不进去的缝"。
  /// 一个 45 分钟的块完全正常，而它前后各留 20 分钟的缝才是问题。
  unusableGap,
}

final class CandidateScoringContext {
  const CandidateScoringContext({
    required this.task,
    this.slotEnergyLevel,
    this.deadlineRiskPermille = 0,
    this.progressPressurePermille = 0,
    this.preferredTimeScore = 0,
    this.lifeQuotaTargetMinutes = 0,
    this.plannedLifeMinutes = 0,
    this.sameTaskAdjacent = false,
    this.categorySwitch = false,
    this.fragmentationPenaltyPermille = 0,
    this.unusableGapPenaltyPermille = 0,
    this.movesExistingBlock = false,
    this.hardConstraintsSatisfied = true,
  });

  final SchedulableTask task;
  final EnergyLevel? slotEnergyLevel;
  final int deadlineRiskPermille;
  final int progressPressurePermille;
  final int preferredTimeScore;
  final int lifeQuotaTargetMinutes;
  final int plannedLifeMinutes;
  final bool sameTaskAdjacent;
  final bool categorySwitch;
  final int fragmentationPenaltyPermille;

  /// 这次放置会留下的无法利用的短空档，按"最深的那一段"折算成千分比（0..1000）。
  ///
  /// **用最深的一段而不是总分钟**：一次放置通常只影响紧邻的两段缝，"总分钟"会把
  /// 一天里早已存在的坏空档也算进来，于是评分反映的是"当前计划有多碎"，
  /// 而不是"这一个候选有多碎"——前者是常量，无法用来比较候选。
  final int unusableGapPenaltyPermille;
  final bool movesExistingBlock;
  final bool hardConstraintsSatisfied;
}

final class CandidateScore {
  CandidateScore.eligible(Map<ScoringFactor, int> factors)
    : isEligible = true,
      factors = UnmodifiableMapView(Map.of(factors)),
      totalScore = factors.values.fold<int>(0, (total, value) => total + value);

  CandidateScore.rejected()
    : isEligible = false,
      factors = UnmodifiableMapView(const {}),
      totalScore = null;

  final bool isEligible;
  final int? totalScore;
  final Map<ScoringFactor, int> factors;
}

final class CandidateScorer {
  const CandidateScorer({this.weights = const SchedulingWeights.v1()});

  final SchedulingWeights weights;

  CandidateScore score(
    SchedulingCandidate candidate,
    CandidateScoringContext context,
  ) {
    if (!context.hardConstraintsSatisfied ||
        candidate.taskId != context.task.id) {
      return CandidateScore.rejected();
    }

    final factors = <ScoringFactor, int>{
      ScoringFactor.deadlineRisk: _scaled(
        weights.maximumDeadlineRisk,
        context.deadlineRiskPermille,
      ),
      ScoringFactor.priority: _priority(context.task.priority),
      ScoringFactor.progressPressure: _scaled(
        weights.maximumProgressPressure,
        context.progressPressurePermille,
      ),
      ScoringFactor.energyMatch: _energyMatch(
        context.task.energyLevel,
        context.slotEnergyLevel,
      ),
      ScoringFactor.preferredTime: context.preferredTimeScore.clamp(
        weights.minimumPreferredTime,
        weights.maximumPreferredTime,
      ),
      ScoringFactor.lifeQuota: _lifeQuota(context),
      ScoringFactor.sameTaskContinuity: context.sameTaskAdjacent
          ? weights.sameTaskContinuity
          : 0,
      ScoringFactor.categorySwitch: context.categorySwitch
          ? weights.categorySwitchPenalty
          : 0,
      ScoringFactor.fragmentation: -_scaled(
        -weights.maximumFragmentationPenalty,
        context.fragmentationPenaltyPermille,
      ),
      ScoringFactor.movingExistingBlock: context.movesExistingBlock
          ? weights.moveExistingBlockPenalty
          : 0,
      // 1.8.0（规范 §11.4 第 6 条）：留下无法利用的短空档要扣分。
      // 用与 `fragmentation` 同一条"上限 × 千分比"的折算方式，因此两个因子可以直接比较。
      ScoringFactor.unusableGap: -_scaled(
        -weights.maximumUnusableGapPenalty,
        context.unusableGapPenaltyPermille,
      ),
    };
    return CandidateScore.eligible(factors);
  }

  int _priority(TaskPriority priority) => switch (priority) {
    TaskPriority.low => weights.priorityLow,
    TaskPriority.medium => weights.priorityMedium,
    TaskPriority.high => weights.priorityHigh,
    TaskPriority.urgent => weights.priorityUrgent,
  };

  int _energyMatch(TaskEnergyLevel task, EnergyLevel? slot) {
    if (slot == null) return 0;
    return switch ((task, slot)) {
      (TaskEnergyLevel.high, EnergyLevel.high) => weights.maximumEnergyMatch,
      (TaskEnergyLevel.high, EnergyLevel.medium) => 100,
      (TaskEnergyLevel.high, EnergyLevel.low) => weights.minimumEnergyMatch,
      (TaskEnergyLevel.medium, EnergyLevel.high) => 200,
      (TaskEnergyLevel.medium, EnergyLevel.medium) => 600,
      (TaskEnergyLevel.medium, EnergyLevel.low) => -300,
      (TaskEnergyLevel.low, EnergyLevel.high) => -200,
      (TaskEnergyLevel.low, EnergyLevel.medium) => 300,
      (TaskEnergyLevel.low, EnergyLevel.low) => 700,
    };
  }

  int _lifeQuota(CandidateScoringContext context) {
    if (!context.task.isLifeTask || context.lifeQuotaTargetMinutes <= 0) {
      return 0;
    }
    final deficit = math.max(
      0,
      context.lifeQuotaTargetMinutes - context.plannedLifeMinutes,
    );
    return (weights.maximumLifeQuota * deficit) ~/
        context.lifeQuotaTargetMinutes;
  }
}

int _scaled(int maximum, int permille) =>
    maximum * permille.clamp(0, 1000) ~/ 1000;
