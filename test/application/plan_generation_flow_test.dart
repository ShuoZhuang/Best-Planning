// FR-REPLAN-03/04/05 在"生成计划"这条路上的分支。
//
// 关键的一条是**第一个用例**：默认（不信任）时**不得调用应用**——"先预览、后确认"如果在这里
// 破了，用户会看到计划在自己没确认的情况下被改掉。其余两条钉住失败/过期时的措辞：必须说明
// "原有计划保留"，而不是含糊地说调整完成。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/plan_generation_flow.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

ScheduleProposal _proposal() => ScheduleProposal(
  proposalId: 'proposal-1',
  inputHash: 'hash-1',
  algorithmVersion: '1',
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

void main() {
  test('默认（未开启信任）只去预览，绝不调用应用', () async {
    final calls = <ScheduleProposal>[];
    final flow = PlanGenerationFlow(isTrusted: () => false);

    final outcome = await flow.run(
      proposal: _proposal(),
      apply: (proposal) async {
        calls.add(proposal);
        return ApplyPlanResult.applied(_plan());
      },
    );

    // 这是本文件最重要的一条：默认路径一旦调用了 apply，"先预览、后确认"就名存实亡。
    expect(calls, isEmpty);
    expect(outcome.applied, isFalse);
    expect(outcome.message, isEmpty);
    expect(outcome.proposalId, 'proposal-1');
  });

  test('开启信任时直接应用，并说明已自动应用', () async {
    final flow = PlanGenerationFlow(isTrusted: () => true);

    final outcome = await flow.run(
      proposal: _proposal(),
      apply: (proposal) async => ApplyPlanResult.applied(_plan()),
    );

    expect(outcome.applied, isTrue);
    expect(outcome.message, '已自动应用调整');
  });

  test('开启信任但提案过期时不应用，并说明原有计划保留', () async {
    final flow = PlanGenerationFlow(isTrusted: () => true);

    final outcome = await flow.run(
      proposal: _proposal(),
      apply: (proposal) async => ApplyPlanResult.stale(),
    );

    expect(outcome.applied, isFalse);
    // FR-REPLAN-05：措辞必须说清"原有计划保留"，否则用户无法判断计划现在是什么状态。
    expect(outcome.message, contains('原有计划保留'));
  });

  test('开启信任但提案不可行时不应用，并说明原有计划保留', () async {
    final flow = PlanGenerationFlow(isTrusted: () => true);

    final outcome = await flow.run(
      proposal: _proposal(),
      apply: (proposal) async => ApplyPlanResult.invalid(const []),
    );

    expect(outcome.applied, isFalse);
    expect(outcome.message, contains('原有计划保留'));
  });
}

ConfirmedPlan _plan() => ConfirmedPlan(
  id: 'plan-1',
  inputHash: 'hash-1',
  algorithmVersion: 'v1',
  blocks: const [],
);
