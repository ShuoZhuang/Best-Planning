import 'dart:collection';

import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

final class TaskDraft {
  const TaskDraft({
    required this.title,
    required this.estimatedMinutes,
    this.projectId,
    this.notes = '',
    this.priority = TaskPriority.medium,
    this.dueAtUtc,
    this.energyLevel = TaskEnergyLevel.medium,
    this.splitMode = TaskSplitMode.splittable,
    this.minChunkMinutes = 25,
    this.maxChunkMinutes = 90,
    this.status = TaskStatus.inbox,
  });

  final String title;
  final int estimatedMinutes;
  final String? projectId;
  final String notes;
  final TaskPriority priority;
  final DateTime? dueAtUtc;
  final TaskEnergyLevel energyLevel;
  final TaskSplitMode splitMode;
  final int minChunkMinutes;
  final int maxChunkMinutes;
  final TaskStatus status;
}

final class TaskSaveResult {
  TaskSaveResult.success(this.task) : fieldErrors = const <String, String>{};

  TaskSaveResult.invalid(Map<String, String> errors)
    : task = null,
      fieldErrors = UnmodifiableMapView(errors);

  final PlannerTask? task;
  final Map<String, String> fieldErrors;

  bool get isSuccess => task != null;
}

final class TaskService {
  const TaskService({
    required TaskRepository repository,
    required Clock clock,
    required IdGenerator idGenerator,
  }) : this._(repository, clock, idGenerator);

  const TaskService._(this._repository, this._clock, this._idGenerator);

  final TaskRepository _repository;
  final Clock _clock;
  final IdGenerator _idGenerator;

  Stream<List<PlannerTask>> watchOpenTasks() => _repository.watchOpenTasks();

  Future<TaskSaveResult> quickAdd(String title, int estimatedMinutes) =>
      saveDraft(TaskDraft(title: title, estimatedMinutes: estimatedMinutes));

  Future<TaskSaveResult> saveDraft(TaskDraft draft) async {
    final errors = <String, String>{};
    if (draft.title.trim().isEmpty) errors['title'] = '请输入任务标题';
    if (draft.estimatedMinutes <= 0) {
      errors['estimatedMinutes'] = '预计时长必须大于 0 分钟';
    }
    if (draft.minChunkMinutes <= 0 ||
        draft.maxChunkMinutes < draft.minChunkMinutes) {
      errors['chunks'] = '任务片段范围无效';
    }
    if (draft.dueAtUtc != null && !draft.dueAtUtc!.isUtc) {
      errors['dueAtUtc'] = '截止时间必须转换为 UTC';
    }
    if (errors.isNotEmpty) return TaskSaveResult.invalid(errors);

    final now = _clock.nowUtc();
    final task = PlannerTask(
      id: _idGenerator.next(),
      projectId: draft.projectId,
      title: draft.title,
      notes: draft.notes,
      priority: draft.priority,
      estimatedMinutes: draft.estimatedMinutes,
      remainingMinutes: draft.estimatedMinutes,
      dueAtUtc: draft.dueAtUtc,
      energyLevel: draft.energyLevel,
      splitMode: draft.splitMode,
      minChunkMinutes: draft.minChunkMinutes,
      maxChunkMinutes: draft.maxChunkMinutes,
      status: draft.status,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await _repository.save(task);
    return TaskSaveResult.success(task);
  }

  Future<bool> changeStatus(String taskId, TaskStatus status) async {
    final existing = await _repository.getById(taskId);
    if (existing == null) return false;
    await _repository.save(
      existing.copyWith(status: status, updatedAtUtc: _clock.nowUtc()),
    );
    return true;
  }
}
