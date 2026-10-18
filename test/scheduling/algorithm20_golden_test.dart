import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

final _zones = TimeZoneDatabase();
const _zone = 'UTC';
final _window = TimeRange(
  startUtc: DateTime.utc(2026, 10, 19),
  endUtc: DateTime.utc(2026, 10, 26),
);

ScheduleProblem _problem() {
  final rules = DefaultSettings.v1();
  final tasks = [
    SchedulableTask(
      id: 'continuous-report',
      requiredMinutes: 120,
      splitMode: TaskSplitMode.continuous,
      minChunkMinutes: 120,
      maxChunkMinutes: 120,
      dueAtUtc: DateTime.utc(2026, 10, 23, 18),
      priority: TaskPriority.high,
    ),
    const SchedulableTask(
      id: 'split-reading',
      requiredMinutes: 180,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 30,
      maxChunkMinutes: 60,
    ),
    const SchedulableTask(
      id: 'short-review',
      requiredMinutes: 20,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
    ),
    const SchedulableTask(
      id: 'deep-work',
      requiredMinutes: 90,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 30,
      maxChunkMinutes: 45,
      energyLevel: TaskEnergyLevel.high,
    ),
  ];
  final fixed = <BusyInterval>[
    for (final day in [19, 21, 23])
      BusyInterval(
        id: 'course-$day',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 10, day, 9),
          endUtc: DateTime.utc(2026, 10, day, 11),
        ),
      ),
  ];
  return ScheduleProblem(
    planningWindow: _window,
    timeZoneId: _zone,
    tasks: tasks,
    fixedIntervals: fixed,
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: rules,
    dailyPolicies: dailyPoliciesForWindow(
      zones: _zones,
      window: _window,
      rules: rules,
      timeZoneId: _zone,
    ),
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _zones,
      window: _window,
      rules: rules,
      timeZoneId: _zone,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'algorithm20-golden-week',
  );
}

void main() {
  test('算法 20 七日黄金夹具逐值稳定', () {
    final proposal = DeterministicScheduleEngine(_zones).generate(_problem());
    final actual = {
      'algorithmVersion': proposal.algorithmVersion,
      'outcome': proposal.outcome.name,
      'blocks': [
        for (final block in proposal.blocks)
          {
            'taskId': block.taskId,
            'startUtc': block.startUtc.toIso8601String(),
            'endUtc': block.endUtc.toIso8601String(),
            'explanationCode': block.explanationCode,
          },
      ],
      'unscheduled': [
        for (final item in proposal.unscheduled)
          {
            'taskId': item.taskId,
            'shortageMinutes': item.shortageMinutes,
            'primaryReason': item.primaryReason.code.name,
          },
      ],
    };
    final expected = jsonDecode(
      File('test/fixtures/scheduling/algorithm20_week.json').readAsStringSync(),
    ) as Map<String, Object?>;
    // 人工审阅要点：连续任务整块 120 分钟；拆分任务共 180 分钟且每段 30；
    // 20 分钟短余量按 20 分钟落地；无未安排项、无重叠。
    expect(actual, expected);
    expect(
      proposal.blocks
          .where((block) => block.taskId == 'continuous-report')
          .fold<int>(0, (sum, block) => sum + block.durationMinutes),
      120,
    );
    expect(
      proposal.blocks
          .where((block) => block.taskId == 'split-reading')
          .fold<int>(0, (sum, block) => sum + block.durationMinutes),
      180,
    );
  });
}
