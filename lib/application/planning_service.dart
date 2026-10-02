import 'dart:isolate';

import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

abstract interface class ScheduleProblemSource {
  Future<ScheduleProblem> load();
}

abstract interface class ProposalCreator {
  Future<ScheduleProposal> createProposal();
}

final class PlanningService implements ProposalCreator {
  PlanningService({
    required this.source,
    required this.engine,
    this.snapshots = const InputSnapshotBuilder(),
  });

  final ScheduleProblemSource source;
  final ScheduleEngine engine;
  final InputSnapshotBuilder snapshots;
  final Map<String, ScheduleProposal> _previews = {};

  @override
  Future<ScheduleProposal> createProposal() async {
    final rawProblem = await source.load();
    final inputHash = snapshots.hash(InputSnapshot(problem: rawProblem));
    final problem = _withInputHash(rawProblem, inputHash);
    final proposal = await Isolate.run(() {
      TimeZoneDatabase();
      return engine.generate(problem);
    });
    _previews[proposal.proposalId] = proposal;
    return proposal;
  }

  ScheduleProposal? preview(String proposalId) => _previews[proposalId];
}

ScheduleProblem withCurrentInputHash(
  ScheduleProblem problem,
  InputSnapshotBuilder snapshots,
) => _withInputHash(problem, snapshots.hash(InputSnapshot(problem: problem)));

ScheduleProblem _withInputHash(ScheduleProblem problem, String inputHash) =>
    ScheduleProblem(
      planningWindow: problem.planningWindow,
      timeZoneId: problem.timeZoneId,
      tasks: problem.tasks,
      fixedIntervals: problem.fixedIntervals,
      protectedIntervals: problem.protectedIntervals,
      lockedBlocks: problem.lockedBlocks,
      existingBlocks: problem.existingBlocks,
      rules: problem.rules,
      preferences: problem.preferences,
      inputHash: inputHash,
    );
