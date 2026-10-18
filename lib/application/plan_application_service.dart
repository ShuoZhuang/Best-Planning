import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final class PlanApplicationService {
  PlanApplicationService({
    required this.source,
    required this.repository,
    required TimeZoneDatabase zones,
    this.snapshots = const InputSnapshotBuilder(),
    this.onPlanChanged,
    this.updateSafety,
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

  /// 计划应用期间的更新阻塞端口（UPD-029）。为空时不汇报。
  final UpdateSafetyCoordinator? updateSafety;

  /// 应用一份提案（1.8.0，2026-10-12 故障；冻结决策 §1.6）。
  ///
  /// **执行顺序不可改变**（计划 Task 5 Step 4）：
  /// ① 重放输入与哈希 → ② **引擎已经报告的阻断冲突** → ③ validator 阻断校验 →
  /// ④ adjustment fulfilment → ⑤ partial 授权检查 → ⑥ repository write。
  ///
  /// 顺序颠倒会在几处放行不该放行的东西：
  /// - 把 ⑤ 放到 ③ 之前，"部分计划"这一支会盖住结构错误（**不完整计划不是错误**，
  ///   但**结构错误也不是"缺一部分"**）；
  /// - 把 ⑤ 放到 ① 之前，过期提案会被误报成"容量缺口"，用户看到的是完全错误的原因；
  /// - 把 ⑤ 放到 ④ 之前，"请求延后 30 分钟却只延后 10 分钟"会被 `allowPartial` 洗白，
  ///   而用户要求的正是那 30 分钟。
  ///
  /// **② 为什么必须存在、且必须在 validator 之前**：引擎报告的阻断冲突里有一类是
  /// `schedulingInvariantViolation`——"排程没有使用仍可用的合法时段"（计划 §2.3 / §2.4）。
  /// 它在**块集合本身合法**的情况下出现，因此 validator 查不出来；而它恰恰是最不能
  /// 被写进用户计划的一类。`allowPartial` 只适用于"装不下"，不适用于"排程器自己没排好"，
  /// 因此这里对 `proposal.conflicts` 的检查**在任何模式下都不可绕过**。
  Future<ApplyPlanResult> apply(
    ScheduleProposal proposal, {
    PlanApplyMode mode = PlanApplyMode.completeOnly,
  }) async {
    final lease = updateSafety?.begin(UpdateBlocker.planApplying);
    try {
      return await _apply(proposal, mode: mode);
    } finally {
      lease?.release();
    }
  }

  Future<ApplyPlanResult> _apply(
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
    // ── 算法版本闸门（计划 Task 10「应用安全」）────────────────────────────────
    //
    // 输入哈希只能证明**输入**没变。算法本身升级之后，同一份输入会算出不同的块集合，
    // 而旧提案的块在新算法下可能已经违反新的硬约束——把它写进计划等于用已经被
    // 判定不合格的安排覆盖用户的确认计划。
    //
    // 因此版本不符与"输入已变"同等处理：**过期、零写入、要求重新生成**。
    // 判据用引擎自己的常量，不留第二份版本号（两份必然漂移）。
    //
    // 位置在哈希之后、冲突与 validator 之前：`stale` 是"这份提案已经作废"，
    // 它必须先于一切"内容是否合法"的判断——否则用户会看到"容量不足"之类
    // 完全错误的原因（同 §①/⑤ 顺序那两条说明）。
    if (proposal.algorithmVersion !=
        DeterministicScheduleEngine.algorithmVersion) {
      return ApplyPlanResult.stale();
    }
    // ── 调整要求闸门（计划 Task 10「应用安全」）────────────────────────────────
    //
    // `problem.adjustment` **不进 `inputHash`**（它是"比较与目标"的输入，不是
    // "哪些时间可用"的输入），因此输入哈希抓不到"用户的调整意图变了"：
    //
    //   ① 用户对块 A 点"延后到 15:00" → 生成提案 P（P 携带这条要求）；
    //   ② 用户改主意 → 对块 B 延后到 17:00（哈希不变）；
    //   ③ 用户点"应用 P"。
    //
    // 没有这道闸门时，`_adjustmentFailure` 只会确认"P 兑现了 **P 自己**那条要求"
    // ——它当然兑现了——于是这份与用户当前意图无关的计划被写进确认计划，
    // 而用户要的延后从未发生。
    //
    // 判据只看**请求本身**（目标块 + 下界）：时长与原位置来自确认计划里那一块，
    // 是"延后前的事实"，由 `evaluateAdjustmentFulfilment` 负责，不在这里重复。
    if (proposal.adjustmentRequirement case final requirement?) {
      final request = current.adjustment;
      if (request == null ||
          request.targetBlockId != requirement.targetBlockId ||
          request.notBeforeUtc != requirement.notBeforeUtc) {
        return ApplyPlanResult.stale();
      }
    }
    // ── 搜索结果闸门（计划 Task 9／Task 10「应用安全」）────────────────────────
    //
    // 提案自带 `outcome`（算法 17）。两类处境**任何模式都不许应用**，
    // `allowPartial` 也不得绕过（ALG-42）：
    //
    // - `budgetExhausted`：搜索达到预算，**既没证明有解也没证明无解**。
    //   计划 §1.2 第 9 条与 ALG-47 明令它**不得**被说成"可用时间不足"；
    //   正确处置是重新生成（很可能就成功）。
    // - `invariantViolation`：引擎还有合法候选却留下缺口。那不是"装不下"，
    //   而是排程器自己没排好——用户要做的不是腾时间，而是报缺陷。
    //
    // 没有这道闸门时，一个"预算耗尽"的提案会落到 `unscheduled.isNotEmpty` 那一支：
    // 完整模式返回 `partialRequired`（把未决说成"要不要就这样应用"），
    // `allowPartial` 模式**直接写库**。两种都是一次静默的错误应用。
    //
    // 位置在 `conflicts` 之前：这两类是**未决/异常**，比任何"内容是否合法"的判断
    // 都更早成立——内容看起来合法并不代表这份搜索结果可用了。
    if (!isApplicableOutcome(proposal.outcome, allowPartial: true)) {
      return ApplyPlanResult.invalid([
        PlanningConflict(
          code: proposal.outcome == SearchOutcomeKind.invariantViolation
              ? ConflictCode.schedulingInvariantViolation
              : ConflictCode.insufficientCapacity,
        ),
      ]);
    }
    // **引擎已经报过的阻断冲突先落地**：`stale` 检查之后、validator 之前。
    // 非空立即返回 `invalid`，因此 `allowPartial` 无法绕过引擎已经报告的阻断冲突，
    // 更不许写库——提案自己带着"不得应用"的证据时，重新校验一遍块集合并不足以放行。
    if (proposal.conflicts.isNotEmpty) {
      return ApplyPlanResult.invalid(proposal.conflicts);
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
