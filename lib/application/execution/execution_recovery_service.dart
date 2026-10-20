import 'package:personal_planner/application/execution/execution_commands.dart';
import 'package:personal_planner/application/execution/execution_input_hashes.dart';
import 'package:personal_planner/application/execution/execution_plan_linker.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_models.dart' as d;
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 局部恢复的一次性作用域（规范 §9、§19.3）。
///
/// **草案只存在于当前进程代次**：路由离开、取消、应用或进程重启都让它失效。生成预览不写
/// 计划、不写 dayHold；`applyRecovery` 才在同一个事务里写计划、来源关联与限制。
final class DriftExecutionRecoveryService implements ExecutionRecoveryService {
  DriftExecutionRecoveryService({
    required this.repository,
    required this.tasks,
    required this.plans,
    required this.baseSource,
    required this.engine,
    required this.zones,
    required this.timeZoneId,
    required this.clock,
    required this.idGenerator,
    required this.linker,
  }) : _processEpoch = idGenerator.next();

  final DriftExecutionRepository repository;
  final TaskRepository tasks;
  final PlanRepository plans;
  final ScheduleProblemSource baseSource;
  final ScheduleEngine engine;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final Clock clock;
  final IdGenerator idGenerator;
  final ExecutionPlanLinker linker;

  final String _processEpoch;
  final Map<String, _RecoveryDraftState> _drafts = {};

  int get openDraftCount =>
      _drafts.values.where((draft) => draft.draft.isOpen).length;

  /// 当前进程代次。页面必须原样带回 `requestRecovery` 与 `applyRecovery`。
  @override
  String get processEpoch => _processEpoch;

