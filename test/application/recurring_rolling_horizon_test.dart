import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_plan_preview_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/recurring_cycle_maintenance_service.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import 'execution/execution_test_support.dart';

final class _Creator implements ProposalCreator {
  _Creator(this.proposal);

  final ScheduleProposal proposal;
  int calls = 0;
  TimeRange? lastWindow;

  @override
  Future<ScheduleProposal> createProposal({
    ScheduleRuleOverride? override,
    TimeRange? window,
  }) async {
    calls++;
    lastWindow = window;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return proposal;
  }
}

void main() {
  late ExecutionTestHarness harness;
  late DriftRecurringExecutionRepository repository;
  late _Creator creator;
  late RecurringCycleMaintenanceService maintenance;
  late PendingPlanPreviewService previews;
  late RecurringTaskService recurring;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    repository = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    await harness.database.customInsert(
      "INSERT INTO plan_versions "
      '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
      "VALUES ('plan-1', ?, 'hash', '20', 'confirmed', '{}')",
      variables: [
        Variable.withInt(harness.clock.nowUtc().microsecondsSinceEpoch),
      ],
    );
    final now = harness.clock.nowUtc();
    final nextMonday = DateTime.utc(2026, 10, 26, 1);
    creator = _Creator(
      ScheduleProposal(
        proposalId: 'lookahead-1',
        inputHash: 'hash',
        algorithmVersion: '20',
        planningWindow: TimeRange(
          startUtc: nextMonday,
          endUtc: nextMonday.add(const Duration(days: 7)),
        ),
        blocks: [
          PlannedBlock(
            id: 'next-block',
            taskId: 'task-1',
            range: TimeRange(
              startUtc: nextMonday,
              endUtc: nextMonday.add(const Duration(minutes: 45)),
            ),
          ),
        ],
        unscheduled: const [],
        conflicts: const [],
        explanations: const [],
        metrics: const ProposalMetrics(
          isFullyFeasible: true,
          scheduledMinutes: 45,
          unscheduledMinutes: 0,
        ),
      ),
    );
    previews = PendingPlanPreviewService(
      repository: repository,
      plans: DriftPlanRepository(harness.database),
      clock: harness.clock,
      idGenerator: harness.ids,
      applyProposal: (_) async => ApplyPlanResult.applied(
        ConfirmedPlan(
          id: 'plan-2',
          inputHash: 'hash',
          algorithmVersion: '20',
          blocks: const [],
        ),
      ),
    );
    recurring = RecurringTaskService(
      repository: DriftRecurringTaskRepository(
        harness.database,
        RecurringTaskDao(harness.database),
      ),
      clock: harness.clock,
      idGenerator: harness.ids,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      snapshots: repository,
    );
    maintenance = RecurringCycleMaintenanceService(
      cycles: recurring,
      previews: previews,
      plans: DriftPlanRepository(harness.database),
      creator: creator,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: harness.clock,
    );
    expect(now.isUtc, isTrue);
  });

  tearDown(() => harness.close());

  test('同一本地周的并发维护只生成一次预排，第二次复用同一 Future', () async {
    final first = maintenance.maintain();
    final second = maintenance.maintain();
    final results = await Future.wait([first, second]);
    expect(creator.calls, 1);
    final zones = TimeZoneDatabase();
    expect(
      creator.lastWindow!.startUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 26), 'Asia/Shanghai'),
    );
    expect(
      creator.lastWindow!.endUtc,
      zones.localMidnightToUtc(DateTime(2026, 11, 2), 'Asia/Shanghai'),
    );
    expect(results[0].preview.preview.previewId, 'lookahead-1');
    expect(results[1].reusedFlight, isTrue);
    expect(results[1].preview.preview.previewId, 'lookahead-1');
    final active = await repository.activePreview(
      PendingPreviewKind.recurringLookahead,
    );
    expect(active!.preview.previewId, 'lookahead-1');
    expect(active.blocks.single.blockId, 'next-block');
  });

  test('信任自动调整只对完整可行预排自动应用', () async {
    final trusted = RecurringCycleMaintenanceService(
      cycles: recurring,
      previews: previews,
      plans: DriftPlanRepository(harness.database),
      creator: creator,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: harness.clock,
      trustAutoAdjust: () => true,
    );
    await trusted.maintain();
    expect(
      await repository.activePreview(PendingPreviewKind.recurringLookahead),
      isNull,
    );
    final preview = await repository.previewById('lookahead-1');
    expect(preview!.status, PendingPreviewStatus.accepted);
  });

  test('尾部合并保留窗口外块、替换窗口内块', () {
    final nextWindow = TimeRange(
      startUtc: DateTime.utc(2026, 10, 12),
      endUtc: DateTime.utc(2026, 10, 19),
    );
    final before = PlannedBlock(
      id: 'before',
      taskId: 'task-1',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 6),
        endUtc: DateTime.utc(2026, 10, 6, 1),
      ),
    );
    final inside = PlannedBlock(
      id: 'inside',
      taskId: 'task-1',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 13),
        endUtc: DateTime.utc(2026, 10, 13, 1),
      ),
    );
    final replacement = PlannedBlock(
      id: 'replacement',
      taskId: 'task-2',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 14),
        endUtc: DateTime.utc(2026, 10, 14, 1),
      ),
    );
    final merged = mergePreviewTailBlocks(
      baseBlocks: [before, inside],
      nextBlocks: [replacement],
      nextWindow: nextWindow,
    );
    expect(merged.map((block) => block.id), ['before', 'replacement']);
  });
}
