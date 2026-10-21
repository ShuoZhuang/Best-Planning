import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart';
import 'package:personal_planner/domain/execution/execution_models.dart' as d;
import 'package:personal_planner/domain/models/recurring_completion_evidence.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';

enum FragmentCommandStatus { applied, stale, notFound, invalid, conflict }

final class FragmentCommandResult {
  const FragmentCommandResult({
    required this.status,
    this.fragment,
    this.evidenceId,
    this.amountMicros = 0,
    this.reason,
  });

  final FragmentCommandStatus status;
  final ExecutionFragment? fragment;
  final String? evidenceId;
  final int amountMicros;
  final String? reason;

  bool get isApplied => status == FragmentCommandStatus.applied;
}

final class CompleteExecutionFragmentCommand {
  const CompleteExecutionFragmentCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.fragmentId,
    required this.planVersionId,
    required this.blockId,
    required this.expectedFragmentRevision,
    required this.occurredAtUtc,
  });

  final String operationId;
  final String dataEpoch;
  final String fragmentId;
  final String planVersionId;
  final String blockId;
  final int expectedFragmentRevision;
  final DateTime occurredAtUtc;
}

/// 手动补记/实际活动：显式发生区间，按真实周界切分，不拿保存时刻冒充历史。
final class RecordRecurringActivityCommand {
  const RecordRecurringActivityCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.startUtc,
    required this.endUtc,
    required this.occurredAtUtc,
    this.reason,
  });

  final String operationId;
  final String dataEpoch;
  final DateTime startUtc;
  final DateTime endUtc;
  final DateTime occurredAtUtc;
  final String? reason;
}

final class UndoFragmentCompletionCommand {
  const UndoFragmentCompletionCommand({
    required this.operationId,
    required this.dataEpoch,
    required this.fragmentId,
    required this.expectedFragmentRevision,
    required this.occurredAtUtc,
    this.reason = '用户撤销本次完成',
  });

  final String operationId;
  final String dataEpoch;
  final String fragmentId;
  final int expectedFragmentRevision;
  final DateTime occurredAtUtc;
  final String reason;
}

/// 1.12.0 片段级完成 / 撤销 / 周期有效进度（设计 §8、Task 8）。
///
/// 只写 evidence 与 fragment，不写 `time_entries`，不伪造真实活动段。真实活动通过 1.11
/// 的 credit 管道进入；本服务用 `fragment.completedMicros` 表示已经覆盖的真实量。
final class RecurringProgressService {
  RecurringProgressService({
    required this.repository,
    required this.executionRepository,
    required this.clock,
    required this.idGenerator,
  });

  final DriftRecurringExecutionRepository repository;
  final DriftExecutionRepository executionRepository;
  final Clock clock;
  final IdGenerator idGenerator;

