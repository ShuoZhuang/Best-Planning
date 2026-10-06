import 'dart:collection';

import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

final class SchedulingCandidate {
  const SchedulingCandidate({
    required this.id,
    required this.taskId,
    required this.range,
    required this.localDate,
  });

  final String id;
  final String taskId;
  final TimeRange range;
  final DateTime localDate;

  DateTime get startUtc => range.startUtc;
  DateTime get endUtc => range.endUtc;
  int get durationMinutes => range.durationMinutes;
}

final class CandidateGenerator {
  const CandidateGenerator({this.granularityMinutes = 5})
    : assert(granularityMinutes > 0);

  final int granularityMinutes;

  List<SchedulingCandidate> generate(
    SchedulableTask task,
    List<AvailabilitySlot> slots,
  ) {
    final durations = _candidateDurations(task);
    final candidates = <SchedulingCandidate>[];

    for (final slot in slots) {
      final availableFrom = task.availableFromUtc;
      final earliestStart = availableFrom == null
          ? slot.startUtc
          : _laterOf(
              slot.startUtc,
              _roundUtcUp(availableFrom, granularityMinutes),
            );
      for (final duration in durations) {
        if (duration > slot.durationMinutes) continue;
        final latestStart = slot.endUtc.subtract(Duration(minutes: duration));
        if (earliestStart.isAfter(latestStart)) continue;
        for (
          var start = earliestStart;
          !start.isAfter(latestStart);
          start = start.add(Duration(minutes: granularityMinutes))
        ) {
          final range = TimeRange(
            startUtc: start,
            endUtc: start.add(Duration(minutes: duration)),
          );
          candidates.add(
            SchedulingCandidate(
              id: '${task.id}:${start.microsecondsSinceEpoch}:$duration',
              taskId: task.id,
              range: range,
              localDate: slot.localDate,
            ),
          );
        }
      }
    }

    candidates.sort((a, b) {
      final startOrder = a.startUtc.compareTo(b.startUtc);
      if (startOrder != 0) return startOrder;
      final durationOrder = a.durationMinutes.compareTo(b.durationMinutes);
      if (durationOrder != 0) return durationOrder;
      return a.id.compareTo(b.id);
    });
    return UnmodifiableListView(candidates);
  }

  List<int> _candidateDurations(SchedulableTask task) {
    if (task.splitMode == TaskSplitMode.continuous) {
      return task.requiredMinutes % granularityMinutes == 0
          ? [task.requiredMinutes]
          : const [];
    }

    final minimum = _roundUp(task.minChunkMinutes, granularityMinutes);
    final maximum = _roundDown(
      task.maxChunkMinutes < task.requiredMinutes
          ? task.maxChunkMinutes
          : task.requiredMinutes,
      granularityMinutes,
    );
    return [
      for (
        var duration = minimum;
        duration <= maximum;
        duration += granularityMinutes
      )
        duration,
    ];
  }
}

int _roundUp(int value, int step) => ((value + step - 1) ~/ step) * step;
int _roundDown(int value, int step) => (value ~/ step) * step;

DateTime _laterOf(DateTime first, DateTime second) =>
    first.isAfter(second) ? first : second;

DateTime _roundUtcUp(DateTime value, int stepMinutes) {
  final step = Duration(minutes: stepMinutes).inMicroseconds;
  final rounded = ((value.microsecondsSinceEpoch + step - 1) ~/ step) * step;
  return DateTime.fromMicrosecondsSinceEpoch(rounded, isUtc: true);
}
