// 计划 Task 9／Task 12 人工场景 F：**"未能确认完整方案"这条链路必须走通**。
//
// ## 为什么值得一条端到端用例
//
// 这个缺口不是靠单个函数修好的，而是由三块拼起来的，每块各自有测试：
//
// | 环节 | 实现 | 已有测试 |
// | --- | --- | --- |
// | 判据（能不能应用） | `isApplicableOutcome` | `search_outcome_label_test` |
// | 文案（为什么不能） | `searchOutcomeLabel` | `search_outcome_label_test` |
// | 载体（随提案传递） | `ScheduleProposal.outcome` | `schedule_proposal_outcome_test` |
//
// 但**没有一条用例把三者串起来**，而计划对场景 F 的要求恰好是一个完整的用户可见结果：
//
// > 预期：显示"未能确认完整方案"，不显示"可用时间不足"，应用按钮禁用。
//
// 三块各自正确、拼起来仍然可以错（例如界面读 `isApplicableOutcome` 时传了
// `allowPartial: true`，或文案链走的是另一条回落）。因此这里钉住**组合后的行为**：
// 给定 `budgetExhausted`，界面应当同时得到"不可应用"与"正确的句子"。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';

ScheduleProposal _proposal(SearchOutcomeKind outcome) => ScheduleProposal(
  proposalId: 'p',
  inputHash: 'h',
  algorithmVersion: 'test',
  planningWindow: TimeRange(
    startUtc: DateTime.utc(2026, 10, 5),
    endUtc: DateTime.utc(2026, 10, 6),
  ),
  blocks: const [],
  unscheduled: const [],
  conflicts: const [],
  explanations: const [],
  metrics: const ProposalMetrics(
    isFullyFeasible: false,
    scheduledMinutes: 0,
    unscheduledMinutes: 0,
  ),
  outcome: outcome,
);

/// 界面在一个提案上要问的两件事：**按钮能不能点**、**上面写什么**。
({bool canApply, String label}) presentationOf(
  ScheduleProposal proposal, {
  required bool allowPartial,
}) => (
  canApply: isApplicableOutcome(proposal.outcome, allowPartial: allowPartial),
  label: searchOutcomeLabel(proposal.outcome),
);

void main() {
  group('人工场景 F：预算耗尽 → 不可应用 + 正确文案（Task 9）', () {
    test('**"未能确认完整方案" + 应用按钮禁用，且两种模式都禁用**', () {
      final proposal = _proposal(SearchOutcomeKind.budgetExhausted);

      for (final allowPartial in [false, true]) {
        final presentation = presentationOf(
          proposal,
          allowPartial: allowPartial,
        );
        expect(
          presentation.canApply,
          isFalse,
          reason:
              'allowPartial=$allowPartial 时仍必须禁用：'
              '预算耗尽既没证明有解也没证明无解，部分应用没有依据',
        );
        expect(
          presentation.label,
          contains('未能确认完整方案'),
          reason: '计划对场景 F 指定了这个措辞；实测「${presentation.label}」',
        );
        expect(
          presentation.label,
          isNot(contains('可用时间不足')),
          reason:
              '搜索超时伪装成无解会把用户引向"腾时间"；'
              '实测「${presentation.label}」',
        );
      }
    });

    test('**内部不变量被破坏时：不可应用 + 说清后果，也不说成容量不足**（ALG-42）', () {
      final presentation = presentationOf(
        _proposal(SearchOutcomeKind.invariantViolation),
        allowPartial: true,
      );
      expect(presentation.canApply, isFalse);
      expect(presentation.label, contains('未自动应用'));
      expect(presentation.label, isNot(contains('可用时间不足')));
    });

    test('**真的无解才允许说"可用时间不足"，且默认拒绝、授权后可应用**', () {
      final proposal = _proposal(SearchOutcomeKind.hardInfeasible);
      final refused = presentationOf(proposal, allowPartial: false);
      expect(refused.canApply, isFalse, reason: '完整模式下不写部分计划');
      expect(
        refused.label,
        contains('可用时间不足'),
        reason: '只有这一种处境允许这么说——它已经证明无解',
      );

      final allowed = presentationOf(proposal, allowPartial: true);
      expect(allowed.canApply, isTrue, reason: '用户显式授权部分应用时才可写（ALG-41）');
    });

    test('**完整方案照常可应用**（回归：闸门不能误伤正常路径）', () {
      for (final kind in [
        SearchOutcomeKind.solved,
        SearchOutcomeKind.solvedWithSoftRelaxation,
      ]) {
        final presentation = presentationOf(
          _proposal(kind),
          allowPartial: false,
        );
        expect(presentation.canApply, isTrue, reason: '$kind 必须可应用');
        expect(
          presentation.label,
          isNot(contains('可用时间不足')),
          reason: '$kind 不是失败',
        );
      }
    });

    test('四种**失败**处境的说法互不相同（用户能据此决定下一步）', () {
      final labels = {
        for (final kind in [
          SearchOutcomeKind.hardInfeasible,
          SearchOutcomeKind.budgetExhausted,
          SearchOutcomeKind.invariantViolation,
        ])
          kind: searchOutcomeLabel(kind),
      };
      expect(
        labels.values.toSet(),
        hasLength(labels.length),
        reason: '三种失败必须说三种话，否则用户无法判断该腾时间、重新生成还是报缺陷',
      );
    });
  });
}