  Future<FragmentCommandResult> completeFragment(
    CompleteExecutionFragmentCommand command,
  ) => repository.transaction(() async {
    final runtime = await executionRepository.ensureRuntimeState();
    if (runtime.dataEpoch != command.dataEpoch) {
      return const FragmentCommandResult(
        status: FragmentCommandStatus.stale,
        reason: 'dataEpochMismatch',
      );
    }
    if (!command.occurredAtUtc.isUtc) {
      return const FragmentCommandResult(
        status: FragmentCommandStatus.invalid,
        reason: 'occurredAtNotUtc',
      );
    }
    final existing = await repository.evidenceByOperation(
      command.dataEpoch,
      command.operationId,
    );
    if (existing != null) {
      return FragmentCommandResult(
        status: FragmentCommandStatus.applied,
        fragment: await repository.findFragment(command.fragmentId),
        evidenceId: existing.evidenceId,
        amountMicros: existing.amountMicros,
        reason: 'idempotentReplay',
      );
    }
    final fragment = await repository.findFragment(command.fragmentId);
    if (fragment == null) {
      return const FragmentCommandResult(
        status: FragmentCommandStatus.notFound,
        reason: 'fragmentNotFound',
      );
    }
    if (fragment.planVersionId != command.planVersionId ||
        fragment.blockId != command.blockId) {
      return const FragmentCommandResult(
        status: FragmentCommandStatus.invalid,
        reason: 'staleBlockIdentity',
      );
    }
    if (fragment.revision != command.expectedFragmentRevision) {
      return const FragmentCommandResult(
        status: FragmentCommandStatus.conflict,
        reason: 'fragmentRevisionConflict',
      );
    }
    if (fragment.state == ExecutionFragmentState.withdrawn ||
        fragment.state == ExecutionFragmentState.superseded) {
      return const FragmentCommandResult(
        status: FragmentCommandStatus.invalid,
        reason: 'fragmentNotExecutable',
      );
    }
    if (fragment.state == ExecutionFragmentState.completed) {
      return const FragmentCommandResult(
        status: FragmentCommandStatus.conflict,
        reason: 'fragmentAlreadyCompleted',
      );
    }
    final amount = fragment.remainingMicros;
    if (amount <= 0) {
      final completed = fragment.copyWith(
        state: ExecutionFragmentState.completed,
        completedAtUtc: command.occurredAtUtc,
        revision: fragment.revision + 1,
      );
      await repository.updateFragment(completed);
      return FragmentCommandResult(
        status: FragmentCommandStatus.applied,
        fragment: completed,
        reason: 'alreadyCoveredByActivity',
      );
    }
    final sequence = await executionRepository.allocateSequence();
    final evidence = RecurringCompletionEvidence(
      evidenceId: idGenerator.next(),
      dataEpoch: command.dataEpoch,
      operationId: command.operationId,
      cycleId: fragment.cycleId ?? fragment.occurrenceId,
      fragmentId: fragment.fragmentId,
      amountMicros: amount,
      kind: RecurringEvidenceKind.fragmentCompletion,
      reversesEvidenceId: null,
      recordedAtUtc: clock.nowUtc(),
      effectiveAtUtc: command.occurredAtUtc,
      sequence: sequence,
      reason: null,
      idempotencyKey: '${command.dataEpoch}:${command.operationId}',
      revision: 1,
    );
    await repository.insertEvidence(evidence);
    final completed = fragment.copyWith(
      completedMicros: fragment.allocatedMicros,
      state: ExecutionFragmentState.completed,
      completedAtUtc: command.occurredAtUtc,
      revision: fragment.revision + 1,
    );
    await repository.updateFragment(completed);
    await _enqueueOutbox(
      dataEpoch: command.dataEpoch,
      targetRevision: completed.revision,
      effectType: 'recurringFragmentCompleted',
      payload: {
        'fragmentId': completed.fragmentId,
        'cycleId': completed.cycleId,
        'evidenceId': evidence.evidenceId,
      },
    );
    await _refreshCycleState(fragment.cycleId);
    return FragmentCommandResult(
      status: FragmentCommandStatus.applied,
      fragment: completed,
      evidenceId: evidence.evidenceId,
      amountMicros: amount,
    );
  });

