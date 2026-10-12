import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final class PlanApplicationService {
  PlanApplicationService({
    required this.source,
    required this.repository,
    required TimeZoneDatabase zones,
    this.snapshots = const InputSnapshotBuilder(),
    this.onPlanChanged,
  }) : _validator = PlanValidator(zones);

  final ScheduleProblemSource source;
  final PlanRepository repository;
  final PlanValidator _validator;
  final InputSnapshotBuilder snapshots;

  /// 计划被**真正改变**之后的回调（B5）。
  ///
  /// 存在的理由是一处真实缺口：通知此前**只在应用启动时同步一次**（`main.dart` 里那唯一一处
  /// `syncNextSevenDays()`），因此**应用开着的时候新建任务、改计划都不会重排提醒**——已排的
  /// 提醒会与当前计划不一致。组合根用它来重新同步。
  final Future<void> Function()? onPlanChanged;

  /// 应用一份提案（1.8.0，2026-10-12 故障；冻结决策 §1.6）。
  ///
  /// **执行顺序不可改变**（计划 Task 5 Step 4）：
  /// ① 重放输入与哈希 → ② validator 阻断校验 → ③ adjustment fulfilment →
  /// ④ partial 授权检查 → ⑤ repository write。
  ///
  /// 顺序颠倒会在三处放行不该放行的东西：
  /// - 把 ④ 放到 ② 之前，"部分计划"这一支会盖住结构错误（**不完整计划不是错误**，
  ///   但**结构错误也不是"缺一部分"**）；
  /// - 把 ④ 放到 ① 之前，过期提案会被误报成"容量缺口"，用户看到的是完全错误的原因；
  /// - 把 ④ 放到 ③ 之前，"请求延后 30 分钟却只延后 10 分钟"会被 `allowPartial` 洗白，
  ///   而用户要求的正是那 30 分钟。
  Future<ApplyPlanResult> apply(
    ScheduleProposal proposal, {
    PlanApplyMode mode = PlanApplyMode.completeOnly,
  }) async {
    // 必须重放生成该提案时用过的同一个一次性规则覆盖（如特殊日恢复的睡眠例外），
    // 否则重新装配出的规则与提案不一致，哈希必然不同，合法提案会被误判为过期。
    final current = withCurrentInputHash(
      await source.load(override: proposal.ruleOverride),
      snapshots,
    );
    if (current.inputHash != proposal.inputHash) {
      return ApplyPlanResult.stale();
    }
    final conflicts = _validator.validate(current, proposal.blocks);
    if (conflicts.isNotEmpty) return ApplyPlanResult.invalid(conflicts);
    // **延后兑现校验（用户第 72 轮）**：只针对**当前调整请求**，
    // 不是"方案里有任意未安排任务"——部分计划本来就可能包含未安排任务。
    //
    // 放在这里而不是只放在界面按钮上：**手动确认与自动应用共用同一条规则**，
    // 自动应用绕不过去（用户第 3、5 条）。
    final adjustmentFailure = _adjustmentFailure(proposal, current);
    if (adjustmentFailure != null) {
      // 保留当前已确认计划（**不写入部分失败结果**）：这里直接返回，不落库。
      //
      // **`allowPartial` 也不能绕过它**：延后要求是用户明确提出的具体目标，
      // "只应用一部分"不适用于"延后 30 分钟却只延后 10 分钟"。
      return ApplyPlanResult.invalid([adjustmentFailure]);
    }
    // **partial 授权检查**（冻结决策 §1.6）：结构错误已经拦住了，这里只剩"装不下"。
    if (mode == PlanApplyMode.completeOnly && proposal.unscheduled.isNotEmpty) {
      // 返回结果里为每个缺口造一条 `insufficientCapacity`，**只用于告诉调用方
      // "需要明确允许部分计划"**，不写回提案。
      return ApplyPlanResult.partialRequired([
        for (final item in proposal.unscheduled)
          PlanningConflict(
            code: ConflictCode.insufficientCapacity,
            taskId: item.taskId,
            shortageMinutes: item.shortageMinutes,
          ),
      ]);
    }
    final result = await repository.applyProposal(proposal, current.inputHash);
    // **只在真的应用了之后**同步：过期与非法提案都没有改变当前计划，同步一次既是白跑，
    // 更糟的是会掩盖"这次确认其实失败了"。
    if (result.status == ApplyPlanStatus.applied) {
      await onPlanChanged?.call();
    }
    return result;
  }

  /// 本次延后有没有兑现；兑现（或本次不是调整）时返回 null。
  ///
  /// **只针对当前调整请求**：判定逻辑在 `evaluateAdjustmentFulfilment`，
  /// 它只看目标块所属任务，别的任务有没有排进去完全不参与。
  PlanningConflict? _adjustmentFailure(
    ScheduleProposal proposal,
    ScheduleProblem current,
  ) {
    final requirement = proposal.adjustmentRequirement;
    if (requirement == null) return null;
    // 目标块所属任务：确认计划里查得到才算得出"要延后的是谁"。
    final target = current.confirmedBlocks
        .where((block) => block.id == requirement.targetBlockId)
        .firstOrNull;
    if (target == null) return null;
    final fulfilment = evaluateAdjustmentFulfilment(
      requirement: requirement,
      proposalBlocks: proposal.blocks,
    );
    if (fulfilment.isFulfilled) return null;
    return PlanningConflict(
      code: ConflictCode.requestedAdjustmentUnsatisfied,
      taskId: target.taskId,
      relatedEntityIds: [requirement.targetBlockId],
      details: {
        'reason': fulfilment.unsatisfiedReason,
        // 界面用标题而不是 UUID 展示（用户第 3 条）。
        'notBeforeUtc': requirement.notBeforeUtc.toIso8601String(),
        'requiredMinutes': requirement.requiredMinutes,
      },
    );
  }
}
