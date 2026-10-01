final class SchedulingWeights {
  const SchedulingWeights._({
    required this.maximumDeadlineRisk,
    required this.priorityLow,
    required this.priorityMedium,
    required this.priorityHigh,
    required this.priorityUrgent,
    required this.maximumProgressPressure,
    required this.maximumEnergyMatch,
    required this.minimumEnergyMatch,
    required this.maximumPreferredTime,
    required this.minimumPreferredTime,
    required this.maximumLifeQuota,
    required this.sameTaskContinuity,
    required this.categorySwitchPenalty,
    required this.maximumFragmentationPenalty,
    required this.moveExistingBlockPenalty,
  });

  const SchedulingWeights.v1()
    : this._(
        maximumDeadlineRisk: 3000,
        priorityLow: 0,
        priorityMedium: 500,
        priorityHigh: 1000,
        priorityUrgent: 1500,
        maximumProgressPressure: 500,
        maximumEnergyMatch: 800,
        minimumEnergyMatch: -800,
        maximumPreferredTime: 500,
        minimumPreferredTime: -300,
        maximumLifeQuota: 1000,
        sameTaskContinuity: 400,
        categorySwitchPenalty: -300,
        maximumFragmentationPenalty: -600,
        moveExistingBlockPenalty: -700,
      );

  final int maximumDeadlineRisk;
  final int priorityLow;
  final int priorityMedium;
  final int priorityHigh;
  final int priorityUrgent;
  final int maximumProgressPressure;
  final int maximumEnergyMatch;
  final int minimumEnergyMatch;
  final int maximumPreferredTime;
  final int minimumPreferredTime;
  final int maximumLifeQuota;
  final int sameTaskContinuity;
  final int categorySwitchPenalty;
  final int maximumFragmentationPenalty;
  final int moveExistingBlockPenalty;
}
