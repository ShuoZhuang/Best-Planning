import 'dart:collection';

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
}