  @override
  Future<ExecutionRecoveryDraftResult> requestRecovery(
    RequestExecutionRecoveryCommand command,
  ) async {
    final occurrence = await repository.findOccurrence(command.occurrenceId);
    if (occurrence == null) {
      return _draftFailure(
        command,
        ExecutionResultStatus.notFound,
        ExecutionReasonCode.entityNotFound,
      );
    }
    if (command.processEpoch != _processEpoch) {
      return _draftFailure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.draftExpired,
      );
    }
    if (occurrence.revision != command.occurrenceRevision) {
      return _draftFailure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
      );
    }
    if (occurrence.currentPlanVersionId == null ||
        occurrence.currentPlanVersionId != command.planVersionId) {
      return _draftFailure(
        command,
        ExecutionResultStatus.sourceMappingMissing,
        ExecutionReasonCode.sourceMappingMissing,
      );
    }
    if (occurrence.taskId case final taskId?) {
      final task = await tasks.getById(taskId);
      if (task == null) {
        return _draftFailure(
          command,
          ExecutionResultStatus.notFound,
          ExecutionReasonCode.entityNotFound,
        );
      }
      if (command.taskInputHash.isNotEmpty &&
          command.taskInputHash != _taskHash(task)) {
        return _draftFailure(
          command,
          ExecutionResultStatus.stale,
          ExecutionReasonCode.revisionMismatch,
        );
      }
    }
    if (!command.notBeforeUtc.isAfter(
      clock.nowUtc().subtract(const Duration(days: 7)),
    )) {
      return _draftFailure(
        command,
        ExecutionResultStatus.outsidePlanBoundary,
        ExecutionReasonCode.outsidePlanBoundary,
      );
    }

    final source = _RecoveryProblemSource(
      base: baseSource,
      repository: repository,
      tasks: tasks,
      occurrence: occurrence,
      notBeforeUtc: command.notBeforeUtc,
      targetShareMicros: command.targetShareMicros,
      timeZoneId: timeZoneId,
    );
    final proposal = await PlanningService(
      source: source,
      engine: engine,
      clock: clock,
    ).createProposal();
    if (proposal.conflicts.isNotEmpty) {
      return _draftFailure(
        command,
        ExecutionResultStatus.invalid,
        ExecutionReasonCode.proposalInvalid,
        parameters: {'conflictCount': proposal.conflicts.length},
      );
    }
    final unassignedMinutes = proposal.unscheduled.fold<int>(
      0,
      (sum, item) => sum + item.shortageMinutes,
    );
    final preview = ExecutionRecoveryPreview(
      blocks: [
        for (final block in proposal.blocks)
          ExecutionRecoveryPreviewBlock(
            taskId: block.taskId,
            startUtc: block.startUtc,
            endUtc: block.endUtc,
            isOccurrenceTask: block.taskId == occurrence.taskId,
          ),
      ],
      shortages: [
        for (final item in proposal.unscheduled)
          ExecutionRecoveryShortage(
            taskId: item.taskId,
            minutes: item.shortageMinutes,
          ),
      ],
    );
    final draft = ExecutionRecoveryDraft(
      draftId: idGenerator.next(),
      proposalId: proposal.proposalId,
      occurrenceId: occurrence.id,
      processEpoch: _processEpoch,
      state: d.ExecutionDraftState.open,
      revision: 1,
      createdAtUtc: clock.nowUtc(),
      notBeforeUtc: command.notBeforeUtc,
      targetShareMicros:
          command.targetShareMicros ?? occurrence.remainingAllocationMicros,
      holdToday: command.holdToday,
      inputHash: proposal.inputHash,
      planVersionId: command.planVersionId,
      unassignedMinutes: unassignedMinutes,
      preview: preview,
    );
    _drafts[draft.draftId] = _RecoveryDraftState(
      draft: draft,
      proposal: proposal,
      occurrence: occurrence,
      source: source,
      timeZoneId: source.timeZoneId,
    );
    return ExecutionRecoveryDraftResult(
      result: ExecutionCommandResult.applied(
        operationId: command.operationId,
        occurrenceId: occurrence.id,
        parameters: {
          'draftId': draft.draftId,
          'proposalId': proposal.proposalId,
          'unassignedMinutes': unassignedMinutes,
          'notBeforeUtc': command.notBeforeUtc.toIso8601String(),
        },
      ),
      draft: draft,
    );
  }

  @override
  Future<ExecutionCommandResult> applyRecovery(
    ApplyExecutionRecoveryCommand command,
  ) async {
    final state = _drafts[command.draftId];
    if (state == null) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.draftNotFound,
      );
    }
    if (state.draft.processEpoch != command.processEpoch ||
        command.processEpoch != _processEpoch) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.draftExpired,
      );
    }
    if (!state.draft.isOpen) {
      return _failure(
        command,
        ExecutionResultStatus.alreadyApplied,
        ExecutionReasonCode.draftNotOpen,
      );
    }
    if (state.draft.proposalId != command.proposalId ||
        state.draft.inputHash != command.inputHash) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.proposalStale,
      );
    }
    if (state.occurrence.revision != command.occurrenceRevision ||
        state.draft.planVersionId != command.planVersionId) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
      );
    }
    final task = state.occurrence.taskId == null
        ? null
        : await tasks.getById(state.occurrence.taskId!);
    if (task == null || _taskHash(task) != command.taskInputHash) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
      );
    }
    final anchor = await repository.currentAnchor(task.id);
    if (command.progressAnchorRevision != 0 &&
        (anchor?.revision ?? 0) != command.progressAnchorRevision) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
      );
    }

    final applier = plans is PlanTransactionApplier
        ? plans as PlanTransactionApplier
        : null;
    final application = PlanApplicationService(
      source: state.source,
      repository: plans,
      zones: zones,
      planTransactionApplier: applier,
      afterApplied: (plan, proposal, problem) => _afterRecoveryApplied(
        command: command,
        state: state,
        plan: plan,
        proposal: proposal,
        timeZoneId: problem.timeZoneId,
      ),
    );
    final applied = await application.apply(
      state.proposal,
      mode: command.authorizationMode,
    );
    switch (applied.status) {
      case ApplyPlanStatus.applied:
        _drafts.remove(command.draftId);
        return ExecutionCommandResult.applied(
          operationId: command.operationId,
          occurrenceId: state.occurrence.id,
          parameters: {
            'planVersionId': applied.plan?.id,
            'draftId': command.draftId,
          },
        );
      case ApplyPlanStatus.partialConfirmationRequired:
        return _failure(
          command,
          ExecutionResultStatus.needsConfirmation,
          ExecutionReasonCode.partialNotAuthorized,
          parameters: {'unassignedMinutes': state.draft.unassignedMinutes},
        );
      case ApplyPlanStatus.staleProposal:
        return _failure(
          command,
          ExecutionResultStatus.stale,
          ExecutionReasonCode.proposalStale,
        );
      case ApplyPlanStatus.invalidProposal:
        return _failure(
          command,
          ExecutionResultStatus.invalid,
          ExecutionReasonCode.proposalInvalid,
        );
    }
  }

  @override
  Future<ExecutionCommandResult> cancelRecovery(
    CancelExecutionRecoveryCommand command,
  ) async {
    final state = _drafts[command.draftId];
    if (state == null) {
      // 重复取消无副作用，但重启后的旧 draft 必须返回 stale（规范 §19.3）。
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.draftNotFound,
      );
    }
    if (state.draft.processEpoch != command.processEpoch ||
        command.processEpoch != _processEpoch) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.draftExpired,
      );
    }
    if (!state.draft.isOpen) {
      return ExecutionCommandResult.alreadyApplied(
        operationId: command.operationId,
        occurrenceId: state.occurrence.id,
        parameters: {'draftId': command.draftId},
      );
    }
    state.draft = state.draft.copyWith(
      state: d.ExecutionDraftState.cancelled,
      revision: state.draft.revision + 1,
    );
    _drafts.remove(command.draftId);
    return ExecutionCommandResult.applied(
      operationId: command.operationId,
      occurrenceId: state.occurrence.id,
      parameters: {'draftId': command.draftId},
    );
  }

  /// 进程结束或路由离开时释放全部草案；未应用的预览绝不留给下一次普通生成。
  void cancelAllDrafts() {
    for (final entry in _drafts.values) {
      entry.draft = entry.draft.copyWith(
        state: d.ExecutionDraftState.expired,
        revision: entry.draft.revision + 1,
      );
    }
    _drafts.clear();
  }

  Future<void> _afterRecoveryApplied({
    required ApplyExecutionRecoveryCommand command,
    required _RecoveryDraftState state,
    required ConfirmedPlan plan,
    required ScheduleProposal proposal,
    required String timeZoneId,
  }) async {
    final occurrenceId = state.occurrence.id;
    await linker.linkAppliedPlan(
      plan: plan,
      proposal: proposal,
      timeZoneId: timeZoneId,
      fallbackOccurrenceByTask: {?state.occurrence.taskId: occurrenceId},
    );
    final taskId = state.occurrence.taskId;
    if (taskId != null) {
      final reserved = plan.blocks
          .where((block) => block.taskId == taskId)
          .fold<int>(
            0,
            (sum, block) => sum + block.range.duration.inMicroseconds,
          );
      final current = await repository.findOccurrence(occurrenceId);
      if (current != null) {
        await repository.updateOccurrence(
          current.copyWith(
            currentPlanVersionId: plan.id,
            remainingAllocationMicros: reserved,
            revision: current.revision + 1,
          ),
        );
      }
    }
    if (state.draft.holdToday) {
      await repository.upsertDayHold(
        _dayHoldFor(state.occurrence, timeZoneId: timeZoneId, planId: plan.id),
      );
    }
    final sequence = await repository.allocateSequence();
    await repository.insertEvent(
      d.ExecutionEvent(
        eventId: idGenerator.next(),
        dataEpoch: command.dataEpoch,
        operationId: command.operationId,
        subEventIndex: 0,
        occurrenceId: occurrenceId,
        eventType: d.ExecutionEventType.recoveryApplied,
        occurredAtUtc: clock.nowUtc(),
        recordedAtUtc: clock.nowUtc(),
        source: d.ExecutionActivitySource.realtime,
        payload: {
          'planVersionId': plan.id,
          'draftId': command.draftId,
          'unassignedMinutes': state.draft.unassignedMinutes,
        },
        correctedEventId: null,
        sequence: sequence,
        revision: 1,
      ),
    );
    await repository.recordOperation(
      dataEpoch: command.dataEpoch,
      operationId: command.operationId,
      requestHash: command.requestHash(),
      commandType: command.commandType,
      subjectKind: command.subjectKind,
      subjectId: command.subjectId,
      result: ExecutionCommandResult.applied(
        operationId: command.operationId,
        occurrenceId: occurrenceId,
        parameters: {'planVersionId': plan.id},
      ),
    );
  }

  d.ExecutionDayHold _dayHoldFor(
    d.ExecutionOccurrence occurrence, {
    required String timeZoneId,
    required String planId,
  }) {
    final now = clock.nowUtc();
    final local = zones.toLocal(now, timeZoneId);
    final nextLocalMidnight = DateTime(local.year, local.month, local.day + 1);
    final invalidAfterUtc = zones.localMidnightToUtc(
      nextLocalMidnight,
      timeZoneId,
    );
    return d.ExecutionDayHold(
      taskId: occurrence.taskId!,
      localDate: d.executionLocalDateKey(nextLocalMidnight),
      timeZoneId: timeZoneId,
      invalidAfterUtc: invalidAfterUtc,
      sourceProposalId: planId,
      createdAtUtc: now,
    );
  }

  String _taskHash(PlannerTask task) => executionTaskInputHash(task);

  ExecutionRecoveryDraftResult _draftFailure(
    ExecutionCommand command,
    ExecutionResultStatus status,
    ExecutionReasonCode reason, {
    Map<String, Object?> parameters = const {},
  }) => ExecutionRecoveryDraftResult(
    result: _failure(command, status, reason, parameters: parameters),
  );

  ExecutionCommandResult _failure(
    ExecutionCommand command,
    ExecutionResultStatus status,
    ExecutionReasonCode reason, {
    Map<String, Object?> parameters = const {},
  }) => ExecutionCommandResult.failure(
    status,
    reason,
    operationId: command.operationId,
    parameters: parameters,
  );
}

