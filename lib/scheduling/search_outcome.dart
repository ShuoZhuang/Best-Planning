/// 一次排程搜索的**结果种类**（算法 17，计划 §6 / §3.6）。
///
/// ## 为什么必须分成五种
///
/// 修复前"排不下"只有一条出路：`insufficientCapacity`。
/// 于是四种**性质完全不同**的处境被翻译成同一句话：
///
/// | 真实处境 | 用户该做什么 | 修复前显示 |
/// | --- | --- | --- |
/// | 硬约束下确实无解 | 腾时间、改截止 | 可用时间不足 |
/// | 只是用到了偏好外的时段 | **什么都不用做** | 可用时间不足 |
/// | 搜索预算耗尽，还没证明无解 | 重新生成（可能就成功） | 可用时间不足 |
/// | 引擎还有合法候选却留下缺口 | **报缺陷**，不是腾时间 | 可用时间不足 |
///
/// 计划 §Global Constraints 明确要求这四类使用**不同状态**，
/// 并且禁止"搜索超时伪装成无解"。
enum SearchOutcomeKind {
  /// 全部必需分钟都在**偏好内**合法放置完成。
  solved,

  /// 全部必需分钟都已合法放置，但用到了偏好时段之外或软恢复余量里的时间
  /// （计划 §6：`solvedWithSoftRelaxation`）。
  ///
  /// **它不是失败**：计划 §3.7 与 ALG-25/26 都明确精力与期望时段只是软偏好，
  /// 因此这个状态照常可应用——只是解释里要说明"偏离了偏好"。
  solvedWithSoftRelaxation,

  /// **已经证明**完整方案在硬约束下不可行（计划 §6）。
  ///
  /// 提案仍可携带迄今最优的合法部分块；是否写入由用户的**显式部分应用授权**决定
  /// （ALG-41）。因此它允许 `allowPartial`，但默认（完整模式）拒绝。
  hardInfeasible,

  /// 搜索达到预算，**尚未**证明有解或无解（计划 §3.6 第 6 条）。
  ///
  /// **既不能声称无解，也不能部分应用**（计划 §6 末段）：
  /// 文案必须是"未能确认完整方案"，而不是"可用时间不足"。
  budgetExhausted,

  /// 输出违反了引擎自己的内部不变量（重复块 ID、任务分钟超发、仍有合法候选却留缺口）。
  ///
  /// **永远禁止应用**，且 `allowPartial` 不得绕过（ALG-42）：
  /// 它不是"装不下"，而是"排程器自己没排好"，用户要做的不是腾时间。
  invariantViolation,
}

/// [SearchOutcomeKind] 是否可以**在该模式下**被应用。
///
/// 把"可应用性"写成一处判据而不是散在界面与仓库层：
/// 两处各写一遍，迟早在"搜索未决到底能不能部分应用"上分叉。
bool isApplicableOutcome(
  SearchOutcomeKind kind, {
  required bool allowPartial,
}) => switch (kind) {
  // 完整或"软偏好之外但全部放完"都照常可应用。
  SearchOutcomeKind.solved ||
  SearchOutcomeKind.solvedWithSoftRelaxation => true,
  // 硬无解只在用户**显式**授权部分应用时可应用。
  SearchOutcomeKind.hardInfeasible => allowPartial,
  // 下面两类**任何模式**都禁止应用（ALG-42）。
  SearchOutcomeKind.budgetExhausted ||
  SearchOutcomeKind.invariantViolation => false,
};
