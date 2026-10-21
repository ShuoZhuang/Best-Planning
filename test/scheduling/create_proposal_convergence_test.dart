// **`createProposal` 收敛性检验**（第 31 轮 §10.2 的下一步）。
//
// ## 背景
//
// 接上跨日分配后 `week_view_test`「真实源跨页面」会挂过 10 分钟。已排除：
// - 排程器在重负载下正常（`scale_smoke_test` 9.9 秒，基线速度）；
// - `ScheduleProblem` 能穿过 `Isolate.run`（`isolate_problem_transfer_test` 2/2 通过）。
//
// 剩下两种可能：
// 1. `PlanningService.createProposal()` 在这种**输入形状**下不收敛（引擎层面）；
// 2. 引擎能收敛，但界面侧的等待条件永远不满足。
//
// 本文件区分这两者：**不经过界面**，直接走 `PlanningService` 的真实装配路径，
// 并给一个硬超时。若超时 ⇒ 是 1；若正常返回 ⇒ 是 2。
//
// 用一条**接近真实日历**的输入：一周窗口、跨午夜睡眠、多个任务与固定日程。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';
  // 与 `week_view_test` 同形：周一零点起一周。
  final window = TimeRange(
    startUtc: zones.localMidnightToUtc(DateTime(2026, 10, 5), zoneId),
    endUtc: zones.localMidnightToUtc(DateTime(2026, 10, 12), zoneId),
  );

  ScheduleProblem weeklyProblem() {
    final rules = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
      minimumSleepMinutes: 420,
      defaultFocusMinutes: 50,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
    );
    // 一周五个工作日各两节课，再加三个任务（含一个跨午夜的睡眠边界）。
    final fixed = <BusyInterval>[
      for (var day = 0; day < 5; day++)
        for (final hour in [8, 14])
          BusyInterval(
            id: 'course-$day-$hour',
            range: TimeRange(
              startUtc: window.startUtc.add(Duration(days: day, hours: hour)),
              endUtc: window.startUtc.add(Duration(days: day, hours: hour + 2)),
            ),
          ),
    ];
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: const [
        SchedulableTask(
          id: 'a',
          requiredMinutes: 120,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 90,
        ),
        SchedulableTask(
          id: 'b',
          requiredMinutes: 210,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 50,
          maxChunkMinutes: 90,
          distributionPolicy: TaskDistributionPolicy.even,
        ),
        SchedulableTask(
          id: 'c',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.continuous,
          minChunkMinutes: 60,
          maxChunkMinutes: 60,
        ),
      ],
      fixedIntervals: fixed,
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: rules,
      dailyPolicies: dailyPoliciesForWindow(
        zones: zones,
        window: window,
        rules: rules,
        timeZoneId: zoneId,
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: rules,
        timeZoneId: zoneId,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'weekly-probe',
    );
  }

  test('**引擎在这种真实形状上必须收敛**（不经过界面）', () {
    final proposal = DeterministicScheduleEngine(zones)
        .generate(weeklyProblem());
    expect(proposal.blocks, isNotEmpty, reason: '真实装配形状下必须排出块；空结果会让页面永远停在加载态');
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('**`createProposal` 必须收敛**（与生产路径一致，含 isolate）', () async {
    final service = PlanningService(
      source: _FixedSource(weeklyProblem()),
      engine: DeterministicScheduleEngine(zones),
    );
    final proposal = await service.createProposal();
    expect(proposal.blocks, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));
}

final class _FixedSource implements ScheduleProblemSource {
  const _FixedSource(this.problem);
  final ScheduleProblem problem;

  @override
  Future<ScheduleProblem> load({
    ScheduleRuleOverride? override,
    TimeRange? window,
  }) async => problem;
}
