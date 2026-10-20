import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:personal_planner/application/execution/execution_availability.dart';
import 'package:personal_planner/application/execution/execution_commands.dart';
import 'package:personal_planner/application/execution/execution_input_hashes.dart';
import 'package:personal_planner/application/execution/execution_notification_settings.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_models.dart' as d;
import 'package:personal_planner/domain/execution/execution_progress.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

/// 今日页与执行条读取的运行时状态（规范 §6、§7）。
final class ExecutionStatus {
  ExecutionStatus({
    required this.runtime,
    required this.activeSession,
    required this.nowUtc,
    required this.occurrences,
  });

  final d.ExecutionRuntimeState runtime;
  final d.ExecutionSessionSnapshot? activeSession;
  final DateTime nowUtc;

  /// 查询窗口内的执行实例（默认是今天）。
  final List<d.ExecutionOccurrence> occurrences;

  d.ExecutionOccurrence? occurrenceForTask(String taskId) =>
      occurrences.where((item) => item.taskId == taskId).firstOrNull;

  int get runtimeRevision => runtime.revision;

  String get dataEpoch => runtime.dataEpoch;
}

/// 执行命令的唯一写入路径（规范 §19.3、§19.4）。
///
/// **三阶段**：读取快照 → 在数据库事务里准备并提交会话、活动段、事件、进度、关联与 outbox
/// → 事务成功后才接纳内存状态并通知界面。任何一步失败都返回 `storageFailed`，不会出现
/// "界面显示已开始、库里没有记录"。
final class DriftExecutionService implements ExecutionService {
  DriftExecutionService({
    required this.repository,
    required this.tasks,
    required this.clock,
    required this.monotonicClock,
    required this.idGenerator,
    required this.availability,
    this.notificationSettings = const DisabledExecutionNotifications(),
    this.updateSafety,
    this.onChanged,
  });

  final DriftExecutionRepository repository;
  final TaskRepository tasks;
  final Clock clock;
  final MonotonicClock monotonicClock;
  final IdGenerator idGenerator;
  final ExecutionAvailabilityPort availability;
  final ExecutionNotificationSettingsPort notificationSettings;

  /// 运行会话阻塞更新安装（规范 §11、§21.3）；为空时不影响更新入口。
  final UpdateSafetyCoordinator? updateSafety;

  /// 提交成功后的界面失效通知。不能用于补写业务事实。
  final void Function()? onChanged;

  String? _lastMonotonicSession;
  Duration? _lastMonotonicMark;
  UpdateBlockerLease? _sessionLease;

  void _acquireSessionLease() {
    _sessionLease ??= updateSafety?.begin(UpdateBlocker.executionSession);
  }

  void _releaseSessionLease() {
    _sessionLease?.release();
    _sessionLease = null;
  }

  /// 释放更新阻塞租约；应用关闭时由组合根调用。
  void dispose() => _releaseSessionLease();

  // ── 只读状态 ─────────────────────────────────────────────────────────────

  Future<ExecutionStatus> status({
    DateTime? windowStartUtc,
    DateTime? windowEndUtc,
  }) async {
    final now = clock.nowUtc();
    final runtime = await repository.ensureRuntimeState();
    final active = await repository.sessionSnapshot(
      runtime.activeSessionId ?? '',
      runtimeRevision: runtime.revision,
    );
    final start = windowStartUtc ?? DateTime.utc(now.year, now.month, now.day);
    final end = windowEndUtc ?? start.add(const Duration(days: 1));
    final occurrences = await repository.occurrencesInWindow(
      startUtc: start,
      endUtc: end,
    );
    return ExecutionStatus(
      runtime: runtime,
      activeSession: active?.isActive == true ? active : null,
      nowUtc: now,
      occurrences: occurrences,
    );
  }

  Future<d.ExecutionSessionSnapshot?> activeSession() async {
    final runtime = await repository.runtimeState();
    final id = runtime?.activeSessionId;
    if (id == null) return null;
    return repository.sessionSnapshot(id, runtimeRevision: runtime!.revision);
  }

  // ── start ────────────────────────────────────────────────────────────────

