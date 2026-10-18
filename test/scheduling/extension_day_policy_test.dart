import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/extension_day_policy.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

final _zones = TimeZoneDatabase();
const _zone = 'Asia/Shanghai';
final _date = DateTime(2026, 10, 17);

ScheduleProblem _problem({required List<SchedulableTask> tasks}) {
  final rules = DefaultSettings.v1().copyWith(
    sleepRange: LocalTimeRange(
      startMinute: 23 * 60 + 30,
      endMinute: 7 * 60 + 30,
    ),
  );
  return ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: _zones.localMidnightToUtc(_date, _zone),
      endUtc: _zones.localMidnightToUtc(DateTime(2026, 10, 19), _zone),
    ),
    timeZoneId: _zone,
    tasks: tasks,
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: rules,
    dailyPolicies: {
      _date: DailySchedulingPolicy(
        localDate: _date,
        resolvedRules: rules,
        softReserveTargetMinutes: 0,
      ),
      DateTime(2026, 10, 18): DailySchedulingPolicy(
        localDate: DateTime(2026, 10, 18),
        resolvedRules: rules,
        softReserveTargetMinutes: 0,
      ),
    },
    weeklyLifeQuotaByWeekStart: {DateTime(2026, 10, 12): 0},
    preferences: const PreferenceProfile(),
    inputHash: 'test',
  );
}

SchedulableTask _task({String id = 't1', int required = 60}) => SchedulableTask(
  id: id,
  requiredMinutes: required,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 30,
  maxChunkMinutes: 60,
  dueAtUtc: _zones.localDateTimeToUtc(DateTime(2026, 10, 18), 2 * 60, _zone),
);

void main() {
  test('正常无缺口不提出候选', () {
    final problem = _problem(tasks: [_task()]);
    final candidates = const ExtensionDayPolicy().buildCandidates(
      problem: problem,
      triggeringTasks: const [],
      allowedDates: {_date},
      absoluteMinimumSleepMinutes: 6 * 60,
      zones: _zones,
      nowUtc: _zones.localDateTimeToUtc(_date, 12 * 60, _zone),
    );
    expect(candidates, isEmpty);
  });

  test('延长可增加触发任务容量时提出，固定起床不变', () {
    final problem = _problem(tasks: [_task()]);
    final candidates = const ExtensionDayPolicy().buildCandidates(
      problem: problem,
      triggeringTasks: [_task()],
      allowedDates: {_date},
      absoluteMinimumSleepMinutes: 6 * 60,
      zones: _zones,
      nowUtc: _zones.localDateTimeToUtc(_date, 12 * 60, _zone),
    );
    expect(candidates, hasLength(1));
    final candidate = candidates.single;
    expect(candidate.localDate, _date);
    expect(candidate.fixedWakeOffsetMinutes, 1890);
    expect(candidate.addedPlaceableMinutes, 60);
    expect(candidate.sleepLossMinutes, 60);
    expect(candidate.triggeringTaskIds, ['t1']);
    // 30 分钟的候选延到 00:00 只有 30 分钟，不够 60；60 分钟候选是 00:30。
    expect(candidate.temporarySleepStartOffsetMinutes, 24 * 60 + 30);
  });

  test('绝对最低睡眠阻止延长越过硬边界', () {
    final problem = _problem(tasks: [_task()]);
    final candidates = const ExtensionDayPolicy().buildCandidates(
      problem: problem,
      triggeringTasks: [_task(required: 600)],
      allowedDates: {_date},
      // 23:30→07:30 只有 8 小时；最低 8 小时 ⇒ 完全不能延长。
      absoluteMinimumSleepMinutes: 8 * 60,
      zones: _zones,
      nowUtc: _zones.localDateTimeToUtc(_date, 12 * 60, _zone),
    );
    expect(candidates, isEmpty);
  });

  test('最多三个候选且稳定排序', () {
    final problem = _problem(tasks: [_task()]);
    final candidates = const ExtensionDayPolicy().buildCandidates(
      problem: problem,
      triggeringTasks: [_task()],
      allowedDates: problem.dailyPolicies.keys.toSet(),
      absoluteMinimumSleepMinutes: 6 * 60,
      zones: _zones,
      nowUtc: _zones.localDateTimeToUtc(_date, 12 * 60, _zone),
    );
    expect(candidates.length, lessThanOrEqualTo(3));
    final ordered = [...candidates]
      ..sort((a, b) {
        final added = b.addedPlaceableMinutes.compareTo(
          a.addedPlaceableMinutes,
        );
        return added != 0 ? added : a.localDate.compareTo(b.localDate);
      });
    expect(candidates.map((candidate) => candidate.stableKey), [
      for (final candidate in ordered) candidate.stableKey,
    ]);
  });
}
