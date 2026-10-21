import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_progress_service.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';
import 'package:personal_planner/domain/models/recurring_completion_evidence.dart';
import 'package:personal_planner/domain/models/recurring_cycle_snapshot.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';

import 'execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftRecurringExecutionRepository repository;
  late RecurringProgressService service;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    repository = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    service = RecurringProgressService(
      repository: repository,
      executionRepository: harness.repository,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    await harness.database.customInsert(
      "INSERT INTO plan_versions "
      '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
      "VALUES ('plan-1', ?, 'hash', '19', 'confirmed', '{}')",
      variables: [
        Variable.withInt(harness.clock.nowUtc().microsecondsSinceEpoch),
      ],
    );
    await harness.seedOccurrence();
  });

  tearDown(() => harness.close());

  Future<ExecutionFragment> insertFragment({
    String id = 'fragment-1',
    String blockId = 'block-1',
    String? cycleId,
    int allocatedMinutes = 50,
    int completedMinutes = 40,
    ExecutionFragmentState state = ExecutionFragmentState.planned,
    int revision = 1,
    String occurrenceId = 'occurrence-1',
    String? rootFragmentId,
    String? sourceFragmentId,
  }) async {
    final start = harness.clock.nowUtc();
    final fragment = ExecutionFragment(
      fragmentId: id,
      dataEpoch: (await harness.repository.ensureRuntimeState()).dataEpoch,
      occurrenceId: occurrenceId,
      cycleId: cycleId,
      rootFragmentId: rootFragmentId ?? rootFragmentIdFor(occurrenceId),
      sourceFragmentId: sourceFragmentId,
      planVersionId: 'plan-1',
      blockId: blockId,
      plannedStartUtc: start,
      plannedEndUtc: start.add(Duration(minutes: allocatedMinutes)),
      plannedMinutes: allocatedMinutes,
      allocatedMicros: allocatedMinutes * 60000000,
      completedMicros: completedMinutes * 60000000,
      state: state,
      createdAtUtc: start,
      completedAtUtc: null,
      revision: revision,
    );
    await repository.insertFragment(fragment);
    return fragment;
  }

  test('50分钟片段已有40分钟真实投入：完成本次只补10分钟声明量', () async {
    await insertFragment();
    final runtime = await harness.repository.ensureRuntimeState();
    final command = CompleteExecutionFragmentCommand(
      operationId: 'op-complete',
      dataEpoch: runtime.dataEpoch,
      fragmentId: 'fragment-1',
      planVersionId: 'plan-1',
      blockId: 'block-1',
      expectedFragmentRevision: 1,
      occurredAtUtc: harness.clock.nowUtc(),
    );
    final result = await service.completeFragment(command);
    expect(result.status, FragmentCommandStatus.applied);
    expect(result.amountMicros, 10 * 60000000);
    final fragment = await repository.findFragment('fragment-1');
    expect(fragment!.state, ExecutionFragmentState.completed);
    expect(fragment.completedMicros, 50 * 60000000);
    final evidence = await repository.evidenceForFragment('fragment-1');
    expect(evidence, hasLength(1));
    expect(evidence.single.amountMicros, 10 * 60000000);
    expect(evidence.single.kind, RecurringEvidenceKind.fragmentCompletion);
    final outbox = await harness.repository.pendingOutbox();
    expect(
      outbox.map((entry) => entry.effectType),
      contains('recurringFragmentCompleted'),
    );
  });

  test('重复提交同一 operationId 只入账一次', () async {
    await insertFragment();
    final runtime = await harness.repository.ensureRuntimeState();
    final command = CompleteExecutionFragmentCommand(
      operationId: 'op-complete',
      dataEpoch: runtime.dataEpoch,
      fragmentId: 'fragment-1',
      planVersionId: 'plan-1',
      blockId: 'block-1',
      expectedFragmentRevision: 1,
      occurredAtUtc: harness.clock.nowUtc(),
    );
    await service.completeFragment(command);
    final replay = await service.completeFragment(command);
    expect(replay.status, FragmentCommandStatus.applied);
    expect(replay.reason, 'idempotentReplay');
    expect(await repository.evidenceForCycle('occurrence-1'), hasLength(1));
  });

  test('三片段中只完成 B，A/C 不变且周期只增加 B 的声明量', () async {
    await insertFragment(id: 'fragment-a', blockId: 'block-a');
    await insertFragment(
      id: 'fragment-b',
      blockId: 'block-b',
      completedMinutes: 0,
    );
    await insertFragment(
      id: 'fragment-c',
      blockId: 'block-c',
      completedMinutes: 40,
    );
    final runtime = await harness.repository.ensureRuntimeState();
    final result = await service.completeFragment(
      CompleteExecutionFragmentCommand(
        operationId: 'op-b',
        dataEpoch: runtime.dataEpoch,
        fragmentId: 'fragment-b',
        planVersionId: 'plan-1',
        blockId: 'block-b',
        expectedFragmentRevision: 1,
        occurredAtUtc: harness.clock.nowUtc(),
      ),
    );
    expect(result.amountMicros, 50 * 60000000);
    for (final id in ['fragment-a', 'fragment-c']) {
      final sibling = await repository.findFragment(id);
      expect(sibling!.state, ExecutionFragmentState.planned);
      expect(sibling.completedMicros, 40 * 60000000);
    }
    final b = await repository.findFragment('fragment-b');
    expect(b!.state, ExecutionFragmentState.completed);
  });

  test('真实投入已覆盖全部承诺时，完成动作只改状态、不再写证据', () async {
    await insertFragment(completedMinutes: 50);
    final runtime = await harness.repository.ensureRuntimeState();
    final result = await service.completeFragment(
      CompleteExecutionFragmentCommand(
        operationId: 'op-covered',
        dataEpoch: runtime.dataEpoch,
        fragmentId: 'fragment-1',
        planVersionId: 'plan-1',
        blockId: 'block-1',
        expectedFragmentRevision: 1,
        occurredAtUtc: harness.clock.nowUtc(),
      ),
    );
    expect(result.status, FragmentCommandStatus.applied);
    expect(result.reason, 'alreadyCoveredByActivity');
    expect(result.amountMicros, 0);
    expect(await repository.evidenceForFragment('fragment-1'), isEmpty);
  });

  test('撤销完成只反转声明证据，不清除真实投入', () async {
    await insertFragment();
    final runtime = await harness.repository.ensureRuntimeState();
    final applied = await service.completeFragment(
      CompleteExecutionFragmentCommand(
        operationId: 'op-complete',
        dataEpoch: runtime.dataEpoch,
        fragmentId: 'fragment-1',
        planVersionId: 'plan-1',
        blockId: 'block-1',
        expectedFragmentRevision: 1,
        occurredAtUtc: harness.clock.nowUtc(),
      ),
    );
    final undone = await service.undoFragmentCompletion(
      UndoFragmentCompletionCommand(
        operationId: 'op-undo',
        dataEpoch: runtime.dataEpoch,
        fragmentId: 'fragment-1',
        expectedFragmentRevision: applied.fragment!.revision,
        occurredAtUtc: harness.clock.nowUtc(),
      ),
    );
    expect(undone.status, FragmentCommandStatus.applied);
    final fragment = await repository.findFragment('fragment-1');
    expect(fragment!.state, ExecutionFragmentState.planned);
    expect(fragment.completedMicros, 40 * 60000000);
    final evidence = await repository.evidenceForFragment('fragment-1');
    expect(evidence, hasLength(2));
    expect(evidence.last.kind, RecurringEvidenceKind.correction);
    expect(await service.effectiveMinutesForCycle('occurrence-1'), 0);
  });

  test('重排产生的旧/新片段独立，完成并撤销新片段不复活旧历史', () async {
    await insertFragment(
      id: 'old-fragment',
      blockId: 'old-block',
      completedMinutes: 40,
    );
    await insertFragment(
      id: 'new-fragment',
      blockId: 'new-block',
      completedMinutes: 0,
      sourceFragmentId: 'old-fragment',
      rootFragmentId: 'root:occurrence-1',
    );
    final runtime = await harness.repository.ensureRuntimeState();
    final applied = await service.completeFragment(
      CompleteExecutionFragmentCommand(
        operationId: 'op-new',
        dataEpoch: runtime.dataEpoch,
        fragmentId: 'new-fragment',
        planVersionId: 'plan-1',
        blockId: 'new-block',
        expectedFragmentRevision: 1,
        occurredAtUtc: harness.clock.nowUtc(),
      ),
    );
    expect(applied.status, FragmentCommandStatus.applied);
    await service.undoFragmentCompletion(
      UndoFragmentCompletionCommand(
        operationId: 'op-new-undo',
        dataEpoch: runtime.dataEpoch,
        fragmentId: 'new-fragment',
        expectedFragmentRevision: applied.fragment!.revision,
        occurredAtUtc: harness.clock.nowUtc(),
      ),
    );
    final old = await repository.findFragment('old-fragment');
    expect(old!.state, ExecutionFragmentState.planned);
    expect(old.completedMicros, 40 * 60000000);
    final updated = await repository.findFragment('new-fragment');
    expect(updated!.completedMicros, 0);
    expect(updated.sourceFragmentId, 'old-fragment');
  });

  test('达到周期目标后快照推导为 met，已结算周不被普通完成改写', () async {
    final start = DateTime.utc(2026, 10, 19);
    await repository.upsertCycleSnapshot(
      RecurringCycleSnapshot(
        cycleId: 'cycle-1',
        templateId: 'template-1',
        transportTaskId: 'task-1',
        periodStartLocalDate: start,
        periodStartUtc: start,
        periodEndUtc: start.add(const Duration(days: 7)),
        effectiveStartUtc: start,
        effectiveEndUtc: start.add(const Duration(days: 7)),
        timeZoneId: 'Asia/Shanghai',
        templateRevision: 1,
        title: '每周阅读',
        notes: '',
        areaId: null,
        projectId: null,
        priority: TaskPriority.medium,
        energyLevel: TaskEnergyLevel.medium,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 25,
        maxChunkMinutes: 90,
        preferredStartMinute: null,
        preferredEndMinute: null,
        pace: RecurringPace.even,
        allowedWeekdaysMask: 0x7F,
        targetMinutes: 50,
        carryInMinutes: 0,
        state: RecurringCycleStatus.open,
        revision: 1,
        createdAtUtc: start,
        updatedAtUtc: start,
        settledAtUtc: null,
      ),
    );
    await insertFragment(cycleId: 'cycle-1');
    final runtime = await harness.repository.ensureRuntimeState();
    await service.completeFragment(
      CompleteExecutionFragmentCommand(
        operationId: 'op-complete',
        dataEpoch: runtime.dataEpoch,
        fragmentId: 'fragment-1',
        planVersionId: 'plan-1',
        blockId: 'block-1',
        expectedFragmentRevision: 1,
        occurredAtUtc: harness.clock.nowUtc(),
      ),
    );
    final snapshot = await repository.findCycleSnapshot('cycle-1');
    expect(snapshot!.state, RecurringCycleStatus.met);
  });
}
