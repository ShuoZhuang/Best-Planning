import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  late AppDatabase database;
  late DriftPlanRepository repository;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftPlanRepository(
      database,
      clock: _FixedClock(DateTime.utc(2026, 10, 5, 8)),
    );
    await database.customInsert("""
      INSERT INTO tasks (
        id, title, notes, priority, estimated_minutes, remaining_minutes,
        energy_level, split_mode, min_chunk_minutes, max_chunk_minutes,
        status, created_at_utc, updated_at_utc
      ) VALUES (
        'task', 'Task', '', 'medium', 180, 180,
        'medium', 'splittable', 30, 60, 'open', 1, 1
      )
      """);
  });

  tearDown(() => database.close());

  test(
    'third block failure rolls back plan, blocks, log and supersede',
    () async {
      await database.customInsert("""
      INSERT INTO plan_versions
        (id, created_at_utc, input_hash, algorithm_version, status, summary_json)
      VALUES ('existing', 1, 'old', '1', 'confirmed', '{}')
      """);
      await database.customStatement("""
      CREATE TRIGGER fail_third_block
      BEFORE INSERT ON schedule_blocks
      WHEN (
        SELECT COUNT(*) FROM schedule_blocks
        WHERE plan_version_id = NEW.plan_version_id
      ) = 2
      BEGIN
        SELECT RAISE(ABORT, 'simulated third block failure');
      END
      """);

      await expectLater(
        repository.applyProposal(_proposal(), 'snapshot-hash'),
        throwsA(anything),
      );

      expect(await database.select(database.planVersions).get(), hasLength(1));
      expect((await repository.current())?.id, 'existing');
      expect(await database.select(database.scheduleBlocks).get(), isEmpty);
      expect(await database.select(database.changeLog).get(), isEmpty);
    },
  );

  test(
    'successful apply stores one confirmed version, blocks and log',
    () async {
      final result = await repository.applyProposal(
        _proposal(),
        'snapshot-hash',
      );

      expect(result.status, ApplyPlanStatus.applied);
      expect(result.plan?.blocks, hasLength(3));
      expect(await database.select(database.planVersions).get(), hasLength(1));
      expect(
        await database.select(database.scheduleBlocks).get(),
        hasLength(3),
      );
      expect(await database.select(database.changeLog).get(), hasLength(4));
    },
  );

  test('application service revalidates blocks before transaction', () async {
    const snapshots = InputSnapshotBuilder();
    final problem = _validationProblem();
    final hash = snapshots.hash(InputSnapshot(problem: problem));
    final proposal = ScheduleProposal(
      proposalId: 'invalid-proposal',
      inputHash: hash,
      algorithmVersion: '1',
      blocks: [
        PlannedBlock(
          id: 'one',
          taskId: 'task',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 5, 9),
            endUtc: DateTime.utc(2026, 10, 5, 10),
          ),
        ),
        PlannedBlock(
          id: 'two',
          taskId: 'task',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 5, 9, 30),
            endUtc: DateTime.utc(2026, 10, 5, 10, 30),
          ),
        ),
      ],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 120,
        unscheduledMinutes: 0,
      ),
    );
    final service = PlanApplicationService(
      source: _ProblemSource(problem),
      repository: repository,
      zones: TimeZoneDatabase(),
      snapshots: snapshots,
    );

    final result = await service.apply(proposal);

    expect(result.status, ApplyPlanStatus.invalidProposal);
    expect(await database.select(database.planVersions).get(), isEmpty);
  });
}

ScheduleProposal _proposal() {
  final start = DateTime.utc(2026, 10, 5, 9);
  final blocks = [
    for (var index = 0; index < 3; index++)
      PlannedBlock(
        id: 'block-$index',
        taskId: 'task',
        range: TimeRange(
          startUtc: start.add(Duration(hours: index)),
          endUtc: start.add(Duration(hours: index + 1)),
        ),
        explanationCode: 'priority',
      ),
  ];
  return ScheduleProposal(
    proposalId: 'proposal-1',
    inputHash: 'snapshot-hash',
    algorithmVersion: '1',
    blocks: blocks,
    unscheduled: const [],
    conflicts: const [],
    explanations: const [],
    metrics: const ProposalMetrics(
      isFullyFeasible: true,
      scheduledMinutes: 180,
      unscheduledMinutes: 0,
    ),
  );
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

ScheduleProblem _validationProblem() {
  final day = DateTime.utc(2026, 10, 5);
  return ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    ),
    timeZoneId: 'UTC',
    tasks: const [
      SchedulableTask(
        id: 'task',
        requiredMinutes: 180,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
      ),
    ],
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: DefaultSettings.v1(),
    preferences: const PreferenceProfile(),
    inputHash: 'ignored',
  );
}

final class _ProblemSource implements ScheduleProblemSource {
  const _ProblemSource(this.problem);
  final ScheduleProblem problem;
  @override
  Future<ScheduleProblem> load() async => problem;
}