  /// 手动补记/实际活动：按真实周界拆分到相交的周实例，逐段写证据。
  Future<List<RecurringCompletionEvidence>> recordActivity(
    RecordRecurringActivityCommand command,
  ) => repository.transaction(() async {
    if (!command.startUtc.isUtc ||
        !command.endUtc.isUtc ||
        !command.occurredAtUtc.isUtc ||
        !command.endUtc.isAfter(command.startUtc)) {
      throw ArgumentError('Activity bounds must be ordered UTC instants.');
    }
    final runtime = await executionRepository.ensureRuntimeState();
    if (runtime.dataEpoch != command.dataEpoch) {
      throw StateError('dataEpochMismatch');
    }
    final snapshots = await repository.cycleSnapshotsIntersecting(
      command.startUtc,
      command.endUtc,
    );
    if (snapshots.isEmpty) {
      throw StateError('noRecurringCycleForActivity');
    }
    final result = <RecurringCompletionEvidence>[];
    for (final snapshot in snapshots) {
      final start = command.startUtc.isBefore(snapshot.effectiveStartUtc)
          ? snapshot.effectiveStartUtc
          : command.startUtc;
      final end = command.endUtc.isAfter(snapshot.effectiveEndUtc)
          ? snapshot.effectiveEndUtc
          : command.endUtc;
      final micros = end.difference(start).inMicroseconds;
      if (micros <= 0) continue;
      final key =
          '${command.dataEpoch}:${command.operationId}:${snapshot.cycleId}';
      final existing = await repository.evidenceByIdempotencyKey(key);
      if (existing != null) {
        result.add(existing);
        continue;
      }
      final sequence = await executionRepository.allocateSequence();
      // 手动补记/真实活动进入同一执行管道：time_entry → activity segment →
      // recurringCycle credit → evidence。周期进度仍只从 time_entries 汇总，证据用于审计。
      final entryId = idGenerator.next();
      await executionRepository.insertTimeEntry(
        id: entryId,
        taskId: snapshot.transportTaskId,
        startedAtUtc: start,
        phase: d.ExecutionSessionState.finished,
        activeMicros: micros,
        lastReliableAtUtc: end,
        note: command.reason ?? '',
      );
      await executionRepository.updateTimeEntry(
        id: entryId,
        phase: d.ExecutionSessionState.finished,
        activeMicros: micros,
        lastReliableAtUtc: end,
        endedAtUtc: end,
      );
      final segment = d.ExecutionActivitySegment(
        segmentId: idGenerator.next(),
        dataEpoch: command.dataEpoch,
        sessionId: entryId,
        sequence: 1,
        startUtc: start,
        endUtc: end,
        source: d.ExecutionActivitySource.manual,
        invalidatedReason: null,
        createdAtUtc: clock.nowUtc(),
      );
      await executionRepository.insertActivitySegment(segment);
      await executionRepository.insertCredit(
        d.ExecutionCreditAllocation(
          dataEpoch: command.dataEpoch,
          segmentId: segment.segmentId,
          targetKind: d.ExecutionTargetKind.recurringCycle,
          targetId: snapshot.cycleId,
          allocationIndex: 0,
          recordRevision: 1,
          amountMicros: micros,
          firstAcceptedSequence: sequence,
          createdAtUtc: clock.nowUtc(),
        ),
      );
      final evidence = RecurringCompletionEvidence(
        evidenceId: idGenerator.next(),
        dataEpoch: command.dataEpoch,
        operationId: command.operationId,
        cycleId: snapshot.cycleId,
        fragmentId: null,
        amountMicros: micros,
        kind: RecurringEvidenceKind.activity,
        reversesEvidenceId: null,
        recordedAtUtc: clock.nowUtc(),
        effectiveAtUtc: command.occurredAtUtc,
        sequence: sequence,
        reason: command.reason,
        idempotencyKey: key,
        revision: 1,
      );
      await repository.insertEvidence(evidence);
      await _enqueueOutbox(
        dataEpoch: command.dataEpoch,
        targetRevision: evidence.revision,
        effectType: 'recurringActivityRecorded',
        payload: {
          'cycleId': snapshot.cycleId,
          'evidenceId': evidence.evidenceId,
        },
      );
      result.add(evidence);
    }
    return result;
  });

