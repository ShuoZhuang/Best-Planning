import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/preference_evidence_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide DayException;
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/preference_evidence_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';

import '../support/daily_policies.dart';

final _zones = TimeZoneDatabase();
const _zone = 'UTC';
final _day = DateTime.utc(2026, 10, 5);

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;

  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  int _next = 0;
  @override
  String next() => 'evidence-${_next++}';
}

final class _MemoryEvidence implements PreferenceEvidenceRepository {
  final List<PreferenceEvidence> rows = [];

  @override
  Future<void> save(PreferenceEvidence evidence) async => rows.add(evidence);

  @override
  Future<List<PreferenceEvidence>> since(DateTime sinceUtc) async =>
      rows.where((row) => !row.observedAtUtc.isBefore(sinceUtc)).toList();
}

final class _Source implements ScheduleProblemSource {
  _Source(this.problem);
  final ScheduleProblem problem;

  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async =>
      problem;
}

ScheduleProblem _problem() {
  final rules = DefaultSettings.v1();
  final window = TimeRange(
    startUtc: _day,
    endUtc: _day.add(const Duration(days: 1)),
  );
  final oldBlock = PlannedBlock(
    id: 'old-block',
    taskId: 'task',
    range: TimeRange(
      startUtc: DateTime.utc(2026, 10, 5, 9),
      endUtc: DateTime.utc(2026, 10, 5, 10),
    ),
  );
  return ScheduleProblem(
    planningWindow: window,
    timeZoneId: _zone,
    tasks: const [
      SchedulableTask(
        id: 'task',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 60,
      ),
    ],
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: const [],
    existingBlocks: [oldBlock],
    confirmedBlocks: [oldBlock],
    rules: rules,
    dailyPolicies: dailyPoliciesForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: _zone,
    ),
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: _zone,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'manual-move',
  );
}

ScheduleProposal _proposal(String inputHash) => ScheduleProposal(
  proposalId: 'manual-move-proposal',
  inputHash: inputHash,
  algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
  planningWindow: TimeRange(
    startUtc: _day,
    endUtc: _day.add(const Duration(days: 1)),
  ),
  blocks: [
    PlannedBlock(
      id: 'new-block',
      taskId: 'task',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 5, 10),
        endUtc: DateTime.utc(2026, 10, 5, 11),
      ),
      continuedFromId: 'old-block',
    ),
  ],
  unscheduled: const [],
  conflicts: const [],
  explanations: const [],
  metrics: const ProposalMetrics(
    isFullyFeasible: true,
    scheduledMinutes: 60,
    unscheduledMinutes: 0,
  ),
);

void main() {
  test('计划应用成功后才写手动移动证据，并归到任务领域', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customInsert("""
      INSERT INTO tasks (
        id, title, notes, priority, estimated_minutes, remaining_minutes,
        energy_level, split_mode, min_chunk_minutes, max_chunk_minutes,
        status, created_at_utc, updated_at_utc
      ) VALUES (
        'task', 'Task', '', 'medium', 60, 60,
        'medium', 'splittable', 30, 60, 'open', 1, 1
      )
      """);
    final evidence = _MemoryEvidence();
    final service = PlanApplicationService(
      source: _Source(_problem()),
      repository: DriftPlanRepository(
        database,
        clock: _FixedClock(DateTime.utc(2026, 10, 5, 8)),
      ),
      zones: _zones,
      preferenceEvidence: PreferenceEvidenceService(
        evidence: evidence,
        clock: _FixedClock(DateTime.utc(2026, 10, 5, 12)),
        zones: _zones,
        timeZoneId: _zone,
        idGenerator: _Ids(),
      ),
      areaIdForTask: (taskId) async => 'study',
    );

    final proposal = _proposal(
      const InputSnapshotBuilder().hash(InputSnapshot(problem: _problem())),
    );
    final result = await service.apply(proposal);
    expect(result.status.name, 'applied');
    expect(evidence.rows, hasLength(1));
    final move = evidence.rows.single;
    expect(move.kind, PreferenceEvidenceKind.manualMove);
    expect(move.subjectKey, 'area:study');
    expect(move.metadata['evidenceVersion'], 2);
    expect(move.metadata['fromMinute'], 9 * 60);
    expect(move.metadata['toMinute'], 10 * 60);
  });

  testWidgets('移动预览页确认经路由应用，移动证据只写一次且重载仍在', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customInsert("""
      INSERT INTO tasks (
        id, title, notes, priority, estimated_minutes, remaining_minutes,
        energy_level, split_mode, min_chunk_minutes, max_chunk_minutes,
        status, created_at_utc, updated_at_utc
      ) VALUES (
        'task', 'Task', '', 'medium', 60, 60,
        'medium', 'splittable', 30, 60, 'open', 1, 1
      )
      """);
    final evidence = _MemoryEvidence();
    final service = PlanApplicationService(
      source: _Source(_problem()),
      repository: DriftPlanRepository(
        database,
        clock: _FixedClock(DateTime.utc(2026, 10, 5, 8)),
      ),
      zones: _zones,
      preferenceEvidence: PreferenceEvidenceService(
        evidence: evidence,
        clock: _FixedClock(DateTime.utc(2026, 10, 5, 12)),
        zones: _zones,
        timeZoneId: _zone,
        idGenerator: _Ids(),
      ),
      areaIdForTask: (taskId) async => 'study',
    );
    final proposal = _proposal(
      const InputSnapshotBuilder().hash(InputSnapshot(problem: _problem())),
    );
    final router = GoRouter(
      initialLocation: '/preview',
      routes: [
        GoRoute(
          path: '/preview',
          builder: (context, state) => PlanPreviewPage(
            model: PlanPreviewModel(
              proposalId: proposal.proposalId,
              changes: const [],
              issues: const [],
              isStale: false,
            ),
            autoAdjustStore: MemoryAutoAdjustStore(),
            zones: _zones,
            timeZoneId: _zone,
            onConfirm: (mode) async => service.apply(proposal, mode: mode),
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(await database.select(database.planVersions).get(), isEmpty);
    expect(evidence.rows, isEmpty);
    await tester.tap(find.text('确认应用'));
    await tester.pumpAndSettle();

    expect(evidence.rows, hasLength(1));
    expect(evidence.rows.single.kind, PreferenceEvidenceKind.manualMove);
    expect(await database.select(database.planVersions).get(), hasLength(1));

    await tester.pumpWidget(const MaterialApp(home: Text('reloaded')));
    expect(await database.select(database.planVersions).get(), hasLength(1));
    expect(evidence.rows, hasLength(1));
  });
}
