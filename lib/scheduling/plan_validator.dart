import 'dart:collection';

import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

enum ConflictCode {
  insufficientCapacity,
  fixedEventOverlap,
  protectedTimeOverlap,
  lockedBlockMoved,
  blockOverlap,
  continuousBlockUnavailable,
  dailyLimitExceeded,
  scheduledDurationExceeded,
  minimumSleepConflict,
  staleProposal,
  invalidInput,
}

final class PlanningConflict {
  PlanningConflict({
    required this.code,
    this.taskId,
    this.shortageMinutes = 0,
    List<String> relatedEntityIds = const [],
    Map<String, Object?> details = const {},
  }) : relatedEntityIds = UnmodifiableListView(List.of(relatedEntityIds)),
       details = UnmodifiableMapView(Map.of(details));

  final ConflictCode code;
  final String? taskId;
  final int shortageMinutes;
  final List<String> relatedEntityIds;
  final Map<String, Object?> details;
}

final class PlanValidator {
  const PlanValidator(this._zones);

  final TimeZoneDatabase _zones;

  List<PlanningConflict> validate(
    ScheduleProblem problem,
    List<PlannedBlock> blocks,
  ) {
    final conflicts = <PlanningConflict>[];
    final tasks = {for (final task in problem.tasks) task.id: task};

    for (final block in blocks) {
      if (!problem.planningWindow.contains(block.startUtc) ||
          block.endUtc.isAfter(problem.planningWindow.endUtc) ||
          !tasks.containsKey(block.taskId)) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.invalidInput,
            taskId: block.taskId,
            relatedEntityIds: [block.id],
          ),
        );
      }
      for (final fixed in problem.fixedIntervals) {
        if (block.range.overlaps(fixed.range)) {
          conflicts.add(
            PlanningConflict(
              code: ConflictCode.fixedEventOverlap,
              taskId: block.taskId,
              relatedEntityIds: [block.id, fixed.id],
            ),
          );
        }
      }
      for (final protected in problem.protectedIntervals) {
        if (block.range.overlaps(protected.range)) {
          conflicts.add(
            PlanningConflict(
              code: ConflictCode.protectedTimeOverlap,
              taskId: block.taskId,
              relatedEntityIds: [block.id, protected.id],
            ),
          );
        }
      }
    }

    final ordered = [...blocks]
      ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
    for (var index = 1; index < ordered.length; index++) {
      if (ordered[index - 1].range.overlaps(ordered[index].range)) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.blockOverlap,
            relatedEntityIds: [ordered[index - 1].id, ordered[index].id],
          ),
        );
      }
    }

    final proposedById = {for (final block in blocks) block.id: block};
    for (final locked in problem.lockedBlocks) {
      final proposed = proposedById[locked.id];
      if (proposed == null ||
          proposed.taskId != locked.taskId ||
          proposed.range != locked.range) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.lockedBlockMoved,
            taskId: locked.taskId,
            relatedEntityIds: [locked.id],
          ),
        );
      }
    }

    for (final task in problem.tasks) {
      final taskBlocks = blocks
          .where((block) => block.taskId == task.id)
          .toList();
      final total = taskBlocks.fold<int>(
        0,
        (sum, block) => sum + block.durationMinutes,
      );
      if (task.splitMode == TaskSplitMode.continuous && taskBlocks.length > 1) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.continuousBlockUnavailable,
            taskId: task.id,
            relatedEntityIds: taskBlocks.map((block) => block.id).toList(),
          ),
        );
      }
      if (total > task.requiredMinutes) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.scheduledDurationExceeded,
            taskId: task.id,
            details: {
              'scheduledMinutes': total,
              'requiredMinutes': task.requiredMinutes,
            },
          ),
        );
      }
      for (final block in taskBlocks) {
        if (block.durationMinutes < task.minChunkMinutes ||
            block.durationMinutes > task.maxChunkMinutes) {
          conflicts.add(
            PlanningConflict(
              code: ConflictCode.invalidInput,
              taskId: task.id,
              relatedEntityIds: [block.id],
              details: {'reason': 'chunkLength'},
            ),
          );
        }
      }
    }

    // 每日上限约束的是"可移动任务"时长：规则字段名为
    // dailyMovableTaskLimitMinutes，需求规格 8.4.1 也表述为"每日可移动任务上限，
    // 不含固定课程与会议"。已锁定块由用户固定、引擎不得移动，属于不可移动时长，
    // 因此不计入本上限。AvailabilityBuilder 同样先把锁定块从可用时间中扣除，
    // 再把当日预算花在剩余空闲上；若此处再把锁定块计入，同一段时长会被计算两次，
    // 产生虚假的 dailyLimitExceeded，并使 PlanApplicationService 把合法提案判为 invalid。
    final minutesByLocalDate = <String, int>{};
    for (final block in blocks) {
      if (block.locked) continue;
      final local = _zones.toLocal(block.startUtc, problem.timeZoneId);
      final key = '${local.year}-${local.month}-${local.day}';
      minutesByLocalDate.update(
        key,
        (value) => value + block.durationMinutes,
        ifAbsent: () => block.durationMinutes,
      );
    }
    for (final entry in minutesByLocalDate.entries) {
      if (entry.value > problem.rules.dailyMovableTaskLimitMinutes) {
        conflicts.add(
          PlanningConflict(
            code: ConflictCode.dailyLimitExceeded,
            details: {
              'localDate': entry.key,
              'scheduledMinutes': entry.value,
              'limitMinutes': problem.rules.dailyMovableTaskLimitMinutes,
            },
          ),
        );
      }
    }

    return List.unmodifiable(conflicts);
  }
}
