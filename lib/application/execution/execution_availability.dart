import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 开始前的硬约束检查结果（规范 §7.2）。
///
/// 事实记录与合法排程分开校验：这里只回答"现在能不能开始一段**计划内**会话"。
/// `actualOnly` 记录不经过这道门，用户可以在保护时间里如实记录已做的工作。
final class ExecutionAvailability {
  const ExecutionAvailability({
    required this.canStartPlanned,
    required this.availableMicros,
    required this.nextAvailableUtc,
    required this.boundaryUtc,
    required this.blockerKind,
    required this.hardBoundaryInputHash,
    this.taskAvailable = true,
  });

  factory ExecutionAvailability.allowed({
    required int availableMicros,
    required DateTime boundaryUtc,
    required String hardBoundaryInputHash,
  }) => ExecutionAvailability(
    canStartPlanned: true,
    availableMicros: availableMicros,
    nextAvailableUtc: null,
    boundaryUtc: boundaryUtc,
    blockerKind: null,
    hardBoundaryInputHash: hardBoundaryInputHash,
  );

  factory ExecutionAvailability.blocked({
    required DateTime nextAvailableUtc,
    required String blockerKind,
    required String hardBoundaryInputHash,
    bool taskAvailable = true,
    int availableMicros = 0,
  }) => ExecutionAvailability(
    canStartPlanned: false,
    availableMicros: availableMicros,
    nextAvailableUtc: nextAvailableUtc,
    boundaryUtc: nextAvailableUtc,
    blockerKind: blockerKind,
    hardBoundaryInputHash: hardBoundaryInputHash,
    taskAvailable: taskAvailable,
  );

  final bool canStartPlanned;
  final int availableMicros;
  final DateTime? nextAvailableUtc;
  final DateTime boundaryUtc;
  final String? blockerKind;
  final String hardBoundaryInputHash;
  final bool taskAvailable;
}

abstract interface class ExecutionAvailabilityPort {
  Future<ExecutionAvailability> at({
    required DateTime nowUtc,
    required String taskId,
    String? occurrenceId,
  });
}

/// 基于现有排程输入装配的只读检查。
///
/// **刻意复用 `ScheduleProblemSource`**：课程、保护时间、睡眠、锁定块和工作日规则只应该
/// 在装配层解释一次。若这里另写一份"哪些时间不能开始"的判断，两处必然漂移，用户会看到
/// 排程器认为不可用、按钮却可点的矛盾。
final class ScheduleExecutionAvailability implements ExecutionAvailabilityPort {
  ScheduleExecutionAvailability({
    required this.source,
    required this.tasks,
    required this.clock,
    this.horizon = const Duration(hours: 24),
  });

  final ScheduleProblemSource source;
  final TaskRepository tasks;
  final Clock clock;
  final Duration horizon;

