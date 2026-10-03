import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/time_range.dart';

enum TaskPriority { low, medium, high, urgent }

enum TaskEnergyLevel { low, medium, high }

enum TaskSplitMode { splittable, continuous }

/// 任务的当前状态。
///
/// 前六个是**用户设置并持久化**的生命周期状态；`scheduled`（已安排）与
/// `overdue`（已逾期）是**由事实派生**的状态，不写入数据库：
///
/// - `overdue` 只取决于"截止时间已过且任务未结束"，时间流逝本身就会让它成立，
///   没有任何写入时机；
/// - `scheduled` 取决于"已确认计划中是否存在该任务的块"，与计划生命周期绑定，
///   若另行落库就会产生两个事实来源，撤销与重排时必然不同步。
///
/// 因此从数据库读出的状态永远不会是这两个值，判断当前状态请用
/// [PlannerTask.statusAt]。
enum TaskStatus {
  inbox,
  open,
  scheduled,
  inProgress,
  completed,
  skipped,
  cancelled,
  overdue,
}

extension TaskStatusSemantics on TaskStatus {
  /// 已结束：完成、跳过或取消。
  bool get isClosed =>
      this == TaskStatus.completed ||
      this == TaskStatus.skipped ||
      this == TaskStatus.cancelled;

  /// 是否属于用户设置并可持久化的状态。
  bool get isStored => this != TaskStatus.scheduled && this != TaskStatus.overdue;
}

final class PlannerTask {
  PlannerTask({
    required this.id,
    this.projectId,
    required String title,
    this.notes = '',
    required this.priority,
    required this.estimatedMinutes,
    required this.remainingMinutes,
    this.dueAtUtc,
    required this.energyLevel,
    required this.splitMode,
    required this.minChunkMinutes,
    required this.maxChunkMinutes,
    this.preferredWindow,
    required this.status,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : title = title.trim() {
    if (this.title.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Cannot be empty.');
    }
    _requirePositive(estimatedMinutes, 'estimatedMinutes');
    // **剩余时长允许为 0**（本轮放宽，见 §13.0 的 R9 行）：0 表示"没有剩余工作"，而这正是
    // "按专注记录重算"的合法结果。此前要求 > 0，会把"专注时长已覆盖预计时长"这种情况逼成
    // 一处**钳到 1 分钟**的假数字——界面显示"还剩 1 分钟"，而用户其实已经做完了。
    // 负数仍然非法。
    _requireNonNegative(remainingMinutes, 'remainingMinutes');
    _requirePositive(minChunkMinutes, 'minChunkMinutes');
    _requirePositive(maxChunkMinutes, 'maxChunkMinutes');
    if (minChunkMinutes > maxChunkMinutes) {
      throw ArgumentError('minChunkMinutes cannot exceed maxChunkMinutes.');
    }
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
    if (dueAtUtc != null) _requireUtc(dueAtUtc!, 'dueAtUtc');
  }

  static const Object _unset = Object();

  final EntityId id;
  final EntityId? projectId;
  final String title;
  final String notes;
  final TaskPriority priority;
  final int estimatedMinutes;
  final int remainingMinutes;
  final DateTime? dueAtUtc;
  final TaskEnergyLevel energyLevel;
  final TaskSplitMode splitMode;
  final int minChunkMinutes;
  final int maxChunkMinutes;

  /// 用户表达的期望时段（本地分钟区间），为空表示没有偏好。
  ///
  /// 这是软约束的输入而不是硬约束：排程可以落在区间之外，只是分数更低
  /// （见设计 §5.4 的"任务期望时段"因子与 §9.4）。
  final LocalTimeRange? preferredWindow;
  final TaskStatus status;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  int get schedulingEstimatedMinutes => _roundToFive(estimatedMinutes);
  int get schedulingRemainingMinutes => _roundToFive(remainingMinutes);

  /// 派生当前状态，供界面展示与筛选使用。
  ///
  /// 优先级（前者优先）：
  /// 1. 已结束（完成 / 跳过 / 取消）——结束即结束，不再判逾期；
  /// 2. 已逾期——截止已过且未结束，这是最需要处理的事实；
  /// 3. 进行中——比"已安排"更能说明用户当下在做什么；
  /// 4. 已安排——已确认计划中存在该任务的块；
  /// 5. 否则回落到用户设置的状态（收集箱 / 待安排）。
  ///
  /// [nowUtc] 必须为 UTC；[hasPlanBlocks] 表示已确认计划中是否有该任务的块。
  TaskStatus statusAt({required DateTime nowUtc, bool hasPlanBlocks = false}) {
    if (!nowUtc.isUtc) {
      throw ArgumentError.value(nowUtc, 'nowUtc', 'Must be UTC.');
    }
    if (status.isClosed) return status;
    final due = dueAtUtc;
    if (due != null && due.isBefore(nowUtc)) return TaskStatus.overdue;
    if (status == TaskStatus.inProgress) return status;
    if (hasPlanBlocks) return TaskStatus.scheduled;
    return status;
  }

  PlannerTask copyWith({
    EntityId? id,
    Object? projectId = _unset,
    String? title,
    String? notes,
    TaskPriority? priority,
    int? estimatedMinutes,
    int? remainingMinutes,
    Object? dueAtUtc = _unset,
    TaskEnergyLevel? energyLevel,
    TaskSplitMode? splitMode,
    int? minChunkMinutes,
    int? maxChunkMinutes,
    Object? preferredWindow = _unset,
    TaskStatus? status,
    DateTime? createdAtUtc,
    DateTime? updatedAtUtc,
  }) => PlannerTask(
    id: id ?? this.id,
    projectId: identical(projectId, _unset)
        ? this.projectId
        : projectId as EntityId?,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    priority: priority ?? this.priority,
    estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
    remainingMinutes: remainingMinutes ?? this.remainingMinutes,
    dueAtUtc: identical(dueAtUtc, _unset)
        ? this.dueAtUtc
        : dueAtUtc as DateTime?,
    energyLevel: energyLevel ?? this.energyLevel,
    splitMode: splitMode ?? this.splitMode,
    minChunkMinutes: minChunkMinutes ?? this.minChunkMinutes,
    maxChunkMinutes: maxChunkMinutes ?? this.maxChunkMinutes,
    preferredWindow: identical(preferredWindow, _unset)
        ? this.preferredWindow
        : preferredWindow as LocalTimeRange?,
    status: status ?? this.status,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}

int _roundToFive(int value) => ((value + 4) ~/ 5) * 5;

/// 允许 0 的校验：`remainingMinutes` 用它，因为"没有剩余工作"是合法状态。
void _requireNonNegative(int value, String name) {
  if (value < 0) {
    throw ArgumentError.value(value, name, 'must not be negative');
  }
}

void _requirePositive(int value, String name) {  if (value <= 0) throw ArgumentError.value(value, name, 'Must be positive.');
}

void _requireUtc(DateTime value, String name) {
  if (!value.isUtc) throw ArgumentError.value(value, name, 'Must be UTC.');
}
