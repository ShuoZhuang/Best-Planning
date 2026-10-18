import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final _zones = TimeZoneDatabase();
const _zone = 'UTC';

ScheduleProblem _problem(List<SchedulableTask> tasks) {
  final rules = DefaultSettings.v1();
  final policies = <DateTime, DailySchedulingPolicy>{
    for (var index = 0; index < 7; index++)
      DateTime(2026, 10, 17 + index): DailySchedulingPolicy(
        localDate: DateTime(2026, 10, 17 + index),
        resolvedRules: rules,
        softReserveTargetMinutes: 0,
      ),
  };
  return ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: DateTime.utc(2026, 10, 17),
      endUtc: DateTime.utc(2026, 10, 24),
    ),
    timeZoneId: _zone,
    tasks: tasks,
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: rules,
    dailyPolicies: policies,
    weeklyLifeQuotaByWeekStart: {DateTime(2026, 10, 12): 0},
    preferences: const PreferenceProfile(),
    inputHash: 'property-test',
  );
}

List<SchedulableTask> _tasks() => const [
  SchedulableTask(
    id: 'continuous',
    requiredMinutes: 120,
    splitMode: TaskSplitMode.continuous,
    minChunkMinutes: 120,
    maxChunkMinutes: 120,
  ),
  SchedulableTask(
    id: 'split',
    requiredMinutes: 150,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 60,
  ),
  SchedulableTask(
    id: 'short',
    requiredMinutes: 15,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
  ),
];

String _signature(ScheduleProposal proposal) => [
  'outcome=${proposal.outcome.name}',
  for (final block in proposal.blocks)
    '${block.id}|${block.taskId}|${block.startUtc.toIso8601String()}|'
        '${block.endUtc.toIso8601String()}',
  for (final item in proposal.unscheduled)
    '${item.taskId}|${item.shortageMinutes}|${item.primaryReason.code.name}',
].join('\n');

void main() {
  test('同一输入连续运行 100 次，提案逐值相同', () {
    final engine = DeterministicScheduleEngine(_zones);
    final first = _signature(engine.generate(_problem(_tasks())));
    for (var index = 0; index < 99; index++) {
      expect(_signature(engine.generate(_problem(_tasks()))), first);
    }
  });

  test('输入任务列表打乱后结果仍相同', () {
    final engine = DeterministicScheduleEngine(_zones);
    final first = _signature(engine.generate(_problem(_tasks())));
    final reversed = _tasks().reversed.toList();
    expect(_signature(engine.generate(_problem(reversed))), first);
  });

  test('所有输出块不重叠、不越界，且分钟数不超过需求', () {
    final proposal = DeterministicScheduleEngine(_zones)
        .generate(_problem(_tasks()));
    final sorted = [...proposal.blocks]
      ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
    for (var index = 0; index < sorted.length; index++) {
      final block = sorted[index];
      expect(block.startUtc.isBefore(block.endUtc), isTrue);
      expect(block.startUtc.isBefore(DateTime.utc(2026, 10, 24)), isTrue);
      if (index > 0) {
        expect(
          sorted[index - 1].endUtc.isAfter(block.startUtc),
          isFalse,
          reason: '相邻块不得重叠：${sorted[index - 1]} / $block',
        );
      }
    }
    final byTask = <String, int>{};
    for (final block in proposal.blocks) {
      byTask.update(
        block.taskId,
        (value) => value + block.durationMinutes,
        ifAbsent: () => block.durationMinutes,
      );
    }
    for (final task in _tasks()) {
      expect(byTask[task.id] ?? 0, lessThanOrEqualTo(task.requiredMinutes));
    }
  });
}
