import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';

/// 周实例的完整排程快照（1.12.0 设计 §5.1、Task 3）。
///
/// 排程输入只读这份快照，不再混读“当前模板 + 旧周期”。历史周因此不受模板改名、
/// 时区变化或后续编辑影响。
final class RecurringCycleSnapshot {
  RecurringCycleSnapshot({
    required this.cycleId,
    required this.templateId,
    required this.transportTaskId,
    required this.periodStartLocalDate,
    required this.periodStartUtc,
    required this.periodEndUtc,
    required this.effectiveStartUtc,
    required this.effectiveEndUtc,
    required this.timeZoneId,
    required this.templateRevision,
    required this.title,
    required this.notes,
    required this.areaId,
    required this.projectId,
    required this.priority,
    required this.energyLevel,
    required this.splitMode,
    required this.minChunkMinutes,
    required this.maxChunkMinutes,
    required this.preferredStartMinute,
    required this.preferredEndMinute,
    required this.pace,
    required this.allowedWeekdaysMask,
    required this.targetMinutes,
    required this.carryInMinutes,
    required this.state,
    required this.revision,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    required this.settledAtUtc,
  }) {
    if (cycleId.trim().isEmpty) {
      throw ArgumentError.value(cycleId, 'cycleId');
    }
    if (!periodStartUtc.isUtc || !periodEndUtc.isUtc) {
      throw ArgumentError('Period bounds must be UTC.');
    }
    if (!periodEndUtc.isAfter(periodStartUtc)) {
      throw ArgumentError('periodEndUtc must be after periodStartUtc.');
    }
    if (!effectiveStartUtc.isUtc || !effectiveEndUtc.isUtc) {
      throw ArgumentError('Effective bounds must be UTC.');
    }
    if (effectiveStartUtc.isBefore(periodStartUtc) ||
        effectiveEndUtc.isAfter(periodEndUtc) ||
        !effectiveEndUtc.isAfter(effectiveStartUtc)) {
      throw ArgumentError('Effective interval must be inside the period.');
    }
    if ((preferredStartMinute == null) != (preferredEndMinute == null)) {
      throw ArgumentError('Preferred minutes must be set together.');
    }
    if (targetMinutes <= 0 || carryInMinutes < 0) {
      throw ArgumentError('Target must be positive and carry-in non-negative.');
    }
    if (revision < 1) throw ArgumentError.value(revision, 'revision');
    if (periodStartLocalDate.weekday != DateTime.monday) {
      throw ArgumentError('Cycle period must start on a Monday.');
    }
  }

  final String cycleId;
  final String templateId;
  final String transportTaskId;
  final DateTime periodStartLocalDate;
  final DateTime periodStartUtc;
  final DateTime periodEndUtc;
  final DateTime effectiveStartUtc;
  final DateTime effectiveEndUtc;
  final String timeZoneId;
  final int templateRevision;
  final String title;
  final String notes;
  final String? areaId;
  final String? projectId;
  final TaskPriority priority;
  final TaskEnergyLevel energyLevel;
  final TaskSplitMode splitMode;
  final int minChunkMinutes;
  final int maxChunkMinutes;
  final int? preferredStartMinute;
  final int? preferredEndMinute;
  final RecurringPace pace;
  final int allowedWeekdaysMask;
  final int targetMinutes;
  final int carryInMinutes;
  final RecurringCycleStatus state;
  final int revision;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final DateTime? settledAtUtc;

  int get effectiveTargetMinutes => targetMinutes + carryInMinutes;

  bool get isOpen => state == RecurringCycleStatus.open;

  bool get isSettled => state.isSettled;

  /// 周期区间是否与某窗口相交（半开区间）。
  bool intersects(DateTime startUtc, DateTime endUtc) =>
      effectiveStartUtc.isBefore(endUtc) && effectiveEndUtc.isAfter(startUtc);

  RecurringCycleSnapshot copyWith({
    DateTime? effectiveStartUtc,
    DateTime? effectiveEndUtc,
    int? templateRevision,
    String? title,
    String? notes,
    String? areaId,
    String? projectId,
    TaskPriority? priority,
    TaskEnergyLevel? energyLevel,
    TaskSplitMode? splitMode,
    int? minChunkMinutes,
    int? maxChunkMinutes,
    int? preferredStartMinute,
    int? preferredEndMinute,
    RecurringPace? pace,
    int? allowedWeekdaysMask,
    int? targetMinutes,
    int? carryInMinutes,
    RecurringCycleStatus? state,
    int? revision,
    DateTime? updatedAtUtc,
    DateTime? settledAtUtc,
  }) => RecurringCycleSnapshot(
    cycleId: cycleId,
    templateId: templateId,
    transportTaskId: transportTaskId,
    periodStartLocalDate: periodStartLocalDate,
    periodStartUtc: periodStartUtc,
    periodEndUtc: periodEndUtc,
    effectiveStartUtc: effectiveStartUtc ?? this.effectiveStartUtc,
    effectiveEndUtc: effectiveEndUtc ?? this.effectiveEndUtc,
    timeZoneId: timeZoneId,
    templateRevision: templateRevision ?? this.templateRevision,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    areaId: areaId ?? this.areaId,
    projectId: projectId ?? this.projectId,
    priority: priority ?? this.priority,
    energyLevel: energyLevel ?? this.energyLevel,
    splitMode: splitMode ?? this.splitMode,
    minChunkMinutes: minChunkMinutes ?? this.minChunkMinutes,
    maxChunkMinutes: maxChunkMinutes ?? this.maxChunkMinutes,
    preferredStartMinute: preferredStartMinute ?? this.preferredStartMinute,
    preferredEndMinute: preferredEndMinute ?? this.preferredEndMinute,
    pace: pace ?? this.pace,
    allowedWeekdaysMask: allowedWeekdaysMask ?? this.allowedWeekdaysMask,
    targetMinutes: targetMinutes ?? this.targetMinutes,
    carryInMinutes: carryInMinutes ?? this.carryInMinutes,
    state: state ?? this.state,
    revision: revision ?? this.revision,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    settledAtUtc: settledAtUtc ?? this.settledAtUtc,
  );
}

/// 周期有效区间与周区间的相交结果。
final class EffectiveCycleWindow {
  const EffectiveCycleWindow({
    required this.startUtc,
    required this.endUtc,
    required this.isPartial,
  });

  final DateTime startUtc;
  final DateTime endUtc;
  final bool isPartial;

  bool get isEmpty => !endUtc.isAfter(startUtc);
}
