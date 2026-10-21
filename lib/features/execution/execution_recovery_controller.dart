import 'package:flutter/foundation.dart';
import 'package:personal_planner/application/execution/execution_commands.dart';
import 'package:personal_planner/application/execution/execution_input_hashes.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

import 'execution_messages.dart';

/// 恢复预览的 UI 编排。
///
/// 只通过 [ExecutionRecoveryService] 端口工作；草案由服务保存在当前进程代次里，页面
/// 不缓存计划，也不在取消后把草案留给下一次普通生成。
final class ExecutionRecoveryController extends ChangeNotifier {
  ExecutionRecoveryController({
    required this.service,
    required this.repository,
    required this.tasks,
    required this.clock,
    required this.idGenerator,
  });

  final ExecutionRecoveryService service;
  final DriftExecutionRepository repository;
  final TaskRepository tasks;
  final Clock clock;
  final IdGenerator idGenerator;

  ExecutionRecoveryDraft? _draft;
  String? _message;
  bool _busy = false;
  ExecutionCommandResult? _lastResult;

  ExecutionRecoveryDraft? get draft => _draft;
  String? get message => _message;
  bool get busy => _busy;
  ExecutionCommandResult? get lastResult => _lastResult;
  bool get hasDraft => _draft != null;

  Future<bool> request({
    required String occurrenceId,
    bool holdToday = false,
    int? targetShareMicros,
  }) async {
    _busy = true;
    notifyListeners();
    try {
      final occurrence = await repository.findOccurrence(occurrenceId);
      if (occurrence == null || occurrence.currentPlanVersionId == null) {
        _message = '找不到这条安排对应的原计划块';
        return false;
      }
      final taskId = occurrence.taskId;
      if (taskId == null) {
        _message = '任务已删除，不能重新安排';
        return false;
      }
      final task = await tasks.getById(taskId);
      if (task == null) {
        _message = '任务已删除，不能重新安排';
        return false;
      }
      final runtime = await repository.ensureRuntimeState();
      final anchor = await repository.currentAnchor(taskId);
      final result = await service.requestRecovery(
        RequestExecutionRecoveryCommand(
          operationId: idGenerator.next(),
          dataEpoch: runtime.dataEpoch,
          occurrenceId: occurrenceId,
          notBeforeUtc: clock.nowUtc(),
          targetShareMicros: targetShareMicros,
          holdToday: holdToday,
          occurrenceRevision: occurrence.revision,
          planVersionId: occurrence.currentPlanVersionId!,
          taskInputHash: executionTaskInputHash(task),
          progressAnchorRevision: anchor?.revision ?? 0,
          processEpoch: service.processEpoch,
        ),
      );
      _lastResult = result.result;
      _draft = result.draft;
      _message = result.isSuccess ? null : executionMessageFor(result.result);
      return result.isSuccess;
    } on Object {
      _message = '生成恢复预览失败，请重试';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> apply({bool allowPartial = false}) async {
    final draft = _draft;
    if (draft == null) {
      _message = '预览已失效，请重新生成';
      return false;
    }
    _busy = true;
    notifyListeners();
    try {
      final occurrence = await repository.findOccurrence(draft.occurrenceId);
      final taskId = occurrence?.taskId;
      final task = taskId == null ? null : await tasks.getById(taskId);
      if (occurrence == null || task == null) {
        _message = '这条安排已经变化，请刷新后重试';
        return false;
      }
      final runtime = await repository.ensureRuntimeState();
      final anchor = await repository.currentAnchor(task.id);
      final result = await service.applyRecovery(
        ApplyExecutionRecoveryCommand(
          operationId: idGenerator.next(),
          dataEpoch: runtime.dataEpoch,
          draftId: draft.draftId,
          proposalId: draft.proposalId,
          inputHash: draft.inputHash,
          processEpoch: draft.processEpoch,
          occurrenceRevision: occurrence.revision,
          planVersionId: draft.planVersionId,
          taskInputHash: executionTaskInputHash(task),
          progressAnchorRevision: anchor?.revision ?? 0,
          authorizationMode: allowPartial
              ? PlanApplyMode.allowPartial
              : PlanApplyMode.completeOnly,
        ),
      );
      _lastResult = result;
      _message = executionMessageFor(result);
      if (result.isSuccess) _draft = null;
      return result.isSuccess;
    } on Object {
      _message = '应用恢复预览失败，原计划保留';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> cancel() async {
    final draft = _draft;
    if (draft == null) return;
    _busy = true;
    notifyListeners();
    try {
      final runtime = await repository.ensureRuntimeState();
      await service.cancelRecovery(
        CancelExecutionRecoveryCommand(
          operationId: idGenerator.next(),
          dataEpoch: runtime.dataEpoch,
          draftId: draft.draftId,
          draftRevision: draft.revision,
          processEpoch: draft.processEpoch,
        ),
      );
    } on Object {
      _message = '取消预览未完成，请重试';
    } finally {
      _draft = null;
      _busy = false;
      notifyListeners();
    }
  }

  void clear() {
    _draft = null;
    _message = null;
    _lastResult = null;
    notifyListeners();
  }
}