  @override
  Future<ExecutionCommandResult> start(
    StartExecutionCommand command,
  ) => _execute(command, (context) async {
    final runtime = context.runtime;
    if (runtime.revision != command.runtimeRevision) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
        parameters: {'currentRuntimeRevision': runtime.revision},
      );
    }
    final task = await tasks.getById(command.taskId);
    if (task == null) {
      return _failure(
        command,
        ExecutionResultStatus.notFound,
        ExecutionReasonCode.entityNotFound,
      );
    }
    if (task.status.isClosed) {
      return _failure(
        command,
        ExecutionResultStatus.invalid,
        ExecutionReasonCode.taskClosed,
      );
    }
    if (executionTaskInputHash(task) != command.taskInputHash) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
      );
    }
    d.ExecutionOccurrence? occurrence;
    if (command.occurrenceId case final occurrenceId?) {
      occurrence = await repository.findOccurrence(occurrenceId);
      if (occurrence == null) {
        return _failure(
          command,
          ExecutionResultStatus.notFound,
          ExecutionReasonCode.entityNotFound,
        );
      }
      if (occurrence.taskId != task.id) {
        return _failure(
          command,
          ExecutionResultStatus.invalid,
          ExecutionReasonCode.taskUnavailable,
        );
      }
      if (occurrence.revision != command.occurrenceRevision) {
        return _failure(
          command,
          ExecutionResultStatus.stale,
          ExecutionReasonCode.revisionMismatch,
        );
      }
      if (occurrence.isTerminal) {
        return _failure(
          command,
          ExecutionResultStatus.stale,
          ExecutionReasonCode.illegalTransition,
        );
      }
      if (occurrence.remainingAllocationMicros <= 0) {
        return _failure(
          command,
          ExecutionResultStatus.invalid,
          ExecutionReasonCode.noRemainingWork,
        );
      }
    }
    if (command.mode == d.ExecutionMode.planned && task.remainingMinutes <= 0) {
      return _failure(
        command,
        ExecutionResultStatus.invalid,
        ExecutionReasonCode.noRemainingWork,
      );
    }

    final current = await _resolveActiveSession(runtime);
    if (current != null) {
      final sameOccurrence =
          occurrence != null && current.occurrenceId == occurrence.id;
      final sameUnlinkedTask =
          occurrence == null &&
          current.occurrenceId == null &&
          current.taskId == task.id;
      if (sameOccurrence || sameUnlinkedTask) {
        // 同一实例已有会话：返回其身份（规范 §19.3 的 start 返回语义）。
        return ExecutionCommandResult.alreadyApplied(
          operationId: command.operationId,
          occurrenceId: current.occurrenceId,
          sessionId: current.sessionId,
          revision: current.revision,
        );
      }
      return _failure(
        command,
        ExecutionResultStatus.activeSessionConflict,
        ExecutionReasonCode.activeSessionConflict,
        parameters: {
          'activeSessionId': current.sessionId,
          'activeOccurrenceId': current.occurrenceId,
          'activeTaskId': current.taskId,
        },
      );
    }

    ExecutionAvailability? gate;
    if (command.mode == d.ExecutionMode.planned) {
      gate = await availability.at(
        nowUtc: context.now,
        taskId: task.id,
        occurrenceId: occurrence?.id,
      );
      if (!gate.canStartPlanned) {
        return _failure(
          command,
          ExecutionResultStatus.blockedByHardBoundary,
          gate.taskAvailable
              ? ExecutionReasonCode.hardBoundaryBlocked
              : ExecutionReasonCode.taskUnavailable,
          parameters: {
            'blockerKind': gate.blockerKind,
            'nextAvailableUtc': gate.nextAvailableUtc?.toIso8601String(),
          },
        );
      }
      final target = command.targetDurationMicros;
      if (target != null && target > gate.availableMicros) {
        return _failure(
          command,
          ExecutionResultStatus.blockedByHardBoundary,
          ExecutionReasonCode.hardBoundaryBlocked,
          parameters: {
            'blockerKind': 'insufficientContinuousTime',
            'availableMicros': gate.availableMicros,
            'boundaryUtc': gate.boundaryUtc.toIso8601String(),
          },
        );
      }
    }

    final sessionId = idGenerator.next();
    await repository.insertTimeEntry(
      id: sessionId,
      taskId: task.id,
      startedAtUtc: context.now,
      phase: d.ExecutionSessionState.running,
      activeMicros: 0,
      lastReliableAtUtc: context.now,
      note: '',
    );
    await repository.insertSessionLink(
      d.ExecutionSessionLink(
        sessionId: sessionId,
        dataEpoch: runtime.dataEpoch,
        occurrenceId: occurrence?.id,
        source: d.ExecutionActivitySource.realtime,
        mode: command.mode,
        firstAcceptedSequence: null,
        revision: 1,
        createdAtUtc: context.now,
        updatedAtUtc: context.now,
      ),
    );
    await context.addEvent(
      type: d.ExecutionEventType.started,
      occurredAtUtc: context.now,
      source: d.ExecutionActivitySource.realtime,
      occurrenceId: occurrence?.id,
      payload: {
        'mode': command.mode.name,
        'targetDurationMicros': command.targetDurationMicros,
        'hardBoundaryInputHash': gate?.hardBoundaryInputHash,
      },
    );
    final freshRuntime = await repository.ensureRuntimeState();
    final updatedRuntime = freshRuntime.copyWith(
      activeSessionId: sessionId,
      revision: freshRuntime.revision + 1,
      updatedAtUtc: context.now,
    );
    await repository.writeRuntimeState(updatedRuntime);
    _markMonotonic(sessionId);
    _acquireSessionLease();
    return ExecutionCommandResult.applied(
      operationId: command.operationId,
      occurrenceId: occurrence?.id,
      sessionId: sessionId,
      revision: 1,
      parameters: {
        if (gate != null) 'hardBoundaryInputHash': gate.hardBoundaryInputHash,
      },
    );
  }, notify: true);

  // ── pause ────────────────────────────────────────────────────────────────

  @override
  Future<ExecutionCommandResult> pause(PauseExecutionCommand command) =>
      _execute(command, (context) async {
        final runtime = await _runtimeFor(context);
        if (runtime.revision != command.runtimeRevision) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.revisionMismatch,
            parameters: {'currentRuntimeRevision': runtime.revision},
          );
        }
        final snapshot = await repository.sessionSnapshot(
          command.sessionId,
          runtimeRevision: runtime.revision,
        );
        if (snapshot == null) {
          return _failure(
            command,
            ExecutionResultStatus.notFound,
            ExecutionReasonCode.entityNotFound,
          );
        }
        if (runtime.activeSessionId != command.sessionId) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.illegalTransition,
          );
        }
        if (snapshot.revision != command.sessionRevision) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.revisionMismatch,
            parameters: {'currentSessionRevision': snapshot.revision},
          );
        }
        if (snapshot.state == d.ExecutionSessionState.paused) {
          return ExecutionCommandResult.alreadyApplied(
            operationId: command.operationId,
            occurrenceId: snapshot.occurrenceId,
            sessionId: snapshot.sessionId,
            revision: snapshot.revision,
          );
        }
        if (snapshot.state != d.ExecutionSessionState.running &&
            snapshot.state != d.ExecutionSessionState.recoveryPending) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.illegalTransition,
          );
        }

        final occurrence = snapshot.occurrenceId == null
            ? null
            : await repository.findOccurrence(snapshot.occurrenceId!);
        d.ExecutionProgressAnchor? anchor;
        final sessionTask = await tasks.getById(snapshot.taskId);
        if (sessionTask != null) anchor = await _ensureAnchor(sessionTask);

        final closed = await _closeRunningSegment(context, snapshot);
        var updatedOccurrence = occurrence;
        if (closed != null && closed.durationMicros > 0 && anchor != null) {
          updatedOccurrence = await _applyActivity(
            context,
            snapshot: snapshot,
            occurrence: occurrence,
            segment: closed,
            anchor: anchor,
          );
        }
        final activeMicros =
            snapshot.activeMicros + (closed?.durationMicros ?? 0);
        await repository.updateTimeEntry(
          id: snapshot.sessionId,
          phase: d.ExecutionSessionState.paused,
          activeMicros: activeMicros,
          lastReliableAtUtc: context.now,
          pausedMinutes: 0,
        );
        final link = await repository.findSessionLink(snapshot.sessionId);
        if (link != null) {
          await repository.updateSessionLink(
            d.ExecutionSessionLink(
              sessionId: link.sessionId,
              dataEpoch: link.dataEpoch,
              occurrenceId: link.occurrenceId,
              source: link.source,
              mode: link.mode,
              firstAcceptedSequence: link.firstAcceptedSequence,
              revision: link.revision + 1,
              createdAtUtc: link.createdAtUtc,
              updatedAtUtc: context.now,
            ),
          );
        }
        await context.addEvent(
          type: d.ExecutionEventType.paused,
          occurredAtUtc: context.now,
          source: d.ExecutionActivitySource.realtime,
          occurrenceId: snapshot.occurrenceId,
          payload: {
            'activeMicros': activeMicros,
            'segmentMicros': closed?.durationMicros ?? 0,
            'clockAnomaly': closed?.clockAnomaly ?? false,
            'systemReason': command.systemReason,
          },
        );
        _clearMonotonic();
        return ExecutionCommandResult.applied(
          operationId: command.operationId,
          occurrenceId: updatedOccurrence?.id ?? snapshot.occurrenceId,
          sessionId: snapshot.sessionId,
          revision: snapshot.revision + 1,
          parameters: {'activeMicros': activeMicros},
        );
      }, notify: true);

  // ── resume ───────────────────────────────────────────────────────────────

  @override
  Future<ExecutionCommandResult> resume(ResumeExecutionCommand command) =>
      _execute(command, (context) async {
        final runtime = await _runtimeFor(context);
        if (runtime.revision != command.runtimeRevision) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.revisionMismatch,
            parameters: {'currentRuntimeRevision': runtime.revision},
          );
        }
        final snapshot = await repository.sessionSnapshot(
          command.sessionId,
          runtimeRevision: runtime.revision,
        );
        if (snapshot == null) {
          return _failure(
            command,
            ExecutionResultStatus.notFound,
            ExecutionReasonCode.entityNotFound,
          );
        }
        if (runtime.activeSessionId != command.sessionId) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.illegalTransition,
          );
        }
        if (snapshot.revision != command.sessionRevision) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.revisionMismatch,
            parameters: {'currentSessionRevision': snapshot.revision},
          );
        }
        if (snapshot.state == d.ExecutionSessionState.running) {
          return ExecutionCommandResult.alreadyApplied(
            operationId: command.operationId,
            occurrenceId: snapshot.occurrenceId,
            sessionId: snapshot.sessionId,
            revision: snapshot.revision,
          );
        }
        if (snapshot.state == d.ExecutionSessionState.finished) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.illegalTransition,
          );
        }
        if (command.mode == d.ExecutionMode.planned) {
          final gate = await availability.at(
            nowUtc: context.now,
            taskId: snapshot.taskId,
            occurrenceId: snapshot.occurrenceId,
          );
          if (gate.hardBoundaryInputHash != command.hardBoundaryInputHash) {
            return _failure(
              command,
              ExecutionResultStatus.stale,
              ExecutionReasonCode.revisionMismatch,
              parameters: {
                'currentHardBoundaryInputHash': gate.hardBoundaryInputHash,
              },
            );
          }
          if (!gate.canStartPlanned) {
            return _failure(
              command,
              ExecutionResultStatus.blockedByHardBoundary,
              ExecutionReasonCode.hardBoundaryBlocked,
              parameters: {
                'blockerKind': gate.blockerKind,
                'nextAvailableUtc': gate.nextAvailableUtc?.toIso8601String(),
              },
            );
          }
        }
        await repository.updateTimeEntry(
          id: snapshot.sessionId,
          phase: d.ExecutionSessionState.running,
          activeMicros: snapshot.activeMicros,
          lastReliableAtUtc: context.now,
        );
        final link = await repository.findSessionLink(snapshot.sessionId);
        if (link == null) {
          return _failure(
            command,
            ExecutionResultStatus.notFound,
            ExecutionReasonCode.entityNotFound,
          );
        }
        await repository.updateSessionLink(
          d.ExecutionSessionLink(
            sessionId: link.sessionId,
            dataEpoch: link.dataEpoch,
            occurrenceId: link.occurrenceId,
            source: link.source,
            mode: command.mode,
            firstAcceptedSequence: link.firstAcceptedSequence,
            revision: link.revision + 1,
            createdAtUtc: link.createdAtUtc,
            updatedAtUtc: context.now,
          ),
        );
        await context.addEvent(
          type: d.ExecutionEventType.resumed,
          occurredAtUtc: context.now,
          source: d.ExecutionActivitySource.realtime,
          occurrenceId: snapshot.occurrenceId,
          payload: {
            'activeMicros': snapshot.activeMicros,
            'fromState': snapshot.state.name,
          },
        );
        _markMonotonic(snapshot.sessionId);
        return ExecutionCommandResult.applied(
          operationId: command.operationId,
          occurrenceId: snapshot.occurrenceId,
          sessionId: snapshot.sessionId,
          revision: snapshot.revision + 1,
        );
      }, notify: true);

  // ── finish ───────────────────────────────────────────────────────────────

  @override
  Future<ExecutionCommandResult> finish(FinishExecutionCommand command) =>
      _execute(command, (context) async {
        final runtime = await _runtimeFor(context);
        if (runtime.revision != command.runtimeRevision) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.revisionMismatch,
            parameters: {'currentRuntimeRevision': runtime.revision},
          );
        }
        final snapshot = await repository.sessionSnapshot(
          command.sessionId,
          runtimeRevision: runtime.revision,
        );
        if (snapshot == null) {
          return _failure(
            command,
            ExecutionResultStatus.notFound,
            ExecutionReasonCode.entityNotFound,
          );
        }
        if (runtime.activeSessionId != command.sessionId) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.illegalTransition,
          );
        }
        if (snapshot.revision != command.sessionRevision) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.revisionMismatch,
            parameters: {'currentSessionRevision': snapshot.revision},
          );
        }
        if (snapshot.state == d.ExecutionSessionState.finished) {
          return ExecutionCommandResult.alreadyApplied(
            operationId: command.operationId,
            occurrenceId: snapshot.occurrenceId,
            sessionId: snapshot.sessionId,
            revision: snapshot.revision,
          );
        }

        var occurrence = snapshot.occurrenceId == null
            ? null
            : await repository.findOccurrence(snapshot.occurrenceId!);
        d.ExecutionProgressAnchor? anchor;
        final sessionTask = await tasks.getById(snapshot.taskId);
        if (sessionTask != null) anchor = await _ensureAnchor(sessionTask);

        final closed = snapshot.state == d.ExecutionSessionState.running
            ? await _closeRunningSegment(context, snapshot)
            : null;
        if (closed != null && closed.durationMicros > 0 && anchor != null) {
          occurrence = await _applyActivity(
            context,
            snapshot: snapshot,
            occurrence: occurrence,
            segment: closed,
            anchor: anchor,
          );
        }
        final activeMicros =
            snapshot.activeMicros + (closed?.durationMicros ?? 0);

        if (occurrence != null && !occurrence.isTerminal) {
          var updated = occurrence.copyWith(revision: occurrence.revision + 1);
          final abandoned =
              command.abandonOccurrenceRemaining &&
              updated.remainingAllocationMicros > 0;
          if (abandoned) {
            updated = updated.copyWith(remainingAllocationMicros: 0);
          }
          await context.addEvent(
            type: d.ExecutionEventType.finished,
            occurredAtUtc: context.now,
            source: d.ExecutionActivitySource.realtime,
            occurrenceId: updated.id,
            payload: {
              'activeMicros': activeMicros,
              'abandonedRemainingMicros': abandoned
                  ? occurrence.remainingAllocationMicros
                  : 0,
              'barrierReason': command.barrierReason?.name,
              'note': command.note,
            },
          );
          if (updated.remainingAllocationMicros == 0) {
            updated = updated.copyWith(
              lifecycleState: d.ExecutionLifecycleState.finished,
            );
          }
          await repository.updateOccurrence(updated);
          occurrence = updated;
        } else {
          await context.addEvent(
            type: d.ExecutionEventType.finished,
            occurredAtUtc: context.now,
            source: d.ExecutionActivitySource.realtime,
            occurrenceId: occurrence?.id,
            payload: {
              'activeMicros': activeMicros,
              'barrierReason': command.barrierReason?.name,
              'note': command.note,
            },
          );
        }

        await repository.updateTimeEntry(
          id: snapshot.sessionId,
          phase: d.ExecutionSessionState.finished,
          activeMicros: activeMicros,
          lastReliableAtUtc: context.now,
          endedAtUtc: context.now,
          note: command.note,
        );
        final link = await repository.findSessionLink(snapshot.sessionId);
        if (link != null) {
          await repository.updateSessionLink(
            d.ExecutionSessionLink(
              sessionId: link.sessionId,
              dataEpoch: link.dataEpoch,
              occurrenceId: link.occurrenceId,
              source: link.source,
              mode: link.mode,
              firstAcceptedSequence: link.firstAcceptedSequence,
              revision: link.revision + 1,
              createdAtUtc: link.createdAtUtc,
              updatedAtUtc: context.now,
            ),
          );
        }
        await repository.writeRuntimeState(
          runtime.copyWith(
            clearActiveSessionId: true,
            revision: runtime.revision + 1,
            updatedAtUtc: context.now,
          ),
        );
        _clearMonotonic();
        _releaseSessionLease();
        return ExecutionCommandResult.applied(
          operationId: command.operationId,
          occurrenceId: occurrence?.id ?? snapshot.occurrenceId,
          sessionId: snapshot.sessionId,
          revision: runtime.revision + 1,
          parameters: {
            'activeMicros': activeMicros,
            'occurrenceState': occurrence?.lifecycleState.name,
          },
        );
      }, notify: true);

  // ── recordManual ─────────────────────────────────────────────────────────

  @override
  Future<ExecutionCommandResult> recordManual(
    RecordManualExecutionCommand command,
  ) => _execute(command, (context) async {
    final now = context.now;
    if (command.segmentEndUtc.isAfter(now)) {
      return _failure(
        command,
        ExecutionResultStatus.invalid,
        ExecutionReasonCode.invalidDuration,
      );
    }
    final durationMicros = command.segmentEndUtc
        .difference(command.segmentStartUtc)
        .inMicroseconds;
    if (durationMicros <= 0) {
      return _failure(
        command,
        ExecutionResultStatus.invalid,
        ExecutionReasonCode.invalidDuration,
      );
    }
    final noteError = d.executionNoteError(command.note);
    if (noteError != null) {
      return _failure(
        command,
        ExecutionResultStatus.invalid,
        ExecutionReasonCode.invalidNote,
      );
    }
    final task = await tasks.getById(command.taskId);
    if (task == null) {
      return _failure(
        command,
        ExecutionResultStatus.notFound,
        ExecutionReasonCode.entityNotFound,
      );
    }
    if (executionTaskInputHash(task) != command.taskInputHash) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
      );
    }
    d.ExecutionOccurrence? occurrence;
    if (command.occurrenceId case final occurrenceId?) {
      occurrence = await repository.findOccurrence(occurrenceId);
      if (occurrence == null) {
        return _failure(
          command,
          ExecutionResultStatus.notFound,
          ExecutionReasonCode.entityNotFound,
        );
      }
      if (occurrence.revision != command.occurrenceRevision) {
        return _failure(
          command,
          ExecutionResultStatus.stale,
          ExecutionReasonCode.revisionMismatch,
        );
      }
    }

    final anchor = await _ensureAnchor(task);
    if (command.progressAnchorRevision != 0 &&
        command.progressAnchorRevision != anchor.revision) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
        parameters: {'currentProgressAnchorRevision': anchor.revision},
      );
    }

    // 晚补记早于人工剩余检查点：必须由用户明确回答"是否已包含"（规范 §10.2）。
    if (command.segmentStartUtc.isBefore(anchor.createdAtUtc) &&
        command.includedInAnchor == null) {
      return _failure(
        command,
        ExecutionResultStatus.needsConfirmation,
        ExecutionReasonCode.confirmationRequired,
        confirmationToken: _token(command.requestHash(), [
          'late-${anchor.revision}',
        ]),
        parameters: {
          'confirmationKind': 'lateWithinAnchor',
          'anchorCreatedAtUtc': anchor.createdAtUtc.toIso8601String(),
          'anchorRevision': anchor.revision,
        },
      );
    }

    final overlaps = await repository.overlappingSegments(
      startUtc: command.segmentStartUtc,
      endUtc: command.segmentEndUtc,
      taskId: task.id,
    );
    if (overlaps.isNotEmpty) {
      if (command.overlapResolution == null) {
        return _failure(
          command,
          ExecutionResultStatus.needsConfirmation,
          ExecutionReasonCode.overlapNeedsConfirmation,
          confirmationToken: _token(command.requestHash(), [
            for (final segment in overlaps) segment.segmentId,
          ]),
          parameters: {
            'confirmationKind': 'overlap',
            'overlappingRecords': [
              for (final segment in overlaps)
                {
                  'recordId': segment.sessionId,
                  'segmentId': segment.segmentId,
                  'startUtc': segment.startUtc.toIso8601String(),
                  'endUtc': segment.endUtc.toIso8601String(),
                },
            ],
          },
        );
      }
      if (command.overlapResolution ==
          d.ExecutionOverlapResolution.allocateExplicit) {
        return _failure(
          command,
          ExecutionResultStatus.invalid,
          ExecutionReasonCode.unsupported,
        );
      }
      if (command.overlapResolution ==
          d.ExecutionOverlapResolution.replaceExisting) {
        for (final segment in overlaps) {
          await repository.invalidateSegment(
            segment.segmentId,
            'replacedByManualRecord',
          );
          await repository.deleteCreditsForSegment(segment.segmentId);
          final oldTaskId = await _taskIdForSession(segment.sessionId);
          if (oldTaskId != null) {
            final oldAnchor = await _anchorForTaskId(oldTaskId);
            if (oldAnchor != null) {
              await _writeProgressForAnchor(oldTaskId, oldAnchor);
            }
          }
        }
      }
    }

    final credit =
        command.includedInAnchor != true &&
        command.overlapResolution !=
            d.ExecutionOverlapResolution.saveNonCrediting;
    final intervals =
        command.overlapResolution == d.ExecutionOverlapResolution.shortenNew
        ? _subtractIntervals(
            command.segmentStartUtc,
            command.segmentEndUtc,
            overlaps,
          )
        : [(startUtc: command.segmentStartUtc, endUtc: command.segmentEndUtc)];
    if (intervals.isEmpty) {
      return _failure(
        command,
        ExecutionResultStatus.invalid,
        ExecutionReasonCode.overlapRejected,
      );
    }

    final sessionId = idGenerator.next();
    final totalMicros = intervals.fold<int>(
      0,
      (sum, interval) =>
          sum + interval.endUtc.difference(interval.startUtc).inMicroseconds,
    );
    await repository.insertTimeEntry(
      id: sessionId,
      taskId: task.id,
      startedAtUtc: intervals.first.startUtc,
      phase: d.ExecutionSessionState.finished,
      activeMicros: totalMicros,
      lastReliableAtUtc: intervals.last.endUtc,
      note: command.note,
    );
    await repository.updateTimeEntry(
      id: sessionId,
      phase: d.ExecutionSessionState.finished,
      activeMicros: totalMicros,
      lastReliableAtUtc: intervals.last.endUtc,
      note: command.note,
      endedAtUtc: intervals.last.endUtc,
    );
    await repository.insertSessionLink(
      d.ExecutionSessionLink(
        sessionId: sessionId,
        dataEpoch: context.runtime.dataEpoch,
        occurrenceId: occurrence?.id,
        source: d.ExecutionActivitySource.manual,
        mode: d.ExecutionMode.planned,
        firstAcceptedSequence: null,
        revision: 1,
        createdAtUtc: now,
        updatedAtUtc: now,
      ),
    );
    var updatedOccurrence = occurrence;
    for (var index = 0; index < intervals.length; index++) {
      final interval = intervals[index];
      final segment = d.ExecutionActivitySegment(
        segmentId: idGenerator.next(),
        dataEpoch: context.runtime.dataEpoch,
        sessionId: sessionId,
        sequence: index + 1,
        startUtc: interval.startUtc,
        endUtc: interval.endUtc,
        source: d.ExecutionActivitySource.manual,
        invalidatedReason: null,
        createdAtUtc: now,
      );
      await repository.insertActivitySegment(segment);
      if (credit) {
        updatedOccurrence =
            await _applyActivity(
              context,
              snapshot: d.ExecutionSessionSnapshot(
                sessionId: sessionId,
                occurrenceId: occurrence?.id,
                taskId: task.id,
                state: d.ExecutionSessionState.finished,
                source: d.ExecutionActivitySource.manual,
                mode: d.ExecutionMode.planned,
                startedAtUtc: intervals.first.startUtc,
                activeMicros: totalMicros,
                revision: 1,
                lastReliableAtUtc: intervals.last.endUtc,
              ),
              occurrence: updatedOccurrence,
              segment: _ClosedActivity(
                segment: segment,
                durationMicros: interval.endUtc
                    .difference(interval.startUtc)
                    .inMicroseconds,
                clockAnomaly: false,
              ),
              anchor: anchor,
              occurrenceStartUtc: intervals.first.startUtc,
              source: d.ExecutionActivitySource.manual,
            ) ??
            updatedOccurrence;
      }
    }
    // 即使本次补记选择"已包含在上次剩余修正中"、不扣当前剩余，它仍是实际投入，
    // 必须留下启动证据（规范 §10.1：零投入会话不算，但正时长的补记算）。
    if (updatedOccurrence != null &&
        updatedOccurrence.firstStartEvidenceId == null) {
      final started = await context.addEvent(
        type: d.ExecutionEventType.started,
        occurredAtUtc: command.segmentStartUtc,
        source: d.ExecutionActivitySource.manual,
        occurrenceId: updatedOccurrence.id,
        payload: {
          'evidence': 'manualRecord',
          'includedInAnchor': command.includedInAnchor,
        },
      );
      updatedOccurrence = updatedOccurrence.copyWith(
        firstStartEvidenceId: started.eventId,
        lifecycleState: d.ExecutionLifecycleState.started,
        revision: updatedOccurrence.revision + 1,
      );
      await repository.updateOccurrence(updatedOccurrence);
    }
    await context.addEvent(
      type: d.ExecutionEventType.manualRecorded,
      occurredAtUtc: command.segmentStartUtc,
      source: d.ExecutionActivitySource.manual,
      occurrenceId: occurrence?.id,
      payload: {
        'startUtc': command.segmentStartUtc.toIso8601String(),
        'endUtc': command.segmentEndUtc.toIso8601String(),
        'creditedMicros': credit ? totalMicros : 0,
        'includedInAnchor': command.includedInAnchor,
        'note': command.note,
      },
    );
    return ExecutionCommandResult.applied(
      operationId: command.operationId,
      occurrenceId: updatedOccurrence?.id ?? occurrence?.id,
      sessionId: sessionId,
      parameters: {
        'creditedMicros': credit ? totalMicros : 0,
        'recordedMicros': totalMicros,
      },
    );
  }, notify: true);

  // ── correctRecord ────────────────────────────────────────────────────────

  @override
  Future<ExecutionCommandResult> correctRecord(
    CorrectExecutionRecordCommand command,
  ) => _execute(command, (context) async {
    final noteError = d.executionNoteError(command.note);
    if (noteError != null) {
      return _failure(
        command,
        ExecutionResultStatus.invalid,
        ExecutionReasonCode.invalidNote,
      );
    }
    if (!command.segmentEndUtc.isAfter(command.segmentStartUtc) ||
        command.segmentEndUtc.isAfter(context.now)) {
      return _failure(
        command,
        ExecutionResultStatus.invalid,
        ExecutionReasonCode.invalidDuration,
      );
    }
    final entry = await repository.findTimeEntry(command.recordId);
    final link = await repository.findSessionLink(command.recordId);
    if (entry == null || link == null) {
      return _failure(
        command,
        ExecutionResultStatus.notFound,
        ExecutionReasonCode.entityNotFound,
      );
    }
    if (link.revision != command.recordRevision) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
        parameters: {'currentRecordRevision': link.revision},
      );
    }
    final oldSegments = [
      for (final segment in await repository.segmentsForSession(
        command.recordId,
      ))
        if (segment.invalidatedReason == null) segment,
    ];
    final oldTaskIds = <String>{};
    int? preservedSequence;
    for (final segment in oldSegments) {
      final credits = await repository.creditsForSegment(segment.segmentId);
      for (final credit in credits) {
        if (credit.targetKind == d.ExecutionTargetKind.task) {
          oldTaskIds.add(credit.targetId);
        }
        // 更正保留首次入账序号：修正一条锚点之前的旧记录，不应反向改写较新的人工剩余。
        if (preservedSequence == null ||
            credit.firstAcceptedSequence < preservedSequence) {
          preservedSequence = credit.firstAcceptedSequence;
        }
      }
    }
    final newTaskId = command.newTargetKind == d.ExecutionTargetKind.task
        ? command.newTargetId
        : await _taskIdForCycle(command.newTargetId);
    final oldAnchors = <String, d.ExecutionProgressAnchor>{};
    for (final taskId in oldTaskIds) {
      final anchor = await _anchorForTaskId(taskId);
      if (anchor != null) oldAnchors[taskId] = anchor;
    }
    d.ExecutionProgressAnchor? newAnchor;
    if (newTaskId != null) {
      final task = await tasks.getById(newTaskId);
      if (task == null) {
        return _failure(
          command,
          ExecutionResultStatus.notFound,
          ExecutionReasonCode.entityNotFound,
        );
      }
      newAnchor = await _ensureAnchor(task);
      if (command.newTargetProgressAnchorRevision != 0 &&
          newAnchor.revision != command.newTargetProgressAnchorRevision) {
        return _failure(
          command,
          ExecutionResultStatus.stale,
          ExecutionReasonCode.revisionMismatch,
        );
      }
    }
    if (command.oldTargetProgressAnchorRevision != null &&
        oldAnchors.values.any(
          (anchor) =>
              anchor.revision != command.oldTargetProgressAnchorRevision,
        )) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
      );
    }

    for (final segment in oldSegments) {
      await repository.invalidateSegment(segment.segmentId, 'corrected');
      await repository.deleteCreditsForSegment(segment.segmentId);
    }
    final segment = d.ExecutionActivitySegment(
      segmentId: idGenerator.next(),
      dataEpoch: context.runtime.dataEpoch,
      sessionId: command.recordId,
      sequence: await repository.nextSegmentSequence(command.recordId),
      startUtc: command.segmentStartUtc,
      endUtc: command.segmentEndUtc,
      source: link.source,
      invalidatedReason: null,
      createdAtUtc: context.now,
    );
    await repository.insertActivitySegment(segment);
    if (newAnchor != null && newTaskId != null) {
      await _applyActivity(
        context,
        snapshot: d.ExecutionSessionSnapshot(
          sessionId: command.recordId,
          occurrenceId: link.occurrenceId,
          taskId: newTaskId,
          state: d.ExecutionSessionState.finished,
          source: link.source,
          mode: link.mode,
          startedAtUtc: command.segmentStartUtc,
          activeMicros: command.segmentEndUtc
              .difference(command.segmentStartUtc)
              .inMicroseconds,
          revision: link.revision,
          lastReliableAtUtc: command.segmentEndUtc,
        ),
        occurrence: link.occurrenceId == null
            ? null
            : await repository.findOccurrence(link.occurrenceId!),
        segment: _ClosedActivity(
          segment: segment,
          durationMicros: command.segmentEndUtc
              .difference(command.segmentStartUtc)
              .inMicroseconds,
          clockAnomaly: false,
        ),
        anchor: newAnchor,
        occurrenceStartUtc: command.segmentStartUtc,
        source: link.source,
        firstAcceptedSequence: oldTaskIds.contains(newTaskId)
            ? preservedSequence
            : null,
      );
    }
    if (newAnchor != null && newTaskId != null) {
      // 改归属后必须同时重算**新任务**的剩余，否则旧任务被反向恢复、新任务却不扣减。
      await _writeProgressForAnchor(newTaskId, newAnchor);
    }
    for (final taskId in oldTaskIds) {
      final anchor = oldAnchors[taskId];
      if (anchor != null) await _writeProgressForAnchor(taskId, anchor);
    }
    await repository.updateTimeEntry(
      id: command.recordId,
      phase: d.ExecutionSessionState.finished,
      activeMicros: command.segmentEndUtc
          .difference(command.segmentStartUtc)
          .inMicroseconds,
      lastReliableAtUtc: command.segmentEndUtc,
      note: command.note,
      endedAtUtc: command.segmentEndUtc,
    );
    await repository.updateSessionLink(
      d.ExecutionSessionLink(
        sessionId: link.sessionId,
        dataEpoch: link.dataEpoch,
        occurrenceId: link.occurrenceId,
        source: link.source,
        mode: link.mode,
        firstAcceptedSequence: link.firstAcceptedSequence,
        revision: link.revision + 1,
        createdAtUtc: link.createdAtUtc,
        updatedAtUtc: context.now,
      ),
    );
    await context.addEvent(
      type: d.ExecutionEventType.recordCorrected,
      occurredAtUtc: command.segmentStartUtc,
      source: link.source,
      occurrenceId: link.occurrenceId,
      payload: {
        'recordId': command.recordId,
        'startUtc': command.segmentStartUtc.toIso8601String(),
        'endUtc': command.segmentEndUtc.toIso8601String(),
        'note': command.note,
      },
    );
    return ExecutionCommandResult.applied(
      operationId: command.operationId,
      occurrenceId: link.occurrenceId,
      sessionId: command.recordId,
      revision: link.revision + 1,
    );
  }, notify: true);

  // ── setSnooze ────────────────────────────────────────────────────────────

  @override
  Future<ExecutionCommandResult> setSnooze(
    SetExecutionSnoozeCommand command,
  ) => _execute(command, (context) async {
    final occurrence = await repository.findOccurrence(command.occurrenceId);
    if (occurrence == null) {
      return _failure(
        command,
        ExecutionResultStatus.notFound,
        ExecutionReasonCode.entityNotFound,
      );
    }
    if (occurrence.revision != command.occurrenceRevision) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
      );
    }
    final targetAtUtc = context.now.add(
      Duration(minutes: command.elapsedMinutes),
    );
    final settings = await notificationSettings.snapshot(
      targetAtUtc: targetAtUtc,
    );
    if (command.notificationSettingsHash != settings.settingsHash) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
        parameters: {'currentNotificationSettingsHash': settings.settingsHash},
      );
    }
    if (!settings.canDeliver) {
      return _failure(
        command,
        ExecutionResultStatus.notificationsDisabled,
        ExecutionReasonCode.notificationsDisabled,
      );
    }
    final current = await repository.currentReminder(occurrence.id);
    final currentRevision = current?.revision ?? 0;
    if (currentRevision != command.reminderRevision) {
      return _failure(
        command,
        ExecutionResultStatus.stale,
        ExecutionReasonCode.revisionMismatch,
        parameters: {'currentReminderRevision': currentRevision},
      );
    }
    if (current != null) {
      await repository.updateReminderState(
        occurrenceId: current.occurrenceId,
        revision: current.revision,
        dataEpoch: current.dataEpoch,
        state: d.ExecutionReminderState.cancelled,
      );
    }
    final revision = currentRevision + 1;
    final notificationId = 'planner.task_start.exec.${occurrence.id}.$revision';
    final state = settings.suppressedByQuietHours
        ? d.ExecutionReminderState.suppressed
        : d.ExecutionReminderState.pending;
    await repository.insertReminder(
      d.ExecutionReminderIntent(
        dataEpoch: context.runtime.dataEpoch,
        occurrenceId: occurrence.id,
        revision: revision,
        targetAtUtc: targetAtUtc,
        notificationId: notificationId,
        state: state,
        claimedAtUtc: null,
        scheduledAtUtc: null,
        dispatchResult: null,
        createdAtUtc: context.now,
        updatedAtUtc: context.now,
      ),
    );
    await context.addEvent(
      type: d.ExecutionEventType.reminderScheduled,
      occurredAtUtc: context.now,
      source: d.ExecutionActivitySource.realtime,
      occurrenceId: occurrence.id,
      payload: {
        'targetAtUtc': targetAtUtc.toIso8601String(),
        'notificationId': notificationId,
        'state': state.name,
      },
    );
    await repository.insertOutbox(
      d.ExecutionOutboxEntry(
        effectId: idGenerator.next(),
        dataEpoch: context.runtime.dataEpoch,
        sourceTransaction: 'setSnooze:${command.operationId}',
        targetRevision: revision,
        effectType: 'reconcileExecutionReminder',
        payload: {
          'occurrenceId': occurrence.id,
          'notificationId': notificationId,
        },
        attempts: 0,
        createdAtUtc: context.now,
        nextAttemptAtUtc: context.now,
        processedAtUtc: null,
      ),
    );
    return ExecutionCommandResult.applied(
      operationId: command.operationId,
      occurrenceId: occurrence.id,
      parameters: {
        'targetAtUtc': targetAtUtc.toIso8601String(),
        'notificationId': notificationId,
        'reminderRevision': revision,
        'suppressedByQuietHours': settings.suppressedByQuietHours,
      },
    );
  }, notify: true);

  // ── 启动恢复 ─────────────────────────────────────────────────────────────

  /// 进程启动时调用：把上次未结束的实时会话标成 `recoveryPending`，不结算未知时长。
  ///
  /// 这是规范 §11.4 与 §20.1 的边界：崩溃后不能假定停机时间都在学习。用户确认后经
  /// `resume`（建立新的活动段）或 `finish`（按最后可靠检查点结算）继续。
  Future<d.ExecutionSessionSnapshot?> recoverOpenSession() async {
    return repository.transaction(() async {
      final runtime = await repository.ensureRuntimeState();
      final id = runtime.activeSessionId;
      if (id == null) {
        _releaseSessionLease();
        return null;
      }
      final snapshot = await repository.sessionSnapshot(
        id,
        runtimeRevision: runtime.revision,
      );
      if (snapshot == null ||
          snapshot.state == d.ExecutionSessionState.finished) {
        await repository.writeRuntimeState(
          runtime.copyWith(
            clearActiveSessionId: true,
            revision: runtime.revision + 1,
            updatedAtUtc: clock.nowUtc(),
          ),
        );
        _releaseSessionLease();
        return null;
      }
      _acquireSessionLease();
      if (snapshot.state != d.ExecutionSessionState.running) {
        return snapshot;
      }
      final now = clock.nowUtc();
      await repository.updateTimeEntry(
        id: id,
        phase: d.ExecutionSessionState.recoveryPending,
        activeMicros: snapshot.activeMicros,
        lastReliableAtUtc: snapshot.lastReliableAtUtc,
      );
      final link = await repository.findSessionLink(id);
      if (link != null) {
        await repository.updateSessionLink(
          d.ExecutionSessionLink(
            sessionId: link.sessionId,
            dataEpoch: link.dataEpoch,
            occurrenceId: link.occurrenceId,
            source: link.source,
            mode: link.mode,
            firstAcceptedSequence: link.firstAcceptedSequence,
            revision: link.revision + 1,
            createdAtUtc: link.createdAtUtc,
            updatedAtUtc: now,
          ),
        );
      }
      return repository.sessionSnapshot(id, runtimeRevision: runtime.revision);
    });
  }

  // ── 内部：命令执行骨架 ───────────────────────────────────────────────────

  Future<ExecutionCommandResult> _execute(
    ExecutionCommand command,
    Future<ExecutionCommandResult> Function(_ExecutionContext context) body, {
    bool notify = false,
  }) async {
    try {
      final result = await repository.transaction(() async {
        final runtime = await repository.ensureRuntimeState();
        final existing = await repository.findOperation(
          dataEpoch: command.dataEpoch,
          operationId: command.operationId,
        );
        if (existing != null) {
          if (existing.requestHash != command.requestHash()) {
            return _failure(
              command,
              ExecutionResultStatus.invalid,
              ExecutionReasonCode.operationIdReused,
            );
          }
          return existing.result.asAlreadyApplied();
        }
        if (runtime.dataEpoch != command.dataEpoch) {
          return _failure(
            command,
            ExecutionResultStatus.stale,
            ExecutionReasonCode.revisionMismatch,
            parameters: {'currentDataEpoch': runtime.dataEpoch},
          );
        }
        final context = _ExecutionContext(
          this,
          command,
          runtime,
          clock.nowUtc(),
        );
        final bodyResult = await body(context);
        if (bodyResult.status == ExecutionResultStatus.applied) {
          await repository.recordOperation(
            dataEpoch: command.dataEpoch,
            operationId: command.operationId,
            requestHash: command.requestHash(),
            commandType: command.commandType,
            subjectKind: command.subjectKind,
            subjectId: command.subjectId,
            result: bodyResult,
          );
        }
        return bodyResult;
      });
      if (notify && result.isSuccess) {
        // 附加效果失败不能把已经提交的业务事实改写成失败（规范 §11、EXE-56）。
        try {
          onChanged?.call();
        } on Object {
          // outbox 与下一次读取会恢复显示；这里只丢一次界面刷新。
        }
      }
      return result;
    } on Object {
      // 事务失败时数据库回到提交前；界面必须看到"未保存"，不能看到假成功。
      return _failure(
        command,
        ExecutionResultStatus.storageFailed,
        ExecutionReasonCode.storageFailed,
        parameters: const {'retryable': true},
      );
    }
  }

  Future<d.ExecutionRuntimeState> _runtimeFor(_ExecutionContext context) async {
    // 每个命令都重新读一次：同一进程内的并发命令不能拿旧槽位判断。
    return await repository.ensureRuntimeState();
  }

  Future<d.ExecutionSessionSnapshot?> _resolveActiveSession(
    d.ExecutionRuntimeState runtime,
  ) async {
    final id = runtime.activeSessionId;
    if (id == null) return null;
    final snapshot = await repository.sessionSnapshot(
      id,
      runtimeRevision: runtime.revision,
    );
    if (snapshot == null || !snapshot.isActive) {
      await repository.writeRuntimeState(
        runtime.copyWith(
          clearActiveSessionId: true,
          revision: runtime.revision + 1,
          updatedAtUtc: clock.nowUtc(),
        ),
      );
      _releaseSessionLease();
      return null;
    }
    _acquireSessionLease();
    return snapshot;
  }

  Future<_ClosedActivity?> _closeRunningSegment(
    _ExecutionContext context,
    d.ExecutionSessionSnapshot snapshot,
  ) async {
    if (snapshot.state != d.ExecutionSessionState.running) return null;
    final now = context.now;
    var delta = now.difference(snapshot.lastReliableAtUtc);
    var clockAnomaly = false;
    final mark = _lastMonotonicMark;
    if (mark != null && _lastMonotonicSession == snapshot.sessionId) {
      final monotonicDelta = monotonicClock.now() - mark;
      final wallMicros = delta.inMicroseconds;
      final monotonicMicros = monotonicDelta.inMicroseconds;
      clockAnomaly = (wallMicros - monotonicMicros).abs() > 2 * 1000000;
      delta = monotonicDelta;
    }
    if (delta.isNegative) {
      delta = Duration.zero;
      clockAnomaly = true;
    }
    if (delta == Duration.zero) {
      return _ClosedActivity(
        segment: null,
        durationMicros: 0,
        clockAnomaly: clockAnomaly,
      );
    }
    var end = snapshot.lastReliableAtUtc.add(delta);
    if (end.isAfter(now)) end = now;
    final effective = end.difference(snapshot.lastReliableAtUtc);
    if (effective <= Duration.zero) {
      return _ClosedActivity(
        segment: null,
        durationMicros: 0,
        clockAnomaly: clockAnomaly,
      );
    }
    final sequence = await repository.nextSegmentSequence(snapshot.sessionId);
    final segment = d.ExecutionActivitySegment(
      segmentId: idGenerator.next(),
      dataEpoch: context.runtime.dataEpoch,
      sessionId: snapshot.sessionId,
      sequence: sequence,
      startUtc: snapshot.lastReliableAtUtc,
      endUtc: end,
      source: d.ExecutionActivitySource.realtime,
      invalidatedReason: null,
      createdAtUtc: now,
    );
    await repository.insertActivitySegment(segment);
    return _ClosedActivity(
      segment: segment,
      durationMicros: effective.inMicroseconds,
      clockAnomaly: clockAnomaly,
    );
  }

  Future<d.ExecutionOccurrence?> _applyActivity(
    _ExecutionContext context, {
    required d.ExecutionSessionSnapshot snapshot,
    required d.ExecutionOccurrence? occurrence,
    required _ClosedActivity segment,
    required d.ExecutionProgressAnchor anchor,
    DateTime? occurrenceStartUtc,
    d.ExecutionActivitySource? source,
    int? firstAcceptedSequence,
  }) async {
    if (segment.durationMicros <= 0) return occurrence;
    if (segment.segment != null && segment.durationMicros > 0) {
      final sequence =
          firstAcceptedSequence ?? await repository.allocateSequence();
      await repository.insertCredit(
        d.ExecutionCreditAllocation(
          dataEpoch: context.runtime.dataEpoch,
          segmentId: segment.segment!.segmentId,
          targetKind: d.ExecutionTargetKind.task,
          targetId: snapshot.taskId,
          allocationIndex: 0,
          recordRevision: 1,
          amountMicros: segment.durationMicros,
          firstAcceptedSequence: sequence,
          createdAtUtc: context.now,
        ),
      );
    }
    await _writeProgressForAnchor(snapshot.taskId, anchor);
    if (occurrence == null ||
        occurrence.privacyState != d.ExecutionPrivacyState.linked) {
      return occurrence;
    }
    var updated = occurrence;
    if (updated.firstStartEvidenceId == null && segment.durationMicros > 0) {
      final started = await context.addEvent(
        type: d.ExecutionEventType.started,
        occurredAtUtc: occurrenceStartUtc ?? snapshot.startedAtUtc,
        source: source ?? d.ExecutionActivitySource.realtime,
        occurrenceId: updated.id,
        payload: {'evidence': 'firstPositiveActivity'},
      );
      updated = updated.copyWith(firstStartEvidenceId: started.eventId);
    }
    final remaining =
        updated.remainingAllocationMicros - segment.durationMicros;
    updated = updated.copyWith(
      remainingAllocationMicros: remaining < 0 ? 0 : remaining,
      lifecycleState: remaining <= 0
          ? d.ExecutionLifecycleState.finished
          : d.ExecutionLifecycleState.started,
      revision: updated.revision + 1,
    );
    await repository.updateOccurrence(updated);
    return updated;
  }

  Future<d.ExecutionProgressAnchor> _ensureAnchor(PlannerTask task) async {
    final current = await repository.currentAnchor(task.id);
    final credits = await _creditsForTask(task.id);
    if (current == null) {
      final sequence = await repository.currentSequence();
      await repository.appendAnchor(
        taskId: task.id,
        anchorRemainingMicros:
            task.remainingMinutes * Duration.microsecondsPerMinute,
        anchorSequence: sequence,
        reason: 'initial',
      );
      final created = await repository.currentAnchor(task.id);
      if (created == null) {
        throw StateError('无法建立进度检查点');
      }
      return created;
    }
    final projection = executionProjectProgress(
      anchorRemainingMicros: current.anchorRemainingMicros,
      anchorSequence: current.anchorSequence,
      credits: credits,
    );
    if (projection.schedulingMinutes != task.remainingMinutes) {
      // 任务剩余被人工修正过（或来自旧数据），建立新的检查点边界。修正前已入账的
      // 记录只更新实际统计，不再扣这个较新的人工剩余。
      final sequence = await repository.currentSequence();
      await repository.appendAnchor(
        taskId: task.id,
        anchorRemainingMicros:
            task.remainingMinutes * Duration.microsecondsPerMinute,
        anchorSequence: sequence,
        reason: 'externalManualCorrection',
      );
      final created = await repository.currentAnchor(task.id);
      if (created == null) {
        throw StateError('无法建立进度检查点');
      }
      return created;
    }
    return current;
  }

  Future<d.ExecutionProgressAnchor?> _anchorForTaskId(String taskId) async {
    final task = await tasks.getById(taskId);
    if (task == null) return null;
    return _ensureAnchor(task);
  }

  Future<List<ExecutionProgressCredit>> _creditsForTask(String taskId) async {
    final credits = await repository.activeCreditsForTarget(
      targetKind: d.ExecutionTargetKind.task,
      targetId: taskId,
    );
    return [
      for (final credit in credits)
        ExecutionProgressCredit(
          firstAcceptedSequence: credit.firstAcceptedSequence,
          durationMicros: credit.amountMicros,
          targetKind: credit.targetKind,
          targetId: credit.targetId,
        ),
    ];
  }

  Future<void> _writeProgressForAnchor(
    String taskId,
    d.ExecutionProgressAnchor anchor,
  ) async {
    final credits = await _creditsForTask(taskId);
    final projection = executionProjectProgress(
      anchorRemainingMicros: anchor.anchorRemainingMicros,
      anchorSequence: anchor.anchorSequence,
      credits: credits,
    );
    await repository.writeTaskRemaining(
      taskId: taskId,
      remainingMicros: projection.remainingMicros,
    );
  }

  Future<String?> _taskIdForSession(String sessionId) async {
    final entry = await repository.findTimeEntry(sessionId);
    return entry?.taskId;
  }

  Future<String?> _taskIdForCycle(String cycleId) async {
    // 第一轮的活动分配目标是普通任务；周期进度的账本仍由 time_entries 汇总。
    return null;
  }

  void _markMonotonic(String sessionId) {
    _lastMonotonicSession = sessionId;
    _lastMonotonicMark = monotonicClock.now();
  }

  void _clearMonotonic() {
    _lastMonotonicSession = null;
    _lastMonotonicMark = null;
  }

  String _token(String requestHash, List<String> conflictIds) {
    final sorted = List<String>.of(conflictIds)..sort();
    final payload = [requestHash, ...sorted].join('|');
    return sha256.convert(utf8.encode(payload)).toString();
  }

  List<({DateTime startUtc, DateTime endUtc})> _subtractIntervals(
    DateTime startUtc,
    DateTime endUtc,
    List<d.ExecutionActivitySegment> overlaps,
  ) {
    final sorted = List<d.ExecutionActivitySegment>.of(overlaps)
      ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
    final free = <({DateTime startUtc, DateTime endUtc})>[];
    var cursor = startUtc;
    for (final overlap in sorted) {
      final overlapStart = overlap.startUtc.isBefore(cursor)
          ? cursor
          : overlap.startUtc;
      if (overlapStart.isAfter(cursor)) {
        free.add((startUtc: cursor, endUtc: overlapStart));
      }
      if (overlap.endUtc.isAfter(cursor)) cursor = overlap.endUtc;
    }
    if (cursor.isBefore(endUtc)) {
      free.add((startUtc: cursor, endUtc: endUtc));
    }
    return free;
  }

  ExecutionCommandResult _failure(
    ExecutionCommand command,
    ExecutionResultStatus status,
    ExecutionReasonCode reason, {
    String? confirmationToken,
    Map<String, Object?> parameters = const {},
  }) => ExecutionCommandResult.failure(
    status,
    reason,
    operationId: command.operationId,
    confirmationToken: confirmationToken,
    parameters: parameters,
  );
}

