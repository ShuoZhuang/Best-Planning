import 'dart:collection';

import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

final class UnscheduledTask {
  const UnscheduledTask({required this.taskId, required this.shortageMinutes});
  final String taskId;
  final int shortageMinutes;
}

final class PlanExplanation {
  PlanExplanation({
    required this.code,
    Map<String, Object?> parameters = const {},
  }) : parameters = UnmodifiableMapView(Map.of(parameters));
  final String code;
  final Map<String, Object?> parameters;
}

final class ProposalMetrics {
  const ProposalMetrics({
    required this.isFullyFeasible,
    required this.scheduledMinutes,
    required this.unscheduledMinutes,
  });
  final bool isFullyFeasible;
  final int scheduledMinutes;
  final int unscheduledMinutes;
}

final class ScheduleProposal {
  ScheduleProposal({
    required this.proposalId,
    required this.inputHash,
    required this.algorithmVersion,
    required List<PlannedBlock> blocks,
    required List<UnscheduledTask> unscheduled,
    required List<PlanningConflict> conflicts,
    required List<PlanExplanation> explanations,
    required this.metrics,
    this.ruleOverride,
  }) : blocks = UnmodifiableListView(List.of(blocks)),
       unscheduled = UnmodifiableListView(List.of(unscheduled)),
       conflicts = UnmodifiableListView(List.of(conflicts)),
       explanations = UnmodifiableListView(List.of(explanations));

  final String proposalId;
  final String inputHash;
  final String algorithmVersion;
  final List<PlannedBlock> blocks;
  final List<UnscheduledTask> unscheduled;
  final List<PlanningConflict> conflicts;
  final List<PlanExplanation> explanations;
  final ProposalMetrics metrics;

  /// 生成该提案时使用的一次性规则覆盖（见 `ScheduleRuleOverride`），没有则为 null。
  ///
  /// 必须随提案一起传递，因为确认阶段会重新装配输入并比对 `inputHash`
  /// （`PlanApplicationService.apply`）。若重放时缺少同一个一次性覆盖，
  /// 重新算出的哈希必然与提案不同，一个本来合法的恢复提案会被判为"已过期"而无法应用。
  /// 引擎自身从不设置该字段，它由组合输入的应用层（`PlanningService`）附加。
  final ScheduleRuleOverride? ruleOverride;

  ScheduleProposal withRuleOverride(ScheduleRuleOverride? override) =>
      ScheduleProposal(
        proposalId: proposalId,
        inputHash: inputHash,
        algorithmVersion: algorithmVersion,
        blocks: blocks,
        unscheduled: unscheduled,
        conflicts: conflicts,
        explanations: explanations,
        metrics: metrics,
        ruleOverride: override,
      );
}
