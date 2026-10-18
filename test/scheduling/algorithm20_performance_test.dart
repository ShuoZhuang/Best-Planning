@Tags(['performance'])
library;

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
  final rules = DefaultSettings.v1().copyWith(
    defaultFocusMinutes: 30,
    dailyMovableTaskLimitMinutes: 480,
  );
  final tasks = [
    for (var index = 0; index < 200; index++)
      SchedulableTask(
        id: 'task-${index.toString().padLeft(3, '0')}',
        requiredMinutes: 30,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 30,
        priority: TaskPriority.values[index % TaskPriority.values.length],
      ),
  ];
  final locked = <PlannedBlock>[];
  var minute = 0;
  for (var index = 0; index < 300; index++) {
    final start = _window.startUtc.add(Duration(minutes: minute));
    locked.add(
      PlannedBlock(
        id: 'baseline-$index',
        taskId: tasks[index % tasks.length].id,
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
        ),
        locked: true,
      ),
    );
    minute += 30;
  }
  return ScheduleProblem(
    planningWindow: _window,
    timeZoneId: _zone,
    tasks: tasks,
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: locked,
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
    inputHash: 'performance-200-300',
  );
}

int _p95(List<int> values) {
  final sorted = [...values]..sort();
  final index = ((sorted.length * 95) / 100).ceil() - 1;
  return sorted[index.clamp(0, sorted.length - 1)];
}

void main() {
  test('200 任务 / 300 基线块七日窗口 p95 不超过 2 秒', () {
    final engine = DeterministicScheduleEngine(_zones);
    // 预热一次，随后固定运行 5 次。
    engine.generate(_problem());
    final elapsed = <int>[];
    for (var index = 0; index < 5; index++) {
      final stopwatch = Stopwatch()..start();
      engine.generate(_problem());
      stopwatch.stop();
      elapsed.add(stopwatch.elapsedMilliseconds);
    }
    // ignore: avoid_print
    print('PERF 200/300 elapsedMs=$elapsed p95=${_p95(elapsed)}ms');
    expect(_p95(elapsed), lessThanOrEqualTo(2000));
  });
}
