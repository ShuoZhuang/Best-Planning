// 1.7.1 Task 2 Step 2：**每日可移动任务上限是对最终安排结果的约束**。
//
// ## 这个文件为什么存在
//
// 上限此前只由两处间接实现：`AvailabilityBuilder` 把它当成"最多保留多少分钟候选"从清晨
// 开始消费（Task 2 Step 1/3 已删除），以及 `PlanValidator` 在整份提案上做最终校验。
//
// 删掉截断之后出现一个真实的空档：**候选现在能看到全天**，而初次放置循环本身不查每日上限
// （它查的是任务自己声明的 `maxMinutesPerLocalDay`，那是另一个概念）。于是必须补上
// `ScheduleEngine._exceedsMovableDailyLimit`，否则"引擎排出来超限、PlanValidator 判无效"
// 会以提案被拒绝的形式暴露给用户。
//
// 这里钉住两件事：
// 1. 最终所有**未锁定**块按本地日汇总不超过 `dailyMovableTaskLimitMinutes`；
// 2. 锁定块沿用既有规则**不计入**可移动上限（否则用户一锁定就会把当天预算吃满）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

final _zones = TimeZoneDatabase();

/// 一天 00:00–24:00（UTC 时区，便于按小时直接读写）。
final _day = TimeRange(
  startUtc: DateTime.utc(2026, 10, 5),
  endUtc: DateTime.utc(2026, 10, 6),
);

SchedulableTask _task(String id, int minutes) => SchedulableTask(
  id: id,
  requiredMinutes: minutes,
  splitMode: TaskSplitMode.continuous,
  minChunkMinutes: minutes,
  maxChunkMinutes: minutes,
);

/// 睡眠留到 00:00–07:00，于是 07:00–24:00 是可排区间（共 1020 分钟），
/// 远大于下面用到的上限，确保"排不下"只能来自上限而不是容量。
ScheduleProblem _problem({
  required List<SchedulableTask> tasks,
  required int dailyLimit,
  List<PlannedBlock> lockedBlocks = const [],
}) {
  final window = _day;
  final zoneId = 'UTC';
  final rules = DefaultSettings.v1().copyWith(
    sleepRange: LocalTimeRange(startMinute: 0, endMinute: 7 * 60),
    dailyMovableTaskLimitMinutes: dailyLimit,
    // 精力窗口清空：本文件只测上限，不希望评分把块挪到别的时段而干扰结论。
    energyWindows: const [],
  );
  return ScheduleProblem(
    planningWindow: window,
    timeZoneId: zoneId,
    tasks: tasks,
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: lockedBlocks,
    rules: rules,
    dailyPolicies: dailyPoliciesForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    ),
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'movable-daily-limit-v1',
  );
}

int _movableMinutesOnDay(List<PlannedBlock> blocks) => blocks
    .where((block) => !block.locked)
    .fold<int>(0, (sum, block) => sum + block.durationMinutes);

void main() {
  test('**最终所有未锁定块之和不超过每日上限**（上限 360，任务合计 600）', () {
    // 三个各 200 分钟的任务，合计 600 > 上限 360。容量充足（1020 分钟），
    // 因此超限只能来自上限本身。
    final problem = _problem(
      tasks: [_task('a', 200), _task('b', 200), _task('c', 200)],
      dailyLimit: 360,
    );
    final proposal = DeterministicScheduleEngine(_zones).generate(problem);

    expect(
      _movableMinutesOnDay(proposal.blocks),
      lessThanOrEqualTo(360),
      reason:
          '每日上限约束的是最终安排结果；实际 '
          '${_movableMinutesOnDay(proposal.blocks)} 分钟',
    );
  });

  test('**提案能通过 PlanValidator**：引擎口径与校验器口径一致', () {
    // 这条是上面那条的真正意义：如果引擎在选块时不查上限，它会排出一份超限的提案，
    // 而 `PlanValidator` 随后判它无效——用户看到的是"生成计划失败"或提案被拒。
    final problem = _problem(
      tasks: [_task('a', 300), _task('b', 300)],
      dailyLimit: 360,
    );
    final proposal = DeterministicScheduleEngine(_zones).generate(problem);

    expect(
      PlanValidator(_zones).validate(problem, proposal.blocks),
      isEmpty,
      reason: '引擎排出的提案必须自洽；差异会表现为"引擎说排好了、校验说无效"',
    );
  });

  test('**锁定块不计入可移动上限**（沿用既有规则）', () {
    // 锁定块 300 分钟 + 可移动上限 360：两者是不同的额度，
    // 因此 300 分钟的可移动任务仍然应被排下。
    final locked = PlannedBlock(
      id: 'locked-1',
      taskId: 'locked-task',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 5, 7),
        endUtc: DateTime.utc(2026, 10, 5, 12),
      ),
      locked: true,
    );
    final problem = _problem(
      tasks: [_task('movable', 300)],
      dailyLimit: 360,
      lockedBlocks: [locked],
    );
    final proposal = DeterministicScheduleEngine(_zones).generate(problem);

    final movable = proposal.blocks
        .where((block) => block.taskId == 'movable')
        .fold<int>(0, (sum, block) => sum + block.durationMinutes);
    expect(movable, 300, reason: '锁定块占的是"锁定额度"，不该把可移动任务的每日上限吃满；实际 $movable 分钟');
  });

  test('上限不小于一天时不产生任何截断（1440 = 关闭这条规则）', () {
    final problem = _problem(
      tasks: [_task('a', 300), _task('b', 300)],
      dailyLimit: 1440,
    );
    final proposal = DeterministicScheduleEngine(_zones).generate(problem);

    expect(
      _movableMinutesOnDay(proposal.blocks),
      600,
      reason: '上限等于一天时应按容量排，而不是被上限截成 360',
    );
  });
}
