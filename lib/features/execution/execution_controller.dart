import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:personal_planner/application/execution/execution_availability.dart';
import 'package:personal_planner/application/execution/execution_commands.dart';
import 'package:personal_planner/application/execution/execution_input_hashes.dart';
import 'package:personal_planner/application/execution/execution_notification_settings.dart';
import 'package:personal_planner/application/execution/execution_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

import 'execution_messages.dart';

/// 连续时间不足时的一次性短会话提议（规范 §7.3 第 5 条）。
final class ExecutionShortStartOffer {
  const ExecutionShortStartOffer({
    required this.taskId,
    required this.occurrenceId,
    required this.availableMicros,
  });

  final String taskId;
  final String? occurrenceId;
  final int availableMicros;

  int get availableMinutes => availableMicros ~/ 60000000;
}

/// 今日页执行条/执行卡的 UI 控制器。
///
/// **只调用 `ExecutionService` 端口**，不直接写执行表，也不在页面里计算进度或幂等。
/// 每次命令成功后重新读取持久状态，因此刷新、重启与页面重建看到的是同一份事实。
final class ExecutionController extends ChangeNotifier {
  ExecutionController({
    required this.service,
    required this.tasks,
    required this.notifications,
    required this.clock,
    required this.idGenerator,
    this.availability,
  });

  final DriftExecutionService service;
  final TaskRepository tasks;
  final ExecutionNotificationSettingsPort notifications;
  final Clock clock;
  final IdGenerator idGenerator;

  /// 运行中检查硬边界用。为空时只能依赖用户手动暂停。
  final ExecutionAvailabilityPort? availability;

  ExecutionStatus? _status;
  bool _busy = false;
  String? _message;
  ExecutionCommandResult? _lastResult;
  DateTime? _windowStartUtc;
  ExecutionShortStartOffer? _shortStartOffer;

  ExecutionShortStartOffer? get shortStartOffer => _shortStartOffer;

  void clearShortStartOffer() {
    _shortStartOffer = null;
    notifyListeners();
  }

  ExecutionStatus? get status => _status;
  bool get busy => _busy;
  String? get message => _message;
  ExecutionCommandResult? get lastResult => _lastResult;
  ExecutionSessionSnapshot? get activeSession => _status?.activeSession;
  bool get hasActiveSession => activeSession != null;

  ExecutionOccurrence? occurrenceForTask(String taskId) =>
      _status?.occurrenceForTask(taskId);

  Future<void> refresh({DateTime? windowStartUtc}) async {
    if (windowStartUtc != null) _windowStartUtc = windowStartUtc;
    try {
      final start = _windowStartUtc;
      _status = await service.status(
        windowStartUtc: start,
        windowEndUtc: start?.add(const Duration(days: 1)),
      );
    } on Object {
      _message = '执行状态暂时无法读取';
    }
    notifyListeners();
  }

  /// 进程启动时调用；把未结束会话标成待确认，不结算未知时长。
  Future<void> recoverOnStart() async {
    try {
      await service.recoverOpenSession();
    } on Object {
      // 恢复失败不能阻止应用启动；用户仍可在执行条里看到持久事实。
    }
    await refresh();
  }

  Future<bool> startTask(
    String taskId, {
    String? occurrenceId,
    int? targetDurationMicros,
  }) async {
    final started = await _run(() async {
      final current = await _requireStatus();
      final task = await tasks.getById(taskId);
      if (task == null) {
        _message = '任务不存在，可能已被删除';
        return null;
      }
      final occurrence = occurrenceId == null
          ? null
          : await service.repository.findOccurrence(occurrenceId);
      return service.start(
        StartExecutionCommand(
          operationId: idGenerator.next(),
          dataEpoch: current.dataEpoch,
          taskId: taskId,
          occurrenceId: occurrenceId,
          occurrenceRevision: occurrence?.revision,
          mode: ExecutionMode.planned,
          targetDurationMicros: targetDurationMicros,
          taskInputHash: executionTaskInputHash(task),
          runtimeRevision: current.runtimeRevision,
        ),
      );
    });
    if (started) {
      _shortStartOffer = null;
    } else if (_lastResult?.status ==
        ExecutionResultStatus.blockedByHardBoundary) {
      final available = _lastResult!.parameters['availableMicros'];
      if (available is int && available > 0) {
        _shortStartOffer = ExecutionShortStartOffer(
          taskId: taskId,
          occurrenceId: occurrenceId,
          availableMicros: available,
        );
        _message = '现在最多还能做 ${available ~/ 60000000} 分钟';
      }
    }
    notifyListeners();
    return started;
  }

  /// 用户明确选择"做这几分钟"后才开始短会话；不会自动越过保护时间。
  Future<bool> startShortSession() async {
    final offer = _shortStartOffer;
    if (offer == null) return false;
    // 留 5 秒采样余量，避免点击瞬间可用时间又少了一点被判成越界。
    final target = offer.availableMicros > 5000000
        ? offer.availableMicros - 5000000
        : offer.availableMicros;
    return startTask(
      offer.taskId,
      occurrenceId: offer.occurrenceId,
      targetDurationMicros: target,
    );
  }

