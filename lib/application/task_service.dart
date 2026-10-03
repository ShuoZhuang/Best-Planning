import 'dart:collection';

import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_correction_log.dart';
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
    TaskCorrectionLog? correctionLog,
  }) : this._(repository, clock, idGenerator, correctionLog);

  const TaskService._(
    this._repository,
    this._clock,
    this._idGenerator,
    this._correctionLog,
  );

  final TaskRepository _repository;
  final Clock _clock;
  final IdGenerator _idGenerator;
  final TaskCorrectionLog? _correctionLog;

  Stream<List<PlannerTask>> watchOpenTasks() => _repository.watchOpenTasks();

  /// 按 id 读取单个任务，不存在时返回 `null`。
  ///
  /// 详情页与通知点击都需要它：`watchOpenTasks` 只返回未结束的任务，而提醒可能指向
  /// 一个已经完成或被取消的任务——用列表去找会把"任务存在但已结束"误判成"任务不存在"。
  Future<PlannerTask?> findById(String taskId) => _repository.getById(taskId);

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

  /// 手动修正剩余时长（FR-TASK-05）。
  ///
  /// 只改 `remainingMinutes`，**不改预计时长**：预计时长是原始估算，§8 的预估偏差
  /// 口径正是用它与实际投入对照；改写它会污染该统计。
  ///
  /// 剩余时长必须大于 0：把任务做完了应当走 `changeStatus(completed)`，而不是把
  /// 剩余时长归零——后者会让任务仍处于未完成状态却没有可排时长。
  ///
  /// 修正记录通过 [TaskCorrectionLog] 落库供统计分析。未注入该端口时修正照常完成，
  /// 但不会留下历史，因此生产装配必须注入。
  Future<TaskSaveResult> correctRemainingMinutes(
    String taskId,
    int remainingMinutes,
  ) async {
    if (remainingMinutes <= 0) {
      return TaskSaveResult.invalid({
        'remainingMinutes': '剩余时长必须大于 0 分钟',
      });
    }
    final existing = await _repository.getById(taskId);
    if (existing == null) {
      return TaskSaveResult.invalid({'taskId': '任务不存在'});
    }

    final now = _clock.nowUtc();
    final updated = existing.copyWith(
      remainingMinutes: remainingMinutes,
      updatedAtUtc: now,
    );
    await _repository.save(updated);
    await _correctionLog?.record(
      RemainingMinutesCorrection(
        taskId: taskId,
        previousMinutes: existing.remainingMinutes,
        correctedMinutes: remainingMinutes,
        correctedAtUtc: now,
      ),
    );
    return TaskSaveResult.success(updated);
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