final class _ExecutionContext {
  _ExecutionContext(this.service, this.command, this.runtime, this.now);

  final DriftExecutionService service;
  final ExecutionCommand command;
  final d.ExecutionRuntimeState runtime;
  final DateTime now;
  int _eventIndex = 0;

  Future<_WrittenEvent> addEvent({
    required d.ExecutionEventType type,
    required DateTime occurredAtUtc,
    required d.ExecutionActivitySource source,
    required String? occurrenceId,
    Map<String, Object?> payload = const {},
    String? correctedEventId,
  }) async {
    final index = _eventIndex++;
    final sequence = await service.repository.allocateSequence();
    final eventId = service.idGenerator.next();
    await service.repository.insertEvent(
      d.ExecutionEvent(
        eventId: eventId,
        dataEpoch: runtime.dataEpoch,
        operationId: command.operationId,
        subEventIndex: index,
        occurrenceId: occurrenceId,
        eventType: type,
        occurredAtUtc: occurredAtUtc,
        recordedAtUtc: now,
        source: source,
        payload: payload,
        correctedEventId: correctedEventId,
        sequence: sequence,
        revision: 1,
      ),
    );
    return _WrittenEvent(eventId: eventId, sequence: sequence);
  }
}

final class _WrittenEvent {
  const _WrittenEvent({required this.eventId, required this.sequence});

  final String eventId;
  final int sequence;
}

final class _ClosedActivity {
  const _ClosedActivity({
    required this.segment,
    required this.durationMicros,
    required this.clockAnomaly,
  });

  final d.ExecutionActivitySegment? segment;
  final int durationMicros;
  final bool clockAnomaly;
}

/// 供测试与界面复用的时长格式（分:秒），不做本地化。
String executionDurationLabel(Duration duration) {
  final totalSeconds = math.max(0, duration.inSeconds);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
