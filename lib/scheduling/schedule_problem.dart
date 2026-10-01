import 'dart:collection';

import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';

final class SchedulableTask {
  const SchedulableTask({
    required this.id,
    required this.requiredMinutes,
    required this.splitMode,
    required this.minChunkMinutes,
    required this.maxChunkMinutes,
    this.dueAtUtc,
    this.priority = TaskPriority.medium,
    this.energyLevel = TaskEnergyLevel.medium,
    this.isLifeTask = false,
  });

  final String id;
  final int requiredMinutes;
  final TaskSplitMode splitMode;
  final int minChunkMinutes;
  final int maxChunkMinutes;
  final DateTime? dueAtUtc;
  final TaskPriority priority;
  final TaskEnergyLevel energyLevel;
  final bool isLifeTask;
}

final class BusyInterval {
  const BusyInterval({required this.id, required this.range});
  final String id;
  final TimeRange range;
}

final class PlannedBlock {
  const PlannedBlock({
    required this.id,
    required this.taskId,
    required this.range,
    this.locked = false,
    this.explanationCode,
  });

  final String id;
  final String taskId;
  final TimeRange range;
  final bool locked;
  final String? explanationCode;

  DateTime get startUtc => range.startUtc;
  DateTime get endUtc => range.endUtc;
  int get durationMinutes => range.durationMinutes;
}

final class ScheduleProblem {
  ScheduleProblem({
    required this.planningWindow,
    required this.timeZoneId,
    required List<SchedulableTask> tasks,
    required List<BusyInterval> fixedIntervals,
    required List<BusyInterval> protectedIntervals,
    required List<PlannedBlock> lockedBlocks,
    required this.rules,
    required this.preferences,
    required this.inputHash,
  }) : tasks = UnmodifiableListView(List.of(tasks)),
       fixedIntervals = UnmodifiableListView(List.of(fixedIntervals)),
       protectedIntervals = UnmodifiableListView(List.of(protectedIntervals)),
       lockedBlocks = UnmodifiableListView(List.of(lockedBlocks));

  final TimeRange planningWindow;
  final String timeZoneId;
  final List<SchedulableTask> tasks;
  final List<BusyInterval> fixedIntervals;
  final List<BusyInterval> protectedIntervals;
  final List<PlannedBlock> lockedBlocks;
  final PlanningRules rules;
  final PreferenceProfile preferences;
  final String inputHash;
}
