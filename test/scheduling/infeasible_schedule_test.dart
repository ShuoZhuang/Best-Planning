import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  test('reports the exact shortage without scheduling into sleep', () {
    final zones = TimeZoneDatabase();
    final engine = DeterministicScheduleEngine(zones);
    final day = DateTime.utc(2026, 10, 5);
    final sleep = TimeRange(
      startUtc: day.add(const Duration(hours: 20)),
      endUtc: day.add(const Duration(days: 1, hours: 8)),
    );
    final problem = ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: day,
        endUtc: day.add(const Duration(days: 1)),
      ),
      timeZoneId: 'UTC',
      tasks: [
        SchedulableTask(
          id: 'over-capacity',
          requiredMinutes: 180,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 90,
          dueAtUtc: day.add(const Duration(hours: 20)),
        ),
      ],
      fixedIntervals: const [],
      protectedIntervals: [
        BusyInterval(
          id: 'day-protection',
          range: TimeRange(
            startUtc: day.add(const Duration(hours: 10)),
            endUtc: day.add(const Duration(hours: 20)),
          ),
        ),
      ],
      lockedBlocks: const [],
      rules: DefaultSettings.v1().copyWith(
        sleepRange: LocalTimeRange(startMinute: 20 * 60, endMinute: 8 * 60),
        dailyMovableTaskLimitMinutes: 120,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'over-capacity-v1',
    );

    final proposal = engine.generate(problem);

    expect(proposal.metrics.isFullyFeasible, isFalse);
    expect(proposal.metrics.scheduledMinutes, 120);
    expect(proposal.metrics.unscheduledMinutes, 60);
    expect(proposal.unscheduled.single.shortageMinutes, 60);
    expect(
      proposal.conflicts
          .singleWhere((item) => item.code == ConflictCode.insufficientCapacity)
          .shortageMinutes,
      60,
    );
    expect(
      proposal.blocks.any((block) => block.range.overlaps(sleep)),
      isFalse,
    );
  });

  test('deterministic result is JSON-identical for 100 runs', () {
    final zones = TimeZoneDatabase();
    final engine = DeterministicScheduleEngine(zones);
    final day = DateTime.utc(2026, 10, 5);
    final problem = ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: day,
        endUtc: day.add(const Duration(days: 1)),
      ),
      timeZoneId: 'UTC',
      tasks: const [
        SchedulableTask(
          id: 'b',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
        ),
        SchedulableTask(
          id: 'a',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
        ),
      ],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: DefaultSettings.v1(),
      preferences: const PreferenceProfile(),
      inputHash: 'stable-v1',
    );
    String signature() => jsonEncode([
      for (final block in engine.generate(problem).blocks)
        [block.id, block.taskId, block.startUtc.toIso8601String()],
    ]);
    final expected = signature();

    for (var run = 0; run < 100; run++) {
      expect(signature(), expected);
    }
  });
}