  Future<FragmentCommandResult> undoFragmentCompletion(
    UndoFragmentCompletionCommand command,
  ) => repository.transaction(() async {
    final fragment = await repository.findFragment(command.fragmentId);
    if (fragment == null) {
      return const FragmentCommandResult(
        status: FragmentCommandStatus.notFound,
        reason: 'fragmentNotFound',
      );
    }
    if (fragment.revision != command.expectedFragmentRevision) {
      return const FragmentCommandResult(
        status: FragmentCommandStatus.conflict,
        reason: 'fragmentRevisionConflict',
      );
    }
    final evidence = await repository.evidenceForFragment(fragment.fragmentId);
    RecurringCompletionEvidence? target;
    for (final item in evidence.reversed) {
      if (item.kind == RecurringEvidenceKind.fragmentCompletion &&
          item.signedMicros > 0) {
        target = item;
        break;
      }
    }
    if (target == null) {
      return const FragmentCommandResult(
        status: FragmentCommandStatus.invalid,
        reason: 'noDeclaredCompletion',
      );
    }
    final reversal = RecurringCompletionEvidence(
      evidenceId: idGenerator.next(),
      dataEpoch: command.dataEpoch,
      operationId: command.operationId,
      cycleId: target.cycleId,
      fragmentId: target.fragmentId,
      amountMicros: target.amountMicros,
      kind: RecurringEvidenceKind.correction,
      reversesEvidenceId: target.evidenceId,
      recordedAtUtc: clock.nowUtc(),
      effectiveAtUtc: command.occurredAtUtc,
      sequence: target.sequence,
      reason: command.reason,
      idempotencyKey: '${command.dataEpoch}:${command.operationId}',
      revision: 1,
    );
    await repository.insertEvidence(reversal);
    final restored = fragment.copyWith(
      completedMicros: (fragment.completedMicros - target.amountMicros).clamp(
        0,
        fragment.allocatedMicros,
      ),
      state: ExecutionFragmentState.planned,
      completedAtUtc: null,
      revision: fragment.revision + 1,
    );
    await repository.updateFragment(restored);
    await _enqueueOutbox(
      dataEpoch: command.dataEpoch,
      targetRevision: restored.revision,
      effectType: 'recurringFragmentCompletionUndone',
      payload: {
        'fragmentId': restored.fragmentId,
        'cycleId': restored.cycleId,
        'evidenceId': reversal.evidenceId,
      },
    );
    await _refreshCycleState(fragment.cycleId);
    return FragmentCommandResult(
      status: FragmentCommandStatus.applied,
      fragment: restored,
      evidenceId: reversal.evidenceId,
      amountMicros: target.amountMicros,
    );
  });

  Future<int> effectiveMinutesForCycle(String cycleId) async {
    final fragments = await repository.fragmentsForCycle(cycleId);
    final micros = fragments.isEmpty
        ? await repository.effectiveMicrosForCycle(cycleId)
        : fragments.fold<int>(0, (sum, item) => sum + item.completedMicros);
    return (micros + 59999999) ~/ 60000000;
  }

  Future<void> _enqueueOutbox({
    required String dataEpoch,
    required int targetRevision,
    required String effectType,
    required Map<String, Object?> payload,
  }) async {
    final now = clock.nowUtc();
    await executionRepository.insertOutbox(
      d.ExecutionOutboxEntry(
        effectId: idGenerator.next(),
        dataEpoch: dataEpoch,
        sourceTransaction: 'recurringProgress',
        targetRevision: targetRevision,
        effectType: effectType,
        payload: payload,
        attempts: 0,
        createdAtUtc: now,
        nextAttemptAtUtc: now,
        processedAtUtc: null,
      ),
    );
  }

  Future<void> _refreshCycleState(String? cycleId) async {
    if (cycleId == null) return;
    final snapshot = await repository.findCycleSnapshot(cycleId);
    if (snapshot == null || !snapshot.isOpen) return;
    final fragments = await repository.fragmentsForCycle(cycleId);
    final effective = fragments.fold<int>(
      0,
      (sum, item) => sum + item.completedMicros,
    );
    final targetMicros = snapshot.effectiveTargetMinutes * 60000000;
    if (effective >= targetMicros) {
      await repository.upsertCycleSnapshot(
        snapshot.copyWith(
          state: RecurringCycleStatus.met,
          revision: snapshot.revision + 1,
          updatedAtUtc: clock.nowUtc(),
        ),
      );
    }
  }
}
