import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/execution/execution_plan_linker.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import 'execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
  });

  tearDown(() => harness.close());

  Future<void> insertPlanVersion(String id, String status) async {
    await harness.database.customInsert(
      'INSERT INTO plan_versions '
      '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
      "VALUES (?, ?, 'hash', '19', ?, '{}')",
      variables: [
        Variable.withString(id),
        Variable.withInt(harness.clock.nowUtc().microsecondsSinceEpoch),
        Variable.withString(status),
      ],
    );
  }

  Future<ExecutionOccurrence> seedOccurrence({
    required String planVersionId,
    required DateTime baselineStartUtc,
  }) async {
    final occurrence = ExecutionOccurrence(
      id: 'occurrence-1',
      taskId: 'task-1',
      originPlanVersionId: planVersionId,
      originBlockId: 'prev-block',
      baselineStartUtc: baselineStartUtc,
      baselineEndUtc: baselineStartUtc.add(const Duration(minutes: 45)),
      baselineTimeZoneId: 'Asia/Shanghai',
      baselineLocalDate: '2026-10-19',
      baselinePlannedDurationMicros: 45 * 60 * 1000000,
      currentPlanVersionId: planVersionId,
      allocatedMicros: 45 * 60 * 1000000,
      remainingAllocationMicros: 45 * 60 * 1000000,
      firstStartEvidenceId: null,
      withdrawalReason: null,
      withdrawnAtUtc: null,
      lifecycleState: ExecutionLifecycleState.planned,
      privacyState: ExecutionPrivacyState.linked,
      createdAtUtc: harness.clock.nowUtc(),
      revision: 1,
    );
    await harness.repository.insertOccurrence(occurrence);
    final runtime = await harness.repository.ensureRuntimeState();
    await harness.repository.insertBlockLink(
      dataEpoch: runtime.dataEpoch,
      planVersionId: planVersionId,
      blockId: 'prev-block',
      occurrenceId: occurrence.id,
      sourceBlockId: null,
      reservedMicros: 45 * 60 * 1000000,
    );
    return occurrence;
  }

  ScheduleProposal emptyProposal() => ScheduleProposal(
    proposalId: 'new-plan',
    inputHash: 'hash',
    algorithmVersion: '19',
    planningWindow: TimeRange(
      startUtc: harness.clock.nowUtc(),
      endUtc: harness.clock.nowUtc().add(const Duration(days: 7)),
    ),
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

  test('到点前被移出计划的实例记为提前撤回，旧承诺保留为历史', () async {
    await insertPlanVersion('prev-plan', 'superseded');
    await insertPlanVersion('new-plan', 'confirmed');
    await seedOccurrence(
      planVersionId: 'prev-plan',
      baselineStartUtc: harness.clock.nowUtc().add(const Duration(hours: 2)),
    );
    final linker = ExecutionPlanLinker(
      repository: harness.repository,
      zones: TimeZoneDatabase(),
      idGenerator: harness.ids,
      clock: harness.clock,
    );
    await linker.linkAppliedPlan(
      plan: ConfirmedPlan(
        id: 'new-plan',
        inputHash: 'hash',
        algorithmVersion: '19',
        blocks: const [],
      ),
      proposal: emptyProposal(),
      timeZoneId: 'Asia/Shanghai',
    );

    final occurrence = await harness.repository.findOccurrence('occurrence-1');
    expect(occurrence!.lifecycleState, ExecutionLifecycleState.withdrawn);
    expect(occurrence.withdrawalReason, 'rescheduledBeforeStart');
    expect(occurrence.remainingAllocationMicros, 0);
    final events = await harness.database
        .customSelect(
          "SELECT event_type FROM execution_events WHERE occurrence_id = ?",
          variables: [Variable.withString('occurrence-1')],
        )
        .get();
    expect(events.map((row) => row.read<String>('event_type')), ['withdrawn']);
  });

  test('到点后从计划里消失的实例不按提前取消豁免', () async {
    await insertPlanVersion('prev-plan', 'superseded');
    await insertPlanVersion('new-plan', 'confirmed');
    await seedOccurrence(
      planVersionId: 'prev-plan',
      baselineStartUtc: harness.clock.nowUtc().subtract(
        const Duration(minutes: 30),
      ),
    );
    final linker = ExecutionPlanLinker(
      repository: harness.repository,
      zones: TimeZoneDatabase(),
      idGenerator: harness.ids,
      clock: harness.clock,
    );
    await linker.linkAppliedPlan(
      plan: ConfirmedPlan(
        id: 'new-plan',
        inputHash: 'hash',
        algorithmVersion: '19',
        blocks: const [],
      ),
      proposal: emptyProposal(),
      timeZoneId: 'Asia/Shanghai',
    );

    final occurrence = await harness.repository.findOccurrence('occurrence-1');
    expect(occurrence!.lifecycleState, ExecutionLifecycleState.planned);
    expect(occurrence.withdrawalReason, isNull);
  });

  test('已经发生实际启动的实例不能被改写成提前撤回', () async {
    await insertPlanVersion('prev-plan', 'superseded');
    await insertPlanVersion('new-plan', 'confirmed');
    final seeded = await seedOccurrence(
      planVersionId: 'prev-plan',
      baselineStartUtc: harness.clock.nowUtc().add(const Duration(hours: 2)),
    );
    await harness.repository.updateOccurrence(
      seeded.copyWith(
        firstStartEvidenceId: 'evt-started',
        lifecycleState: ExecutionLifecycleState.started,
        revision: 2,
      ),
    );
    final linker = ExecutionPlanLinker(
      repository: harness.repository,
      zones: TimeZoneDatabase(),
      idGenerator: harness.ids,
      clock: harness.clock,
    );
    await linker.linkAppliedPlan(
      plan: ConfirmedPlan(
        id: 'new-plan',
        inputHash: 'hash',
        algorithmVersion: '19',
        blocks: const [],
      ),
      proposal: emptyProposal(),
      timeZoneId: 'Asia/Shanghai',
    );

    final occurrence = await harness.repository.findOccurrence('occurrence-1');
    expect(occurrence!.lifecycleState, ExecutionLifecycleState.started);
    expect(occurrence.firstStartEvidenceId, 'evt-started');
    expect(occurrence.withdrawalReason, isNull);
  });

  test('应用计划时为每个可见块建立独立 fragment 并写入 cycleId', () async {
    await insertPlanVersion('prev-plan', 'superseded');
    await insertPlanVersion('new-plan', 'confirmed');
    await seedOccurrence(
      planVersionId: 'prev-plan',
      baselineStartUtc: harness.clock.nowUtc().subtract(
        const Duration(minutes: 30),
      ),
    );
    final start = harness.clock.nowUtc().add(const Duration(hours: 3));
    final block = PlannedBlock(
      id: 'block-1',
      taskId: 'task-1',
      range: TimeRange(
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 45)),
      ),
    );
    final recurring = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final linker = ExecutionPlanLinker(
      repository: harness.repository,
      zones: TimeZoneDatabase(),
      idGenerator: harness.ids,
      clock: harness.clock,
      recurringRepository: recurring,
      cycleIdForTask: (_) async => 'cycle-1',
    );
    await linker.linkAppliedPlan(
      plan: ConfirmedPlan(
        id: 'new-plan',
        inputHash: 'hash',
        algorithmVersion: '19',
        blocks: [block],
      ),
      proposal: ScheduleProposal(
        proposalId: 'new-plan',
        inputHash: 'hash',
        algorithmVersion: '19',
        planningWindow: TimeRange(
          startUtc: harness.clock.nowUtc(),
          endUtc: harness.clock.nowUtc().add(const Duration(days: 7)),
        ),
        blocks: [block],
        unscheduled: const [],
        conflicts: const [],
        explanations: const [],
        metrics: const ProposalMetrics(
          isFullyFeasible: true,
          scheduledMinutes: 45,
          unscheduledMinutes: 0,
        ),
      ),
      timeZoneId: 'Asia/Shanghai',
    );

    final fragment = await recurring.findFragmentForBlock(
      planVersionId: 'new-plan',
      blockId: 'block-1',
    );
    expect(fragment, isNotNull);
    expect(fragment!.cycleId, 'cycle-1');
    expect(fragment.allocatedMicros, 45 * 60000000);
    expect(
      await harness.repository.fragmentIdForBlock(
        planVersionId: 'new-plan',
        blockId: 'block-1',
      ),
      fragment.fragmentId,
    );
  });

  test('回填缺少块时间时写复核 outbox，而不是静默跳过', () async {
    await insertPlanVersion('plan-1', 'confirmed');
    await seedOccurrence(
      planVersionId: 'plan-1',
      baselineStartUtc: harness.clock.nowUtc().add(const Duration(hours: 2)),
    );
    final recurringRepository = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final linker = ExecutionPlanLinker(
      repository: harness.repository,
      zones: TimeZoneDatabase(),
      idGenerator: harness.ids,
      clock: harness.clock,
      recurringRepository: recurringRepository,
    );
    expect(await linker.backfillFragments('plan-1'), 0);
    final outbox = await harness.repository.pendingOutbox();
    expect(
      outbox.any((entry) => entry.effectType == 'recurringBackfillAmbiguous'),
      true,
    );
  });
}
