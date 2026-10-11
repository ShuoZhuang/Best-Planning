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
    required this.maximumUnusableGapPenalty,
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
        maximumUnusableGapPenalty: -500,
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

  /// 制造**无法利用的短空档**的惩罚上限（1.8.0，规范 §11.4 第 6 条）。
  ///
  /// 量级取在 `moveExistingBlockPenalty`（-700）与 `categorySwitchPenalty`（-300）之间：
  /// 规范把"不制造坏空档"排在第 6 位——在"少动块／少位移"（第 3、4 条，由
  /// `LocalRepairPlan.compare` 比较）之后，但在截止风险、优先级、精力与期望时段（第 7 条）
  /// 之前。取 -500 足以压过第 7 条那一组，又不至于盖过移动既有块的代价。
  final int maximumUnusableGapPenalty;
}
