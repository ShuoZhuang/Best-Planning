import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

final _zones = TimeZoneDatabase();
const _zone = 'UTC';
final _date = DateTime(2026, 10, 17);

SchedulableTask _task({
  required String id,
  required int minutes,
  required TaskSplitMode split,
}) => SchedulableTask(
  id: id,
  requiredMinutes: minutes,
  splitMode: split,
  minChunkMinutes: minutes,
  maxChunkMinutes: minutes,
);

ScheduleProblem _adjustmentProblem({required bool locallyRepaired}) {
  final rules = DefaultSettings.v1();
  return ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: DateTime.utc(2026, 10, 17, 9),
      endUtc: DateTime.utc(2026, 10, 17, 11),
    ),
    timeZoneId: _zone,
    tasks: [_task(id: 'only', minutes: 60, split: TaskSplitMode.splittable)],
    fixedIntervals: [
      BusyInterval(
        id: 'blocked',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 10, 17),
          endUtc: DateTime.utc(2026, 10, 18),
        ),
      ),
    ],
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
    confirmedBlocks: [
      PlannedBlock(
        id: 'target',
        taskId: 'only',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 10, 17, 9),
          endUtc: DateTime.utc(2026, 10, 17, 10),
        ),
      ),
    ],
    inputHash: 'adjustment-$locallyRepaired',
    adjustment: BlockAdjustmentContext(
      targetBlockId: 'target',
      notBeforeUtc: DateTime.utc(2026, 10, 17, 9, 30),
      kind: BlockAdjustmentKind.defer,
    ),
    adjustmentLocallyRepaired: locallyRepaired,
  );
}

void main() {
  test('局部修复成功时不再调用全局搜索', () {
    var searches = 0;
    DeterministicScheduleEngine(
      _zones,
      onRepairSearch: () => searches++,
    ).generate(_adjustmentProblem(locallyRepaired: true));
    expect(searches, 0);
  });

  test('局部修复失败时允许一次有界全局搜索', () {
    var searches = 0;
    DeterministicScheduleEngine(
      _zones,
      onRepairSearch: () => searches++,
    ).generate(_adjustmentProblem(locallyRepaired: false));
    expect(searches, 1);
  });

  test('没有缺口时不进入全局修复搜索', () {
    var searches = 0;
    final rules = DefaultSettings.v1();
    final problem = ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: DateTime.utc(2026, 10, 17, 9),
        endUtc: DateTime.utc(2026, 10, 17, 11),
      ),
      timeZoneId: _zone,
      tasks: [_task(id: 'only', minutes: 60, split: TaskSplitMode.splittable)],
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
      },
      weeklyLifeQuotaByWeekStart: {DateTime(2026, 10, 12): 0},
      preferences: const PreferenceProfile(),
      inputHash: 'no-shortage',
    );

    DeterministicScheduleEngine(
      _zones,
      onRepairSearch: () => searches++,
    ).generate(problem);
    expect(searches, 0);
  });

  test('只有真正留下缺口时才进入修复搜索', () {
    var searches = 0;
    final rules = DefaultSettings.v1();
    final problem = ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: DateTime.utc(2026, 10, 17, 9),
        endUtc: DateTime.utc(2026, 10, 17, 11),
      ),
      timeZoneId: _zone,
      tasks: [_task(id: 'only', minutes: 60, split: TaskSplitMode.splittable)],
      fixedIntervals: [
        BusyInterval(
          id: 'blocked',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 17),
            endUtc: DateTime.utc(2026, 10, 18),
          ),
        ),
      ],
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
      inputHash: 'shortage',
    );

    DeterministicScheduleEngine(
      _zones,
      onRepairSearch: () => searches++,
    ).generate(problem);
    expect(searches, 1);
  });

  test('生产引擎通过有界搜索搬走灵活任务，完整安排连续任务', () {
    final rules = DefaultSettings.v1();
    final problem = ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: DateTime.utc(2026, 10, 17, 9),
        endUtc: DateTime.utc(2026, 10, 17, 11),
      ),
      timeZoneId: _zone,
      tasks: [
        // 字典序更小 ⇒ 贪心先排它，占住唯一的 60 分钟长槽。
        _task(id: 'a-flexible', minutes: 30, split: TaskSplitMode.splittable),
        _task(id: 'z-continuous', minutes: 60, split: TaskSplitMode.continuous),
      ],
      fixedIntervals: [
        BusyInterval(
          id: 'break',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 17, 10),
            endUtc: DateTime.utc(2026, 10, 17, 10, 30),
          ),
        ),
      ],
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
      inputHash: 'repair-production',
    );

    final proposal = DeterministicScheduleEngine(_zones).generate(problem);
    expect(proposal.unscheduled, isEmpty);
    expect(
      proposal.blocks
          .where((block) => block.taskId == 'z-continuous')
          .fold<int>(0, (sum, block) => sum + block.durationMinutes),
      60,
    );
    // 灵活任务被搬到 10:30 之后的 30 分钟短槽。
    final flexible = proposal.blocks.singleWhere(
      (block) => block.taskId == 'a-flexible',
    );
    expect(flexible.startUtc, DateTime.utc(2026, 10, 17, 10, 30));
  });
}
