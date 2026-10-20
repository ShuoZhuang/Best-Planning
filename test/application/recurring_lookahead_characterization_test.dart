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
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import 'execution/execution_test_support.dart';

final class _Creator implements ProposalCreator {
  _Creator(this.proposal);
  final ScheduleProposal proposal;
  TimeRange? lastWindow;

  @override
  Future<ScheduleProposal> createProposal({
    ScheduleRuleOverride? override,
    TimeRange? window,
  }) async {
    lastWindow = window;
    return proposal;
  }
}

void main() {
  test('维护明确请求下一完整周窗口并持久化预排', () async {
    final harness = await ExecutionTestHarness.create();
    addTearDown(harness.close);
    final repository = DriftRecurringExecutionRepository(
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
    final nextMonday = DateTime.utc(2026, 10, 26, 1);
    final creator = _Creator(
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
    final previews = PendingPlanPreviewService(
      repository: repository,
      plans: DriftPlanRepository(harness.database),
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final recurring = RecurringTaskService(
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
    final maintenance = RecurringCycleMaintenanceService(
      cycles: recurring,
      previews: previews,
      plans: DriftPlanRepository(harness.database),
      creator: creator,
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: harness.clock,
    );
    await maintenance.maintain();
    final zones = TimeZoneDatabase();
    expect(
      creator.lastWindow!.startUtc,
      zones.localMidnightToUtc(DateTime(2026, 10, 26), 'Asia/Shanghai'),
    );
    expect(
      creator.lastWindow!.endUtc,
      zones.localMidnightToUtc(DateTime(2026, 11, 2), 'Asia/Shanghai'),
    );
    final active = await repository.activePreview(
      PendingPreviewKind.recurringLookahead,
    );
    expect(active, isNotNull);
    expect(active!.preview.previewId, 'lookahead-1');
  });
}
