import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/execution/execution_commands.dart';
import 'package:personal_planner/application/execution/execution_input_hashes.dart';
import 'package:personal_planner/application/execution/execution_plan_linker.dart';
import 'package:personal_planner/application/execution/execution_recovery_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart'
    show PlanApplyMode;
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../../support/daily_policies.dart';
import 'execution_test_support.dart';

final class _FixedSource implements ScheduleProblemSource {
  _FixedSource(this.problem);

  final ScheduleProblem problem;

  @override
  Future<ScheduleProblem> load({
    ScheduleRuleOverride? override,
    TimeRange? window,
  }) async => problem;
}

void main() {
  late ExecutionTestHarness harness;
  late TimeZoneDatabase zones;
  late ScheduleProblem problem;
  late DriftExecutionRecoveryService service;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    zones = TimeZoneDatabase();
    final window = TimeRange(
      startUtc: harness.clock.nowUtc(),
      endUtc: harness.clock.nowUtc().add(const Duration(days: 7)),
    );
    final rules = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 23 * 60, endMinute: 7 * 60),
      minimumSleepMinutes: 300,
      defaultFocusMinutes: 45,
      breakMinutes: 5,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
      minChunkMinutes: 25,
      maxChunkMinutes: 90,
    );
    problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: 'Asia/Shanghai',
      tasks: [
        SchedulableTask(
          id: 'task-1',
          requiredMinutes: 45,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 25,
          maxChunkMinutes: 90,
          availableFromUtc: harness.clock.nowUtc(),
        ),
      ],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: rules,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: window,
        rules: rules,
        timeZoneId: 'Asia/Shanghai',
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: rules,
        timeZoneId: 'Asia/Shanghai',
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'hash',
    );
    await harness.database.customInsert(
      'INSERT INTO plan_versions '
      '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
      "VALUES ('plan-1', ?, 'hash', '19', 'confirmed', '{}')",
      variables: [
        Variable.withInt(harness.clock.nowUtc().microsecondsSinceEpoch),
      ],
    );
    final planRepository = DriftPlanRepository(harness.database);
    service = DriftExecutionRecoveryService(
      repository: harness.repository,
      tasks: harness.taskRepository,
      plans: planRepository,
      baseSource: _FixedSource(problem),
      engine: DeterministicScheduleEngine(zones),
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
      clock: harness.clock,
      idGenerator: harness.ids,
      linker: ExecutionPlanLinker(
        repository: harness.repository,
        zones: zones,
        idGenerator: harness.ids,
        clock: harness.clock,
      ),
    );
  });

  tearDown(() => harness.close());

  test('真实引擎生成恢复预览并原子应用，实例份额被重新预留', () async {
    final occurrence = await harness.seedOccurrence(
      allocatedMinutes: 45,
      remainingMinutes: 45,
      baselineStartUtc: harness.clock.nowUtc(),
    );
    final task = await harness.taskRepository.getById('task-1');
    final command = RequestExecutionRecoveryCommand(
      operationId: 'op-request',
      dataEpoch: 'epoch',
      occurrenceId: occurrence.id,
      notBeforeUtc: harness.clock.nowUtc(),
      occurrenceRevision: occurrence.revision,
      planVersionId: 'plan-1',
      taskInputHash: executionTaskInputHash(task!),
      progressAnchorRevision: 0,
      processEpoch: service.processEpoch,
    );

    final draftResult = await service.requestRecovery(command);
    expect(draftResult.result.status, ExecutionResultStatus.applied);
    expect(draftResult.draft, isNotNull);
    expect(draftResult.draft!.preview.blocks, isNotEmpty);

    final draft = draftResult.draft!;
    final applied = await service.applyRecovery(
      ApplyExecutionRecoveryCommand(
        operationId: 'op-apply',
        dataEpoch: 'epoch',
        draftId: draft.draftId,
        proposalId: draft.proposalId,
        inputHash: draft.inputHash,
        processEpoch: draft.processEpoch,
        occurrenceRevision: 1,
        planVersionId: 'plan-1',
        taskInputHash: executionTaskInputHash(task),
        progressAnchorRevision: 0,
      ),
    );
    expect(applied.status, ExecutionResultStatus.applied);

    final plan = await DriftPlanRepository(harness.database).current();
    expect(plan, isNotNull);
    expect(plan!.blocks, isNotEmpty);
    final updated = await harness.repository.findOccurrence(occurrence.id);
    expect(updated!.currentPlanVersionId, plan.id);
    expect(updated.remainingAllocationMicros, greaterThan(0));
    expect(service.openDraftCount, 0);
  });

  Future<ExecutionRecoveryDraftResult> requestDraft({
    String operationId = 'op-request',
    bool holdToday = false,
  }) async {
    final occurrence = await harness.seedOccurrence(
      baselineStartUtc: harness.clock.nowUtc(),
    );
    final task = await harness.taskRepository.getById('task-1');
    return service.requestRecovery(
      RequestExecutionRecoveryCommand(
        operationId: operationId,
        dataEpoch: 'epoch',
        occurrenceId: occurrence.id,
        notBeforeUtc: harness.clock.nowUtc(),
        holdToday: holdToday,
        occurrenceRevision: occurrence.revision,
        planVersionId: 'plan-1',
        taskInputHash: executionTaskInputHash(task!),
        progressAnchorRevision: 0,
        processEpoch: service.processEpoch,
      ),
    );
  }

  test('取消预览不写计划，也不留下下一次生成可读的草案', () async {
    final before = await DriftPlanRepository(harness.database).current();
    final draft = (await requestDraft()).draft!;
    final cancelled = await service.cancelRecovery(
      CancelExecutionRecoveryCommand(
        operationId: 'op-cancel',
        dataEpoch: 'epoch',
        draftId: draft.draftId,
        draftRevision: draft.revision,
        processEpoch: draft.processEpoch,
      ),
    );
    expect(cancelled.status, ExecutionResultStatus.applied);
    expect(service.openDraftCount, 0);
    final after = await DriftPlanRepository(harness.database).current();
    expect(after!.id, before!.id);
    final plans = await harness.database
        .customSelect('SELECT COUNT(*) AS c FROM plan_versions')
        .getSingle();
    expect(plans.read<int>('c'), 1);
  });

  test('预览期间任务进度变化使旧提案 stale，不写计划', () async {
    final draft = (await requestDraft()).draft!;
    final task = await harness.taskRepository.getById('task-1');
    await harness.taskRepository.save(
      task!.copyWith(
        remainingMinutes: 30,
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );
    final applied = await service.applyRecovery(
      ApplyExecutionRecoveryCommand(
        operationId: 'op-apply',
        dataEpoch: 'epoch',
        draftId: draft.draftId,
        proposalId: draft.proposalId,
        inputHash: draft.inputHash,
        processEpoch: draft.processEpoch,
        occurrenceRevision: 1,
        planVersionId: 'plan-1',
        taskInputHash: executionTaskInputHash(task),
        progressAnchorRevision: 0,
      ),
    );
    expect(applied.status, ExecutionResultStatus.stale);
    final plans = await harness.database
        .customSelect('SELECT COUNT(*) AS c FROM plan_versions')
        .getSingle();
    expect(plans.read<int>('c'), 1);
  });

  test('确认"今天不再安排"时只在应用事务里写入精确失效边界', () async {
    final draft = (await requestDraft(holdToday: true)).draft!;
    final applied = await service.applyRecovery(
      ApplyExecutionRecoveryCommand(
        operationId: 'op-apply',
        dataEpoch: 'epoch',
        draftId: draft.draftId,
        proposalId: draft.proposalId,
        inputHash: draft.inputHash,
        processEpoch: draft.processEpoch,
        occurrenceRevision: 1,
        planVersionId: 'plan-1',
        taskInputHash: executionTaskInputHash(
          (await harness.taskRepository.getById('task-1'))!,
        ),
        progressAnchorRevision: 0,
      ),
    );
    expect(applied.status, ExecutionResultStatus.applied);
    final holds = await harness.database
        .customSelect(
          'SELECT local_date, invalid_after_utc FROM execution_day_holds',
        )
        .get();
    expect(holds, hasLength(1));
    expect(holds.single.read<String>('local_date'), '2026-10-20');
    expect(
      holds.single.read<int>('invalid_after_utc'),
      greaterThan(harness.clock.nowUtc().microsecondsSinceEpoch),
    );
  });

  test('只能排一部分时必须明确确认，completeOnly 不写计划，allowPartial 才应用', () async {
    final window = TimeRange(
      startUtc: harness.clock.nowUtc(),
      endUtc: harness.clock.nowUtc().add(const Duration(hours: 1)),
    );
    final partialProblem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: 'Asia/Shanghai',
      tasks: [
        SchedulableTask(
          id: 'task-1',
          requiredMinutes: 120,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 25,
          maxChunkMinutes: 90,
          availableFromUtc: harness.clock.nowUtc(),
        ),
      ],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: problem.rules,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: window,
        rules: problem.rules,
        timeZoneId: 'Asia/Shanghai',
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: problem.rules,
        timeZoneId: 'Asia/Shanghai',
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'hash',
    );
    final planRepository = DriftPlanRepository(harness.database);
    final partialService = DriftExecutionRecoveryService(
      repository: harness.repository,
      tasks: harness.taskRepository,
      plans: planRepository,
      baseSource: _FixedSource(partialProblem),
      engine: DeterministicScheduleEngine(zones),
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
      clock: harness.clock,
      idGenerator: harness.ids,
      linker: ExecutionPlanLinker(
        repository: harness.repository,
        zones: zones,
        idGenerator: harness.ids,
        clock: harness.clock,
      ),
    );
    final task = await harness.taskRepository.getById('task-1');
    await harness.taskRepository.save(task!.copyWith(remainingMinutes: 120));
    final occurrence = await harness.seedOccurrence(
      allocatedMinutes: 120,
      remainingMinutes: 120,
    );
    final currentTask = (await harness.taskRepository.getById('task-1'))!;
    final draftResult = await partialService.requestRecovery(
      RequestExecutionRecoveryCommand(
        operationId: 'op-request',
        dataEpoch: 'epoch',
        occurrenceId: occurrence.id,
        notBeforeUtc: harness.clock.nowUtc(),
        targetShareMicros: 120 * 60 * 1000000,
        occurrenceRevision: occurrence.revision,
        planVersionId: 'plan-1',
        taskInputHash: executionTaskInputHash(currentTask),
        progressAnchorRevision: 0,
        processEpoch: partialService.processEpoch,
      ),
    );
    expect(draftResult.result.status, ExecutionResultStatus.applied);
    final draft = draftResult.draft!;
    expect(draft.unassignedMinutes, greaterThan(0));

    final completeOnly = await partialService.applyRecovery(
      ApplyExecutionRecoveryCommand(
        operationId: 'op-apply-complete',
        dataEpoch: 'epoch',
        draftId: draft.draftId,
        proposalId: draft.proposalId,
        inputHash: draft.inputHash,
        processEpoch: draft.processEpoch,
        occurrenceRevision: 1,
        planVersionId: 'plan-1',
        taskInputHash: executionTaskInputHash(currentTask),
        progressAnchorRevision: 0,
      ),
    );
    expect(completeOnly.status, ExecutionResultStatus.needsConfirmation);
    expect(await planRepository.current(), isNotNull);
    expect((await planRepository.current())!.blocks, isEmpty);

    final partial = await partialService.applyRecovery(
      ApplyExecutionRecoveryCommand(
        operationId: 'op-apply-partial',
        dataEpoch: 'epoch',
        draftId: draft.draftId,
        proposalId: draft.proposalId,
        inputHash: draft.inputHash,
        processEpoch: draft.processEpoch,
        occurrenceRevision: 1,
        planVersionId: 'plan-1',
        taskInputHash: executionTaskInputHash(currentTask),
        progressAnchorRevision: 0,
        authorizationMode: PlanApplyMode.allowPartial,
      ),
    );
    expect(partial.status, ExecutionResultStatus.applied);
    expect(
      (await planRepository.current())!.blocks.fold<int>(
        0,
        (sum, block) => sum + block.range.duration.inMinutes,
      ),
      lessThan(120),
    );
  });

  test('当天剩余时间被占满时恢复预览排到明天，而不是硬塞进今天', () async {
    final start = harness.clock.nowUtc();
    final tomorrowLocalMidnight = DateTime.utc(2026, 10, 19, 16);
    final tomorrowProblem = ScheduleProblem(
      planningWindow: problem.planningWindow,
      timeZoneId: problem.timeZoneId,
      tasks: problem.tasks,
      fixedIntervals: [
        BusyInterval(
          id: 'busy-today',
          range: TimeRange(startUtc: start, endUtc: tomorrowLocalMidnight),
        ),
      ],
      protectedIntervals: problem.protectedIntervals,
      lockedBlocks: problem.lockedBlocks,
      rules: problem.rules,
      dailyPolicies: problem.dailyPolicies,
      weeklyLifeQuotaByWeekStart: problem.weeklyLifeQuotaByWeekStart,
      preferences: problem.preferences,
      inputHash: 'hash',
    );
    final planRepository = DriftPlanRepository(harness.database);
    final tomorrowService = DriftExecutionRecoveryService(
      repository: harness.repository,
      tasks: harness.taskRepository,
      plans: planRepository,
      baseSource: _FixedSource(tomorrowProblem),
      engine: DeterministicScheduleEngine(zones),
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
      clock: harness.clock,
      idGenerator: harness.ids,
      linker: ExecutionPlanLinker(
        repository: harness.repository,
        zones: zones,
        idGenerator: harness.ids,
        clock: harness.clock,
      ),
    );
    final occurrence = await harness.seedOccurrence();
    final task = (await harness.taskRepository.getById('task-1'))!;
    final result = await tomorrowService.requestRecovery(
      RequestExecutionRecoveryCommand(
        operationId: 'op-request',
        dataEpoch: 'epoch',
        occurrenceId: occurrence.id,
        notBeforeUtc: start,
        occurrenceRevision: 1,
        planVersionId: 'plan-1',
        taskInputHash: executionTaskInputHash(task),
        progressAnchorRevision: 0,
        processEpoch: tomorrowService.processEpoch,
      ),
    );
    expect(result.result.status, ExecutionResultStatus.applied);
    expect(result.draft!.preview.blocks, isNotEmpty);
    expect(
      result.draft!.preview.blocks.first.startUtc.isBefore(
        tomorrowLocalMidnight,
      ),
      isFalse,
    );
  });

  test('准入冲突的恢复方案被拒绝，不写计划', () async {
    final conflicted = ScheduleProblem(
      planningWindow: problem.planningWindow,
      timeZoneId: problem.timeZoneId,
      tasks: problem.tasks,
      fixedIntervals: problem.fixedIntervals,
      protectedIntervals: problem.protectedIntervals,
      lockedBlocks: problem.lockedBlocks,
      rules: problem.rules,
      dailyPolicies: problem.dailyPolicies,
      weeklyLifeQuotaByWeekStart: problem.weeklyLifeQuotaByWeekStart,
      preferences: problem.preferences,
      inputHash: 'hash',
      admissionConflicts: [
        PlanningConflict(
          code: ConflictCode.invalidInput,
          taskId: 'task-1',
          blockingInput: 'test_invalid_input',
        ),
      ],
    );
    final planRepository = DriftPlanRepository(harness.database);
    final conflictedService = DriftExecutionRecoveryService(
      repository: harness.repository,
      tasks: harness.taskRepository,
      plans: planRepository,
      baseSource: _FixedSource(conflicted),
      engine: DeterministicScheduleEngine(zones),
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
      clock: harness.clock,
      idGenerator: harness.ids,
      linker: ExecutionPlanLinker(
        repository: harness.repository,
        zones: zones,
        idGenerator: harness.ids,
        clock: harness.clock,
      ),
    );
    final occurrence = await harness.seedOccurrence();
    final task = (await harness.taskRepository.getById('task-1'))!;
    final result = await conflictedService.requestRecovery(
      RequestExecutionRecoveryCommand(
        operationId: 'op-request',
        dataEpoch: 'epoch',
        occurrenceId: occurrence.id,
        notBeforeUtc: harness.clock.nowUtc(),
        occurrenceRevision: 1,
        planVersionId: 'plan-1',
        taskInputHash: executionTaskInputHash(task),
        progressAnchorRevision: 0,
        processEpoch: conflictedService.processEpoch,
      ),
    );
    expect(result.result.status, ExecutionResultStatus.invalid);
    expect(result.result.reasonCode, ExecutionReasonCode.proposalInvalid);
    expect(result.draft, isNull);
    expect(await planRepository.current(), isNotNull);
    expect((await planRepository.current())!.blocks, isEmpty);
  });
}
