import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';

final _zones = TimeZoneDatabase();
const _zone = 'UTC';
final _date = DateTime(2026, 10, 17);

ScheduleProblem _problem({
  required List<SchedulableTask> tasks,
  List<BusyInterval> fixed = const [],
}) {
  final rules = DefaultSettings.v1();
  return ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: DateTime.utc(2026, 10, 17),
      endUtc: DateTime.utc(2026, 10, 18),
    ),
    timeZoneId: _zone,
    tasks: tasks,
    fixedIntervals: fixed,
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: rules,
    dailyPolicies: {
      _date: DailySchedulingPolicy(
        localDate: _date,
        resolvedRules: rules,
        softReserveTargetMinutes: 0,
      ),
    },
    weeklyLifeQuotaByWeekStart: {DateTime(2026, 10, 12): 0},
    preferences: const PreferenceProfile(),
    inputHash: 'outcome-test',
  );
}

SchedulableTask _task() => const SchedulableTask(
  id: 'task',
  requiredMinutes: 120,
  splitMode: TaskSplitMode.continuous,
  minChunkMinutes: 120,
  maxChunkMinutes: 120,
);

void main() {
  test('完整方案返回 solved', () {
    final proposal = DeterministicScheduleEngine(_zones)
        .generate(_problem(tasks: [_task()]));
    expect(proposal.outcome, SearchOutcomeKind.solved);
    expect(proposal.unscheduled, isEmpty);
  });

  test('硬约束下确实排不下时返回 hardInfeasible，而不是默认 solved', () {
    final proposal = DeterministicScheduleEngine(_zones).generate(
      _problem(
        tasks: [_task()],
        fixed: [
          BusyInterval(
            id: 'all-day',
            range: TimeRange(
              startUtc: DateTime.utc(2026, 10, 17),
              endUtc: DateTime.utc(2026, 10, 18),
            ),
          ),
        ],
      ),
    );
    expect(proposal.unscheduled, isNotEmpty);
    expect(proposal.outcome, SearchOutcomeKind.hardInfeasible);
  });

  test('分配预算耗尽返回 budgetExhausted，不冒充硬无解', () {
    final tasks = [
      for (var index = 0; index < 8; index++)
        SchedulableTask(
          id: 'task-$index',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
        ),
    ];
    final proposal = DeterministicScheduleEngine(
      _zones,
      maxAllocationStates: 1,
    ).generate(_problem(tasks: tasks));
    expect(proposal.outcome, SearchOutcomeKind.budgetExhausted);
  });
}