final class _RecoveryDraftState {
  _RecoveryDraftState({
    required this.draft,
    required this.proposal,
    required this.occurrence,
    required this.source,
    required this.timeZoneId,
  });

  ExecutionRecoveryDraft draft;
  final ScheduleProposal proposal;
  final d.ExecutionOccurrence occurrence;
  final _RecoveryProblemSource source;
  final String timeZoneId;
}

/// 在基础排程输入上叠加一次恢复意图：释放该实例的旧占用，把剩余工作的下界改为现在。
///
/// **不按标题或钟点猜来源**：旧块 id 来自 `execution_block_links`；找不到时由调用方显式
/// 给出实例映射（`fallbackOccurrenceByTask`）。
final class _RecoveryProblemSource implements ScheduleProblemSource {
  _RecoveryProblemSource({
    required this.base,
    required this.repository,
    required this.tasks,
    required this.occurrence,
    required this.notBeforeUtc,
    required this.targetShareMicros,
    required this.timeZoneId,
  });

  final ScheduleProblemSource base;
  final DriftExecutionRepository repository;
  final TaskRepository tasks;
  final d.ExecutionOccurrence occurrence;
  final DateTime notBeforeUtc;
  final int? targetShareMicros;
  final String timeZoneId;

  @override
  Future<ScheduleProblem> load({
    ScheduleRuleOverride? override,
    TimeRange? window,
  }) async {
    final problem = await base.load(override: override, window: window);
    final taskId = occurrence.taskId;
    if (taskId == null) {
      throw StateError('恢复实例已匿名化，不能重建计划占用');
    }
    final task = await tasks.getById(taskId);
    if (task == null) {
      throw StateError('恢复实例所属任务不存在');
    }

    final links = occurrence.currentPlanVersionId == null
        ? const <String, String>{}
        : await repository.blockLinksForVersion(
            occurrence.currentPlanVersionId!,
          );
    final oldBlockIds = {
      for (final entry in links.entries)
        if (entry.value == occurrence.id) entry.key,
    };

    final schedulable = <SchedulableTask>[];
    var replaced = false;
    for (final item in problem.tasks) {
      if (item.id != taskId) {
        schedulable.add(item);
        continue;
      }
      replaced = true;
      final share = targetShareMicros ?? occurrence.remainingAllocationMicros;
      final shareMinutes = _ceilMinutes(share);
      schedulable.add(
        SchedulableTask(
          id: item.id,
          requiredMinutes: shareMinutes > item.requiredMinutes
              ? shareMinutes
              : item.requiredMinutes,
          splitMode: item.splitMode,
          minChunkMinutes: item.minChunkMinutes,
          maxChunkMinutes: item.maxChunkMinutes,
          dueAtUtc: item.dueAtUtc,
          availableFromUtc: _later(item.availableFromUtc, notBeforeUtc),
          priority: item.priority,
          energyLevel: item.energyLevel,
          isLifeTask: item.isLifeTask,
          preferredWindow: item.preferredWindow,
          allowedWeekdaysMask: item.allowedWeekdaysMask,
          maxMinutesPerLocalDay: item.maxMinutesPerLocalDay,
          distributionPolicy: item.distributionPolicy,
        ),
      );
    }
    if (!replaced) {
      schedulable.add(
        SchedulableTask(
          id: task.id,
          requiredMinutes: _ceilMinutes(
            targetShareMicros ?? occurrence.remainingAllocationMicros,
          ),
          splitMode: task.splitMode,
          minChunkMinutes: task.minChunkMinutes,
          maxChunkMinutes: task.maxChunkMinutes,
          dueAtUtc: task.dueAtUtc,
          availableFromUtc: _later(task.availableFromUtc, notBeforeUtc),
          priority: task.priority,
          energyLevel: task.energyLevel,
        ),
      );
    }

    bool keep(PlannedBlock block) => !oldBlockIds.contains(block.id);
    return ScheduleProblem(
      planningWindow: problem.planningWindow,
      timeZoneId: problem.timeZoneId,
      tasks: schedulable,
      fixedIntervals: problem.fixedIntervals,
      protectedIntervals: problem.protectedIntervals,
      lockedBlocks: problem.lockedBlocks.where(keep).toList(),
      existingBlocks: problem.existingBlocks.where(keep).toList(),
      rules: problem.rules,
      dailyPolicies: problem.dailyPolicies,
      weeklyLifeQuotaByWeekStart: problem.weeklyLifeQuotaByWeekStart,
      preferences: problem.preferences,
      inputHash: problem.inputHash,
      pinnedUnlockedBlockIds: problem.pinnedUnlockedBlockIds
          .where((id) => !oldBlockIds.contains(id))
          .toSet(),
      referenceBlocks: {
        for (final entry in problem.referenceBlocks.entries)
          if (!oldBlockIds.contains(entry.key)) entry.key: entry.value,
      },
      adjustment: null,
      confirmedBlocks: problem.confirmedBlocks.where(keep).toList(),
      admissionConflicts: problem.admissionConflicts,
    );
  }

  static int _ceilMinutes(int micros) {
    if (micros <= 0) return 1;
    const perMinute = 60 * 1000000;
    return (micros + perMinute - 1) ~/ perMinute;
  }

  static DateTime? _later(DateTime? current, DateTime lower) {
    if (current == null) return lower;
    return current.isAfter(lower) ? current : lower;
  }
}