  @override
  Future<ExecutionAvailability> at({
    required DateTime nowUtc,
    required String taskId,
    String? occurrenceId,
  }) async {
    if (!nowUtc.isUtc) throw ArgumentError.value(nowUtc, 'nowUtc');
    final task = await tasks.getById(taskId);
    if (task == null) {
      return ExecutionAvailability.blocked(
        nextAvailableUtc: nowUtc,
        blockerKind: 'taskUnavailable',
        hardBoundaryInputHash: _hashOf(const []),
        taskAvailable: false,
      );
    }
    if (task.status.isClosed) {
      return ExecutionAvailability.blocked(
        nextAvailableUtc: nowUtc,
        blockerKind: 'taskClosed',
        hardBoundaryInputHash: _hashOf(const []),
        taskAvailable: false,
      );
    }
    final availableFrom = task.availableFromUtc;
    if (availableFrom != null && nowUtc.isBefore(availableFrom)) {
      return ExecutionAvailability.blocked(
        nextAvailableUtc: availableFrom,
        blockerKind: 'availableFrom',
        hardBoundaryInputHash: _hashOf(const []),
      );
    }
    if (task.dueAtUtc case final due? when nowUtc.isAfter(due)) {
      return ExecutionAvailability.blocked(
        nextAvailableUtc: nowUtc,
        blockerKind: 'deadlineElapsed',
        hardBoundaryInputHash: _hashOf(const []),
      );
    }

    final ScheduleProblem problem;
    try {
      problem = await source.load();
    } on Object {
      // **不猜**：无法装配输入时不得宣称这个时段合法（规范 §7.2）。
      return ExecutionAvailability.blocked(
        nextAvailableUtc: nowUtc,
        blockerKind: 'availabilityUnknown',
        hardBoundaryInputHash: _hashOf(const []),
      );
    }

    final horizonEnd = nowUtc.add(horizon);
    final intervals = <_BoundaryInterval>[];
    for (final interval in problem.fixedIntervals) {
      intervals.add(
        _BoundaryInterval(
          interval.id,
          interval.range.startUtc,
          interval.range.endUtc,
        ),
      );
    }
    for (final interval in problem.protectedIntervals) {
      intervals.add(
        _BoundaryInterval(
          interval.id,
          interval.range.startUtc,
          interval.range.endUtc,
          kind: interval.protectedKind?.name,
        ),
      );
    }
    for (final block in problem.lockedBlocks) {
      intervals.add(
        _BoundaryInterval(
          block.id,
          block.startUtc,
          block.endUtc,
          kind: 'locked',
        ),
      );
    }
    intervals.sort((a, b) => a.startUtc.compareTo(b.startUtc));
    final hash = _hashOf(intervals);

    for (final interval in intervals) {
      if (interval.contains(nowUtc)) {
        return ExecutionAvailability.blocked(
          nextAvailableUtc: interval.endUtc,
          blockerKind: interval.kind ?? 'fixed',
          hardBoundaryInputHash: hash,
        );
      }
    }

    DateTime? nextBoundary;
    for (final interval in intervals) {
      if (interval.startUtc.isAfter(nowUtc)) {
        if (nextBoundary == null || interval.startUtc.isBefore(nextBoundary)) {
          nextBoundary = interval.startUtc;
        }
      }
    }
    final boundary = nextBoundary == null || nextBoundary.isAfter(horizonEnd)
        ? horizonEnd
        : nextBoundary;
    final available = boundary.difference(nowUtc).inMicroseconds;
    return ExecutionAvailability.allowed(
      availableMicros: available < 0 ? 0 : available,
      boundaryUtc: boundary,
      hardBoundaryInputHash: hash,
    );
  }

  String _hashOf(List<_BoundaryInterval> intervals) {
    final payload = [
      for (final interval in intervals)
        {
          'id': interval.id,
          'start': interval.startUtc.microsecondsSinceEpoch,
          'end': interval.endUtc.microsecondsSinceEpoch,
          'kind': interval.kind,
        },
    ];
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }
}

final class _BoundaryInterval {
  const _BoundaryInterval(this.id, this.startUtc, this.endUtc, {this.kind});

  final String id;
  final DateTime startUtc;
  final DateTime endUtc;
  final String? kind;

  bool contains(DateTime instant) =>
      !instant.isBefore(startUtc) && instant.isBefore(endUtc);
}

/// 没有可用来源时使用的**保守**实现：不声称任何时段合法。
///
/// 生产装配必须注入 [ScheduleExecutionAvailability]；只有测试与旧库迁移窗口会用到它。
final class UnknownExecutionAvailability implements ExecutionAvailabilityPort {
  const UnknownExecutionAvailability(this.clock);

  final Clock clock;

  @override
  Future<ExecutionAvailability> at({
    required DateTime nowUtc,
    required String taskId,
    String? occurrenceId,
  }) async => ExecutionAvailability.blocked(
    nextAvailableUtc: nowUtc,
    blockerKind: 'availabilityUnknown',
    hardBoundaryInputHash: 'unavailable',
    taskAvailable: false,
  );
}