  /// 运行中遇到课程、保护时间或锁定块时自动暂停（规范 §7.4）。
  ///
  /// 这是应用运行时的目标行为；后台调度延迟、休眠或进程崩溃后按已保存活动段恢复，
  /// 不把未知时间自动入账。返回 `true` 表示本次确实暂停了。
  Future<bool> maybePauseAtHardBoundary() async {
    final active = _status?.activeSession;
    final gate = availability;
    if (active == null ||
        active.state != ExecutionSessionState.running ||
        gate == null) {
      return false;
    }
    final current = await gate.at(
      nowUtc: clock.nowUtc(),
      taskId: active.taskId,
      occurrenceId: active.occurrenceId,
    );
    if (current.canStartPlanned) return false;
    return pause(systemReason: 'hardBoundaryReached');
  }

  String _hardBoundaryHash = '';

  Future<bool> pause({String? systemReason}) async {
    return _run(() async {
      final active = await _requireActive();
      final runtime = await _requireStatus();
      return service.pause(
        PauseExecutionCommand(
          operationId: idGenerator.next(),
          dataEpoch: runtime.dataEpoch,
          sessionId: active.sessionId,
          sessionRevision: active.revision,
          runtimeRevision: runtime.runtimeRevision,
          systemReason: systemReason,
        ),
      );
    });
  }

  Future<bool> resume() async {
    return _run(() async {
      final active = await _requireActive();
      final runtime = await _requireStatus();
      return service.resume(
        ResumeExecutionCommand(
          operationId: idGenerator.next(),
          dataEpoch: runtime.dataEpoch,
          sessionId: active.sessionId,
          mode: active.mode,
          sessionRevision: active.revision,
          runtimeRevision: runtime.runtimeRevision,
          hardBoundaryInputHash: _hardBoundaryHash,
        ),
      );
    });
  }

  Future<bool> finish({bool abandon = false}) async {
    return _run(() async {
      final active = await _requireActive();
      final runtime = await _requireStatus();
      return service.finish(
        FinishExecutionCommand(
          operationId: idGenerator.next(),
          dataEpoch: runtime.dataEpoch,
          sessionId: active.sessionId,
          sessionRevision: active.revision,
          runtimeRevision: runtime.runtimeRevision,
          abandonOccurrenceRemaining: abandon,
        ),
      );
    });
  }

  Future<bool> snooze(
    ExecutionOccurrence occurrence, {
    int minutes = 10,
  }) async {
    return _run(() async {
      final runtime = await _requireStatus();
      final target = clock.nowUtc().add(Duration(minutes: minutes));
      final settings = await notifications.snapshot(targetAtUtc: target);
      final current = await service.repository.currentReminder(occurrence.id);
      return service.setSnooze(
        SetExecutionSnoozeCommand(
          operationId: idGenerator.next(),
          dataEpoch: runtime.dataEpoch,
          occurrenceId: occurrence.id,
          elapsedMinutes: minutes,
          occurrenceRevision: occurrence.revision,
          reminderRevision: current?.revision ?? 0,
          notificationSettingsHash: settings.settingsHash,
        ),
      );
    });
  }

  Future<bool> recordManual({
    required String taskId,
    required Duration duration,
    String? occurrenceId,
    String note = '',
  }) async {
    return _run(() async {
      final current = await _requireStatus();
      final task = await tasks.getById(taskId);
      if (task == null) {
        _message = '任务不存在，可能已被删除';
        return null;
      }
      final end = clock.nowUtc();
      final occurrence = occurrenceId == null
          ? null
          : await service.repository.findOccurrence(occurrenceId);
      final anchor = await service.repository.currentAnchor(taskId);
      return service.recordManual(
        RecordManualExecutionCommand(
          operationId: idGenerator.next(),
          dataEpoch: current.dataEpoch,
          taskId: taskId,
          occurrenceId: occurrenceId,
          occurrenceRevision: occurrence?.revision,
          segmentStartUtc: end.subtract(duration),
          segmentEndUtc: end,
          note: note,
          includedInAnchor: false,
          taskInputHash: executionTaskInputHash(task),
          progressAnchorRevision: anchor?.revision ?? 0,
        ),
      );
    });
  }

  void clearMessage() {
    _message = null;
    notifyListeners();
  }

  Future<ExecutionStatus> _requireStatus() async {
    final current = _status;
    if (current != null) return current;
    final loaded = await service.status();
    _status = loaded;
    return loaded;
  }

  Future<ExecutionSessionSnapshot> _requireActive() async {
    final active = (await _requireStatus()).activeSession;
    if (active == null) {
      throw StateError('没有进行中的执行会话');
    }
    return active;
  }

  Future<bool> _run(Future<ExecutionCommandResult?> Function() action) async {
    _busy = true;
    notifyListeners();
    try {
      final result = await action();
      if (result == null) return false;
      _lastResult = result;
      _message = executionMessageFor(result);
      final hash = result.parameters['hardBoundaryInputHash'];
      if (hash is String && hash.isNotEmpty) _hardBoundaryHash = hash;
      return result.isSuccess;
    } on Object {
      _message = '操作未保存，请重试';
      return false;
    } finally {
      _busy = false;
      await refresh();
    }
  }
}
