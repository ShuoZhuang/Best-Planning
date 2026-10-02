import 'dart:collection';

import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

enum ApplyPlanStatus { applied, staleProposal, invalidProposal }

final class ConfirmedPlan {
  ConfirmedPlan({
    required this.id,
    required this.inputHash,
    required this.algorithmVersion,
    required List<PlannedBlock> blocks,
  }) : blocks = UnmodifiableListView(List.of(blocks));

  final String id;
  final String inputHash;
  final String algorithmVersion;
  final List<PlannedBlock> blocks;
}

final class ApplyPlanResult {
  ApplyPlanResult._({
    required this.status,
    this.plan,
    List<PlanningConflict> conflicts = const [],
  }) : conflicts = UnmodifiableListView(List.of(conflicts));

  factory ApplyPlanResult.applied(ConfirmedPlan plan) =>
      ApplyPlanResult._(status: ApplyPlanStatus.applied, plan: plan);

  factory ApplyPlanResult.stale() =>
      ApplyPlanResult._(status: ApplyPlanStatus.staleProposal);

  factory ApplyPlanResult.invalid(List<PlanningConflict> conflicts) =>
      ApplyPlanResult._(
        status: ApplyPlanStatus.invalidProposal,
        conflicts: conflicts,
      );

  final ApplyPlanStatus status;
  final ConfirmedPlan? plan;
  final List<PlanningConflict> conflicts;
}

abstract interface class PlanRepository {
  Future<ConfirmedPlan?> current();

  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  );
}

abstract interface class PlanHistoryRepository {
  Future<ConfirmedPlan?> current();

  Future<ConfirmedPlan?> previous();

  Future<ConfirmedPlan> restoreAsNewVersion({
    required ConfirmedPlan source,
    required ConfirmedPlan replaced,
  });
}
