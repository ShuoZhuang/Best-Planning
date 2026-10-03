import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 生成提案之后的走向：默认只是打开预览等用户确认，"信任自动调整"开启时才直接应用。
///
/// **为什么不把它写在路由里**：这段判断有真实分支（信任与否、应用成功与否、过期与否），而路由
/// 在本仓库从不被测试覆盖。把它抽成一个只依赖**两个回调**的薄流程后，测试可以用记账用的假回调
/// 验证每一条分支，而不必伪造具体服务。
///
/// **对应需求**：FR-REPLAN-03"默认由用户确认后应用调整"；FR-REPLAN-04"提供'信任自动调整'开关；
/// 开启后仍记录调整历史和原因"——历史与原因由应用本身写入（新计划版本与变更日志），因此这里
/// 不需要额外"补记"，只需要真的走应用那一步。FR-REPLAN-05"调整计算失败或被取消时保留原有已
/// 确认计划"由 `apply` 的语义保证（只在成功时才换版本），这里只如实回报。
final class PlanGenerationFlow {
  const PlanGenerationFlow({required this.isTrusted});

  /// 读取"信任自动调整"当前值。用回调而不是直接持有设置对象：这一层不需要知道它存在哪里。
  final bool Function() isTrusted;

  Future<PlanGenerationOutcome> run({
    required ScheduleProposal proposal,
    required Future<ApplyPlanResult> Function(ScheduleProposal proposal) apply,
  }) async {
    if (!isTrusted()) {
      // 默认路径：只打开预览，**不调用 apply**——"先预览、后确认"就是这个意思。
      return PlanGenerationOutcome(
        proposalId: proposal.proposalId,
        applied: false,
        message: '',
      );
    }
    final result = await apply(proposal);
    return PlanGenerationOutcome(
      proposalId: proposal.proposalId,
      applied: result.status == ApplyPlanStatus.applied,
      message: switch (result.status) {
        ApplyPlanStatus.applied => '已自动应用调整',
        // FR-REPLAN-05：失败或过期时**原有已确认计划保留**，提示要如实这样说，
        // 而不是含糊地说"调整完成"。
        ApplyPlanStatus.staleProposal => '提案已过期，未自动应用（原有计划保留）',
        ApplyPlanStatus.invalidProposal => '提案不可行，未自动应用（原有计划保留）',
      },
    );
  }
}

/// 一次"生成 → （可能）应用"的结果。`message` 为空表示走的是默认路径（去预览页确认）。
final class PlanGenerationOutcome {
  const PlanGenerationOutcome({
    required this.proposalId,
    required this.applied,
    required this.message,
  });

  final String proposalId;
  final bool applied;
  final String message;
}
