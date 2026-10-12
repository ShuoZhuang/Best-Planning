import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/proposal_disposition.dart';
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
///
/// ## 1.8.0：信任自动调整**只**自动应用完整可行的提案（冻结决策 §1.6）
///
/// 修复前这里只看 `isTrusted()`：开关一开，**部分计划与含阻断错误的提案都会被静默写库**。
/// 用户的第 5 条原话是"'信任自动调整'仅自动应用完整、无冲突、无未安排项的提案；
/// 其余提案必须进入预览"。
///
/// 因此这一段现在先问 [classifyProposal]：
/// - [ProposalDisposition.fullyApplicable] + 信任 ⇒ 调 `apply`，且**只传 `completeOnly`**；
/// - 其余两态 ⇒ `applied = false`、`requiresPreview = true`，**根本不调用 `apply`**
///   （不是"调用了但被拦住"——那会多一次无谓的读库与哈希重放）。
///
/// **自动路径绝不传 `allowPartial`**：那是"用户明确确认过"的专属授权。
final class PlanGenerationFlow {
  const PlanGenerationFlow({required this.isTrusted});

  /// 读取"信任自动调整"当前值。用回调而不是直接持有设置对象：这一层不需要知道它存在哪里。
  final bool Function() isTrusted;

  Future<PlanGenerationOutcome> run({
    required ScheduleProposal proposal,
    required Future<ApplyPlanResult> Function(
      ScheduleProposal proposal, {
      PlanApplyMode mode,
    })
    apply,
  }) async {
    final disposition = classifyProposal(proposal);

    if (!isTrusted() || disposition != ProposalDisposition.fullyApplicable) {
      // 默认路径：只打开预览，**不调用 apply**——"先预览、后确认"就是这个意思。
      //
      // `requiresPreview` 是**显式**的：此前调用方靠"`message` 非空就 return"判断去向，
      // 于是"部分/阻断提案"这两个新增分支一旦给出非空 message，预览导航就会被吞掉
      // （计划 Task 5 Step 6 点名的就是这个陷阱）。
      return PlanGenerationOutcome(
        proposalId: proposal.proposalId,
        applied: false,
        requiresPreview: true,
        message: switch (disposition) {
          // 完整可行但用户没开信任开关：不需要额外解释，直接进预览。
          ProposalDisposition.fullyApplicable => '',
          ProposalDisposition.partialRequiresConfirmation => '仍有未安排事项，需要确认',
          ProposalDisposition.blocked => '计划存在需要处理的问题',
        },
      );
    }

    final result = await apply(proposal, mode: PlanApplyMode.completeOnly);
    return PlanGenerationOutcome(
      proposalId: proposal.proposalId,
      applied: result.status == ApplyPlanStatus.applied,
      // 自动应用失败（过期/非法）时也要回到预览：那里才显示得出具体原因。
      requiresPreview: result.status != ApplyPlanStatus.applied,
      message: switch (result.status) {
        ApplyPlanStatus.applied => '已自动应用调整',
        // FR-REPLAN-05：失败或过期时**原有已确认计划保留**，提示要如实这样说，
        // 而不是含糊地说"调整完成"。
        ApplyPlanStatus.staleProposal => '提案已过期，未自动应用（原有计划保留）',
        ApplyPlanStatus.invalidProposal => '提案不可行，未自动应用（原有计划保留）',
        // 自动路径传的是 `completeOnly`，而这一支只在"有未安排项"时出现 ——
        // 那种情况下上面根本不会调用 `apply`。保留这一支是为了**穷尽 switch**：
        // 用 `_ =>` 吞掉新状态，正是本批次反复出问题的地方。
        ApplyPlanStatus.partialConfirmationRequired => '仍有未安排事项，需要确认',
      },
    );
  }
}

/// 一次"生成 → （可能）应用"的结果。
///
/// [requiresPreview] 明确表示"调用方应当去预览页"，而不是让调用方从 [message] 反推。
final class PlanGenerationOutcome {
  const PlanGenerationOutcome({
    required this.proposalId,
    required this.applied,
    required this.requiresPreview,
    required this.message,
  });

  final String proposalId;
  final bool applied;

  /// 是否应当导航到预览页。**它是独立字段，不是 `message.isNotEmpty` 的推论**。
  final bool requiresPreview;
  final String message;
}
