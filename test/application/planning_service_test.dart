import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  const snapshots = InputSnapshotBuilder();

  test('snapshot hash ignores UI state and normalizes input list order', () {
    final problem = _problem(requiredMinutes: 60);
    final reversed = ScheduleProblem(
      planningWindow: problem.planningWindow,
      timeZoneId: problem.timeZoneId,
      tasks: problem.tasks.reversed.toList(),
      fixedIntervals: problem.fixedIntervals.reversed.toList(),
      protectedIntervals: problem.protectedIntervals.reversed.toList(),
      lockedBlocks: problem.lockedBlocks.reversed.toList(),
      rules: problem.rules,
      preferences: problem.preferences,
      inputHash: 'ignored-too',
    );

    final first = snapshots.hash(
      InputSnapshot(problem: problem, uiState: const {'selectedTab': 0}),
    );
    final second = snapshots.hash(
      InputSnapshot(problem: reversed, uiState: const {'selectedTab': 3}),
    );

    expect(first, second);
    expect(first, hasLength(64));
  });

  test(
    'changed task makes a preview stale without changing current plan',
    () async {
      final source = _MutableProblemSource(_problem(requiredMinutes: 60));
      final repository = _MemoryPlanRepository(currentId: 'existing-plan');
      final planning = PlanningService(
        source: source,
        engine: DeterministicScheduleEngine(TimeZoneDatabase()),
        snapshots: snapshots,
      );
      final application = PlanApplicationService(
        source: source,
        repository: repository,
        snapshots: snapshots,
        zones: TimeZoneDatabase(),
      );
      final proposal = await planning.createProposal();
      source.problem = _problem(requiredMinutes: 120);

      final result = await application.apply(proposal);

      expect(result.status, ApplyPlanStatus.staleProposal);
      expect(repository.applyCalls, 0);
      expect((await repository.current())?.id, 'existing-plan');
    },
  );
}

ScheduleProblem _problem({required int requiredMinutes}) {
  final day = DateTime.utc(2026, 10, 5);
  return ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    ),
    timeZoneId: 'UTC',
    tasks: [
      SchedulableTask(
        id: 'task',
        requiredMinutes: requiredMinutes,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 60,
      ),
    ],
    fixedIntervals: [
      BusyInterval(
        id: 'class',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 10)),
          endUtc: day.add(const Duration(hours: 11)),
        ),
      ),
    ],
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: DefaultSettings.v1(),
    preferences: const PreferenceProfile(),
    inputHash: 'not-part-of-snapshot',
  );
}

final class _MutableProblemSource implements ScheduleProblemSource {
  _MutableProblemSource(this.problem);
  ScheduleProblem problem;
  @override
  Future<ScheduleProblem> load() async => problem;
}

final class _MemoryPlanRepository implements PlanRepository {
  _MemoryPlanRepository({String? currentId})
    : _current = currentId == null
          ? null
          : ConfirmedPlan(
              id: currentId,
              inputHash: 'old-hash',
              algorithmVersion: '1',
              blocks: const [],
            );

  ConfirmedPlan? _current;
  int applyCalls = 0;

  @override
  Future<ConfirmedPlan?> current() async => _current;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async {
    applyCalls++;
    _current = ConfirmedPlan(
      id: proposal.proposalId,
      inputHash: proposal.inputHash,
      algorithmVersion: proposal.algorithmVersion,
      blocks: proposal.blocks,
    );
    return ApplyPlanResult.applied(_current!);
  }
}
