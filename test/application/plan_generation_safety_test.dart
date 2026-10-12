// 1.8.0（2026-10-12 故障；冻结决策 §1.6）：**自动应用只接受完整可行的提案**。
//
// 修复前 `PlanGenerationFlow` 只看 `isTrusted()`：开关一开，
// **部分计划与含阻断错误的提案都会被静默写库**。用户的第 5 条原话是
// "'信任自动调整'仅自动应用完整、无冲突、无未安排项的提案；其余提案必须进入预览"。
//
// 这个文件把三条路径逐条钉住（trusted × 完整／部分／阻断），再加上 untrusted 的对照。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/plan_generation_flow.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/proposal_disposition.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  ScheduleProposal proposalOf({
    List<UnscheduledTask> unscheduled = const [],
    List<PlanningConflict> conflicts = const [],
  }) => ScheduleProposal(
    proposalId: 'proposal-1',
    inputHash: 'hash-1',
    algorithmVersion: '14',
    planningWindow: TimeRange(
      startUtc: DateTime.utc(2026, 10, 12),
      endUtc: DateTime.utc(2026, 10, 19),
    ),
    blocks: const [],
    unscheduled: unscheduled,
    conflicts: conflicts,
    explanations: const [],
    metrics: ProposalMetrics(
      isFullyFeasible: conflicts.isEmpty && unscheduled.isEmpty,
      scheduledMinutes: 0,
      unscheduledMinutes: unscheduled.fold(
        0,
        (sum, item) => sum + item.shortageMinutes,
      ),
    ),
  );

  /// 记账用的应用替身：记录**每次调用时传的 mode**。
  ///
  /// **必须记账 mode**：只数调用次数无法区分"自动路径传了 `allowPartial`"这个
  /// 被明令禁止的行为（计划 §7 的禁止捷径第 7 条）。
  ({
    int Function() count,
    List<PlanApplyMode> Function() modes,
    Future<ApplyPlanResult> Function(ScheduleProposal, {PlanApplyMode mode})
    apply,
  })
  recorder() {
    var calls = 0;
    final modes = <PlanApplyMode>[];
    return (
      count: () => calls,
      modes: () => modes,
      apply: (proposal, {mode = PlanApplyMode.completeOnly}) async {
        calls++;
        modes.add(mode);
        return ApplyPlanResult.applied(
          ConfirmedPlan(
            id: 'plan',
            inputHash: proposal.inputHash,
            algorithmVersion: proposal.algorithmVersion,
            blocks: proposal.blocks,
          ),
        );
      },
    );
  }

  test('trusted + 完整可行 ⇒ 调用 apply 一次，且 mode 是 completeOnly', () async {
    final sink = recorder();
    final outcome = await PlanGenerationFlow(isTrusted: () => true)
        .run(proposal: proposalOf(), apply: sink.apply);

    expect(sink.count(), 1);
    expect(sink.modes(), [
      PlanApplyMode.completeOnly,
    ], reason: '自动路径**绝不**传 allowPartial（冻结决策 §1.6）');
    expect(outcome.applied, isTrue);
    expect(outcome.requiresPreview, isFalse);
    expect(outcome.message, '已自动应用调整');
  });

  test('trusted + 部分计划 ⇒ **零次** apply，回到预览并说明"仍有未安排事项"', () async {
    final sink = recorder();
    final outcome = await PlanGenerationFlow(isTrusted: () => true).run(
      proposal: proposalOf(
        unscheduled: const [
          UnscheduledTask(taskId: 't-a', shortageMinutes: 30),
        ],
      ),
      apply: sink.apply,
    );

    expect(sink.count(), 0, reason: '部分计划不得自动落库：它是"需要用户确认"的状态，不是"可以替用户决定"的状态');
    expect(outcome.applied, isFalse);
    expect(
      outcome.requiresPreview,
      isTrue,
      reason: '必须给出明确的"去预览"信号，而不是靠 message 反推（那会吞掉导航）',
    );
    expect(outcome.message, '仍有未安排事项，需要确认');
  });

  test('trusted + 阻断提案 ⇒ **零次** apply，回到预览并说明"存在需要处理的问题"', () async {
    final sink = recorder();
    final outcome = await PlanGenerationFlow(isTrusted: () => true).run(
      proposal: proposalOf(
        conflicts: [PlanningConflict(code: ConflictCode.blockOverlap)],
      ),
      apply: sink.apply,
    );

    expect(sink.count(), 0, reason: '阻断提案绝不允许写库（冻结决策 §1.6）');
    expect(outcome.applied, isFalse);
    expect(outcome.requiresPreview, isTrue);
    expect(outcome.message, '计划存在需要处理的问题');
  });

  test('untrusted：三种状态都不自动调用 apply', () async {
    for (final proposal in [
      proposalOf(),
      proposalOf(
        unscheduled: const [
          UnscheduledTask(taskId: 't-a', shortageMinutes: 30),
        ],
      ),
      proposalOf(
        conflicts: [PlanningConflict(code: ConflictCode.blockOverlap)],
      ),
    ]) {
      final sink = recorder();
      final outcome = await PlanGenerationFlow(isTrusted: () => false)
          .run(proposal: proposal, apply: sink.apply);

      expect(sink.count(), 0, reason: '"先预览、后确认"是本功能的默认语义');
      expect(outcome.applied, isFalse);
      expect(
        outcome.requiresPreview,
        isTrue,
        reason: '未开启信任时**永远**去预览，包括完整可行的提案',
      );
      // 只有"完整可行且未开信任"这一种组合不需要额外解释（直接进预览就是默认语义）；
      // 部分/阻断两种必须说明"为什么没自动应用"，否则用户以为开关坏了。
      expect(
        outcome.message.isEmpty,
        classifyProposal(proposal) == ProposalDisposition.fullyApplicable,
        reason: 'disposition=${classifyProposal(proposal)}',
      );
    }
  });

  test('trusted + 完整可行但 apply 返回过期 ⇒ 不视为已应用，且要回预览', () async {
    final outcome = await PlanGenerationFlow(isTrusted: () => true).run(
      proposal: proposalOf(),
      apply: (proposal, {mode = PlanApplyMode.completeOnly}) async =>
          ApplyPlanResult.stale(),
    );

    expect(outcome.applied, isFalse);
    expect(outcome.message, contains('原有计划保留'));
    expect(
      outcome.requiresPreview,
      isTrue,
      reason: '自动应用失败时也要给出原因，而具体原因只有预览页说得清',
    );
  });

  test('分类与流程走向一致：`requiresPreview` 等价于"没有真的应用"', () async {
    // 双向断言，防止"流程与分类漂移"：只要没应用成功就一定需要预览，
    // 反之只要应用成功就一定不需要（用户已经拿到结果了）。
    for (final proposal in [
      proposalOf(),
      proposalOf(
        unscheduled: const [
          UnscheduledTask(taskId: 't-a', shortageMinutes: 30),
        ],
      ),
      proposalOf(
        conflicts: [PlanningConflict(code: ConflictCode.blockOverlap)],
      ),
    ]) {
      for (final trusted in [true, false]) {
        final sink = recorder();
        final outcome = await PlanGenerationFlow(isTrusted: () => trusted)
            .run(proposal: proposal, apply: sink.apply);

        expect(
          outcome.requiresPreview,
          !outcome.applied,
          reason: 'disposition=${classifyProposal(proposal)}, trusted=$trusted',
        );
      }
    }
  });
}
