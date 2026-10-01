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
