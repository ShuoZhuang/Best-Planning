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
        maximumUnusableGapPenalty: 0,
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
  /// **现在是 0：这一项暂时不参与评分。** 这不是"还没接上"，而是一次**实测后的撤回**，
  /// 原委必须留在这里，否则下一个人会以为漏了接线又把它打开：
  ///
  /// 接上 `candidate_scorer` 的 `ScoringFactor.unusableGap`、并让引擎按候选两侧的浪费分钟数
  /// 填入千分比之后，`schedule_engine_test.dart` 的两条既有用例变红——
  /// `golden week keeps breaks between chunks and reports the shortfall`（缺口 30 → 90）
  /// 与 `任意两个任务块之间保留休息，不区分任务类型`（间隔 10 → 60）。
  ///
  /// **阈值是"任何负数"，不是某个数值**（2026-10-11 逐值实测）：
  ///
  /// | 权重 | `schedule_engine_test.dart` |
  /// | --- | --- |
  /// | `0` | **全绿**（9 通过） |
  /// | `-50` / `-100` / `-150` / `-500` | 2 红 |
  ///
  /// 也就是说**没有"小一点就安全"的空间**：这一项一旦参与候选评分，无论多小都会
  /// 把休息吃掉。因此"把权重调小"不再是候选方案。
  ///
  /// 根因是**候选评分没有时域视野**：这一项只看候选**紧邻**的两段缝，于是引擎会把块往后推
  /// 以"离开"一段短缝，却在更远处制造出更大的缺口——单看一处它是改善了，整体上休息反而
  /// 被吃掉。规范 §11.4 要求"不制造坏空档"是**在一个局部修复方案上**比较的
  /// （第 6 条排在被移动块数与总位移之后），而方案级比较正是 `LocalRepairPlan.compare`
  /// 那一步。
  ///
  /// **而它没有消费方**（2026-10-11 核对）：`localRepairCascade` 与
  /// `LocalRepairPlan.compare` 只在 `local_repair.dart` 自己与它的测试里被引用，
  /// 生产路径一次都没调用。因此第 6 条**无法通过方案级比较落地**，而候选级已实测不可行。
  ///
  /// **这不是"还没接线"，是一处需要设计决策的结构缺口**：要么给局部修复接上真正的方案级
  /// 选择，要么承认第 6 条在本架构下不强制执行。在决策之前，这个 0 是**诚实的状态**，
  /// 不是遗漏。
  ///
  /// 因此这次交付的边界是：**判据与因子都实现并有用例**，权重保持 0。
  /// 上面那两条既有用例就是它的验收门槛 —— **且门槛比原先记录的更严：任何负数都过不去。**
  final int maximumUnusableGapPenalty;

  /// 只为**测试**准备的一份权重：其余各项取 `v1`，坏空档那一项由调用方给。
  ///
  /// 存在的理由很具体：生产权重里 `maximumUnusableGapPenalty` 当前是 0（见上），
  /// 于是"因子按千分比折算"这条逻辑在 `v1` 下**永远算出 0**，用例再怎么写都验不到它。
  /// 与其让那块折算代码没有覆盖，不如给它一份非零权重把它钉住——
  /// 将来重开这一项时，唯一要改的就是 `v1` 里的那个 0。
  const SchedulingWeights.testing({required int maximumUnusableGapPenalty})
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
        maximumUnusableGapPenalty: maximumUnusableGapPenalty,
      );
}
