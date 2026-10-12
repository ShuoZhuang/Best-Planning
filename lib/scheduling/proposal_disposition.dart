import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 一份提案的**处置状态**（1.8.0，2026-10-12 故障；冻结决策 §1.5）。
///
/// **为什么必须是显式分类、而不是页面临时判断**：截图里的第三件事是"明知装不下，
/// 页面仍显示可点击的『确认应用』"。根因不是按钮写错，而是**没有任何一层回答
/// "这份提案能不能应用"这个问题**：引擎有 `metrics.isFullyFeasible`，预览模型却只保存
/// `isStale`，于是页面只能靠"冲突列表空不空"临时猜——而它连冲突列表都只有字符串
/// （`List<String>`，见 R7）。
///
/// 分类把这件事变成**一个纯函数 + 一个枚举**，由引擎、应用服务与预览共同消费：
/// 三处若各自判断，必然漂移。
enum ProposalDisposition {
  /// 全部排得下、没有任何阻断错误 ⇒ 可以直接应用。
  fullyApplicable,

  /// 没有阻断错误，但有**未安排**的任务（"容量不足"） ⇒ 允许用户明确确认后
  /// 应用可安排的部分（冻结决策 §1.6）。
  ///
  /// **它不是错误**：规范明确"『容量不足』不是结构性错误：允许用户明确确认应用可安排部分；
  /// 但自动应用不得静默接受部分计划"。
  partialRequiresConfirmation,

  /// 存在阻塞错误（重叠、越界、锁定块被移动、非法输入……） ⇒ 不得调用仓储写入，
  /// 不得显示可点击的确认按钮，不得记成已应用历史。
  blocked,
}

/// 按**结构化事实**判定提案的处置状态（冻结决策 §1.5）。
///
/// **规则顺序不可调换**：
/// 1. `proposal.conflicts.isNotEmpty` → [ProposalDisposition.blocked]；
/// 2. 否则 `proposal.unscheduled.isNotEmpty` →
///    [ProposalDisposition.partialRequiresConfirmation]；
/// 3. 否则 → [ProposalDisposition.fullyApplicable]。
///
/// **它刻意不读 `proposal.metrics`**：`isFullyFeasible` 是**派生量**，把它当成第二条
/// 事实源会让"旧 metrics 掩盖结构化问题"成为可能（例如某次重构忘了在新增的
/// 阻断路径上更新 metrics，页面就会显示可点击的确认）。metrics 只能与它**一致**，
/// 那由测试双向断言（见 `proposal_disposition_test.dart`）。
ProposalDisposition classifyProposal(ScheduleProposal proposal) {
  if (proposal.conflicts.isNotEmpty) return ProposalDisposition.blocked;
  if (proposal.unscheduled.isNotEmpty) {
    return ProposalDisposition.partialRequiresConfirmation;
  }
  return ProposalDisposition.fullyApplicable;
}

/// [ProposalDisposition.fullyApplicable] 的便捷判断。
///
/// 存在的理由：调用点（自动应用、信任开关、按钮状态）问的都是同一个问题，
/// 直接比枚举更容易读错（例如写成 `!= blocked`，那会把"部分计划"也算成可自动应用）。
bool isFullyApplicable(ScheduleProposal proposal) =>
    classifyProposal(proposal) == ProposalDisposition.fullyApplicable;
