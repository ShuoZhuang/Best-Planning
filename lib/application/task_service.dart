import 'dart:collection';

import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
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
    void Function(ScheduleInputChange change)? onScheduleInputChanged,
  }) : this._(
         repository,
         clock,
         idGenerator,
         correctionLog,
         onScheduleInputChanged,
       );

  const TaskService._(
    this._repository,
    this._clock,
    this._idGenerator,
    this._correctionLog,
    this._onScheduleInputChanged,
  );

  final TaskRepository _repository;
  final Clock _clock;
  final IdGenerator _idGenerator;
  final TaskCorrectionLog? _correctionLog;

  /// 任务的**排程输入发生变化**时的回调（FR-STAT-06 的"重排原因"来源）。
  ///
  /// 口径（按默认选定）：**截止日期／优先级／剩余时长／状态**这四类变化会让排程结果可能改变，
  /// 因此各记一条 `replan:` 事件。用人类可读的原因码，因为统计页直接把它显示给用户。
  ///
  /// 用回调而不是直接依赖统计模块：任务服务不该知道统计的存在，装配由组合根负责；
  /// 未装配时只是不留原因，不影响任何行为。
  ///
  /// **固定日程这一类不再缺**：日历服务的增删改（创建／删除／单次改写／系列改写）也会改变排程
  /// 输入，此前登记为"本服务看不到它"（§13.0 W9 的 (a) 末句）。现由 `CalendarService` 的同名
  /// 回调各自记一条，装配点仍是组合根那一个 lambda——**同一份"重排原因"由两个写入方提供**，
  /// 而不是让任务服务去读日历。
  final void Function(ScheduleInputChange change)? _onScheduleInputChanged;

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
  /// 剩余时长**允许为 0**（本轮放宽，见 §13.0 的 R9 行）：0 表示"没有剩余工作"，是"按专注
  /// 记录重算"的合法结果。此前要求 > 0，会把"专注已覆盖预计时长"逼成一处**钳到 1 分钟**的
  /// 假数字——界面显示"还剩 1 分钟"，而用户其实已经做完了。负数仍然拒绝。
  ///
  /// 修正记录通过 [TaskCorrectionLog] 落库供统计分析。未注入该端口时修正照常完成，
  /// 但不会留下历史，因此生产装配必须注入。
  Future<TaskSaveResult> correctRemainingMinutes(
    String taskId,
    int remainingMinutes,
  ) async {
    if (remainingMinutes < 0) {
      return TaskSaveResult.invalid({
        'remainingMinutes': '剩余时长不能为负数',
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
    _onScheduleInputChanged?.call(const ScheduleInputChange(label: '剩余时长修正', kind: DomainChangeKind.taskSchedulingChanged));
    return TaskSaveResult.success(updated);
  }

  /// 按**已确认的专注记录**重算剩余时长（FR-FOCUS-05）。
  ///
  /// 口径（按默认选定）：`remaining = max(0, 预计时长 − 实际专注分钟)`；算到 0 时**同时把任务
  /// 标记为已完成**——0 剩余与"做完了"是同一件事的两种表达，留着状态不改会让任务留在待排
  /// 池里却没有任何可排时长。
  ///
  /// `actualMinutes` 由调用方给出（组合根从专注记录里汇总）：本服务不认识专注模块，与
  /// `FocusService` 不认识任务是同一个边界。
  Future<TaskSaveResult> applyFocusRecompute({
    required String taskId,
    required int actualMinutes,
  }) async {
    if (actualMinutes < 0) {
      return TaskSaveResult.invalid({'actualMinutes': '实际专注时长不能为负数'});
    }
    final existing = await _repository.getById(taskId);
    if (existing == null) {
      return TaskSaveResult.invalid({'taskId': '任务不存在'});
    }
    final remaining = existing.estimatedMinutes - actualMinutes;
    final result = await correctRemainingMinutes(
      taskId,
      remaining < 0 ? 0 : remaining,
    );
    if (!result.isSuccess) return result;
    if (remaining <= 0 && existing.status != TaskStatus.completed) {
      await changeStatus(taskId, TaskStatus.completed);
      final reloaded = await _repository.getById(taskId);
      if (reloaded != null) return TaskSaveResult.success(reloaded);
    }
    return result;
  }

  /// 设置或清除任务截止时间（FR-REPLAN-07 的处理入口之一）。
  ///
  /// `dueAtUtc` 为 null 表示**清除**（`PlannerTask.copyWith` 对可空字段用哨兵值，因此传
  /// null 是"置空"而不是"不改"）。与 [setPriority] 同型：读取—改一个字段—保存。
  ///
  /// **与 FR-REPLAN-08 不冲突**：那条禁止的是**系统自行**改截止日期；这里由用户显式调用。
  /// **必须传入 UTC 时刻**：本地日期到 UTC 的换算需要时区，而本服务不持有它，因此换算由
  /// 调用方（持有 `TimeZoneDatabase` 的界面层或组合根）负责，与 `TaskDraft` 的既有约定一致。
  Future<TaskSaveResult> setDueDate(String taskId, DateTime? dueAtUtc) async {
    if (dueAtUtc != null && !dueAtUtc.isUtc) {
      return TaskSaveResult.invalid({'dueAtUtc': '截止时间必须转换为 UTC'});
    }
    final existing = await _repository.getById(taskId);
    if (existing == null) {
      return TaskSaveResult.invalid({'taskId': '任务不存在'});
    }
    final updated = existing.copyWith(
      dueAtUtc: dueAtUtc,
      updatedAtUtc: _clock.nowUtc(),
    );
    await _repository.save(updated);
    _onScheduleInputChanged?.call(const ScheduleInputChange(label: '截止日期变化', kind: DomainChangeKind.taskSchedulingChanged));
    return TaskSaveResult.success(updated);
  }

  /// 调整任务优先级（FR-REPLAN-07 的处理入口之一）。
  ///
  /// 与 [correctRemainingMinutes] 同型：读取—改一个字段—保存，并推进修改时间。
  ///
  /// **与 FR-REPLAN-08 不冲突**：那条禁止的是**系统自行**修改截止日期、预计时长或硬约束；
  /// 优先级由**用户显式**调整，正是 FR-REPLAN-07 要求提供的入口。
  Future<TaskSaveResult> setPriority(String taskId, TaskPriority priority) async {
    final existing = await _repository.getById(taskId);
    if (existing == null) {
      return TaskSaveResult.invalid({'taskId': '任务不存在'});
    }
    final updated = existing.copyWith(
      priority: priority,
      updatedAtUtc: _clock.nowUtc(),
    );
    await _repository.save(updated);
    _onScheduleInputChanged?.call(const ScheduleInputChange(label: '优先级变化', kind: DomainChangeKind.taskSchedulingChanged));
    return TaskSaveResult.success(updated);
  }

  /// 把任务归属到某个项目，`projectId` 为 null 表示取消归属。
  ///
  /// 这是**任务通向领域的唯一路径**：任务的分类（领域）与生活标记都经
  /// `tasks.project_id` → `projects.area_id` → `areas.is_life` 推导，因此没有这个入口，
  /// 无论领域与项目建得多完整、生活标记写得多正确，也不会有任何任务算作生活任务。
  ///
  /// 这里**不校验项目是否存在**：数据库对 `tasks.projectId` 有外键约束，连接时又开启了
  /// `PRAGMA foreign_keys`，因此不存在的项目会在写入时直接失败，不需要在服务层再维护
  /// 一份容易与库结构脱节的重复判断。界面侧的职责是只提供已存在的项目。
  Future<bool> assignProject(String taskId, String? projectId) async {
    final existing = await _repository.getById(taskId);
    if (existing == null) return false;
    // 归属未变化时不写入：无变化的写入会把"最近修改"推到现在，让该字段失去意义。
    if (existing.projectId == projectId) return true;
    await _repository.save(
      existing.copyWith(projectId: projectId, updatedAtUtc: _clock.nowUtc()),
    );
    return true;
  }

  /// 设置或清除任务的期望时段（spec §7.1）。
  ///
  /// 期望时段是**软约束**：它参与评分但不参与硬约束，因此非法取值不该抛给调用方——
  /// 界面拿到 `false` 就能给出提示，不必自己镜像一遍 `LocalTimeRange` 的校验规则。
  /// 两个参数同为 null 表示清除偏好；只给一个、起点不早于终点、或超出一日范围都返回
  /// `false` 且不写库。
  Future<bool> setPreferredWindow(
    String taskId, {
    int? startMinute,
    int? endMinute,
  }) async {
    final existing = await _repository.getById(taskId);
    if (existing == null) return false;

    LocalTimeRange? window;
    if (startMinute != null || endMinute != null) {
      if (startMinute == null || endMinute == null) return false;
      try {
        window = LocalTimeRange(
          startMinute: startMinute,
          endMinute: endMinute,
        );
      } on ArgumentError {
        return false;
      }
    }

    final current = existing.preferredWindow;
    if (current == null && window == null) return true;
    if (current != null &&
        window != null &&
        current.startMinute == window.startMinute &&
        current.endMinute == window.endMinute) {
      // 偏好未变化时不写入，避免"最近修改"被无谓推进。
      return true;
    }

    await _repository.save(
      existing.copyWith(
        preferredWindow: window,
        updatedAtUtc: _clock.nowUtc(),
      ),
    );
    return true;
  }

  Future<bool> changeStatus(String taskId, TaskStatus status) async {
    final existing = await _repository.getById(taskId);
    if (existing == null) return false;
    await _repository.save(
      existing.copyWith(status: status, updatedAtUtc: _clock.nowUtc()),
    );
    // 状态变化会改变"可排任务集合"（完成／取消后不再参与排程），因此同样是一条重排原因。
    // 类别按**新状态**细分：完成与跳过对排程的含义不同，而这一层正好知道新状态是什么——
    // 若只报一个笼统的"状态变化"，协调器就只能靠猜。
    _onScheduleInputChanged?.call(
      ScheduleInputChange(
        label: '状态变化',
        kind: switch (status) {
          TaskStatus.completed => DomainChangeKind.taskCompleted,
          TaskStatus.skipped => DomainChangeKind.taskSkipped,
          TaskStatus.cancelled => DomainChangeKind.taskCancelled,
          _ => DomainChangeKind.taskSchedulingChanged,
        },
      ),
    );
    return true;
  }
}
