// 计划 Task 9：**`ScheduleProposal.outcome` 必须能穿过包装方法**。
//
// ## 为什么值得单独钉住
//
// `schedule_proposal.dart` 里有一个**反复出现过的缺陷类别**：新增字段时忘记在
// `with*` 方法里搬运。文件自己在 `withLinkedBlocks` 的注释里记着这件事：
//
// > **`adjustmentRequirement` 必须显式带过去**：它此前被漏在这里，而
// > `withRuleOverride` 与 `withAdjustmentRequirement` 都传了。
//
// `outcome` 正落在同一个陷阱上：它由引擎设置，随后 `PlanningService` 会用
// `withRuleOverride` / `withAdjustmentRequirement` 包装提案。
// 漏搬运的后果很隐蔽——包装后 `outcome` 悄悄变回默认的 `solved`，
// 于是"搜索预算耗尽"在界面上又变回"已排定完整方案"，而**没有任何一处报错**。
//
// 因此这里不是测"字段存在"，而是测"它在两条包装路径上都活得下来"。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
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

void main() {
  group('`ScheduleProposal.outcome` 的搬运（Task 9）', () {
    for (final outcome in [
      SearchOutcomeKind.budgetExhausted,
      SearchOutcomeKind.invariantViolation,
      SearchOutcomeKind.hardInfeasible,
      SearchOutcomeKind.solvedWithSoftRelaxation,
    ]) {
      test('`withRuleOverride` 保留 $outcome', () {
        final wrapped = _proposal(outcome).withRuleOverride(null);
        expect(
          wrapped.outcome,
          outcome,
          reason: '包装后 outcome 变了 ⇒ 界面上会把「未决」说成「已排定完整方案」',
        );
      });

      test('`withAdjustmentRequirement` 保留 $outcome', () {
        final wrapped = _proposal(outcome).withAdjustmentRequirement(
          AdjustmentRequirement(
            targetBlockId: 'block',
            notBeforeUtc: DateTime.utc(2026, 10, 5, 12),
            requiredMinutes: 60,
            originalStartUtc: DateTime.utc(2026, 10, 5, 11),
          ),
        );
        expect(wrapped.outcome, outcome);
      });
    }

    test('默认是 `solved`（手写夹具的便利路径）', () {
      final proposal = ScheduleProposal(
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
          isFullyFeasible: true,
          scheduledMinutes: 0,
          unscheduledMinutes: 0,
        ),
      );
      expect(proposal.outcome, SearchOutcomeKind.solved);
    });
  });
}
