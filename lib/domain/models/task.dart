import 'package:personal_planner/core/ids.dart';

enum TaskPriority { low, medium, high, urgent }

enum TaskEnergyLevel { low, medium, high }

enum TaskSplitMode { splittable, continuous }

enum TaskStatus { inbox, open, inProgress, completed, skipped, cancelled }

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
    required this.status,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : title = title.trim() {
    if (this.title.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Cannot be empty.');
    }
    _requirePositive(estimatedMinutes, 'estimatedMinutes');
    _requirePositive(remainingMinutes, 'remainingMinutes');
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
  final TaskStatus status;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  int get schedulingEstimatedMinutes => _roundToFive(estimatedMinutes);
  int get schedulingRemainingMinutes => _roundToFive(remainingMinutes);

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
    status: status ?? this.status,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}

int _roundToFive(int value) => ((value + 4) ~/ 5) * 5;

void _requirePositive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'Must be positive.');
}

void _requireUtc(DateTime value, String name) {
  if (!value.isUtc) throw ArgumentError.value(value, name, 'Must be UTC.');
}
