// **Isolate 边界检验**（第 31 轮 §10.1 的假设）。
//
// ## 背景
//
// 接上跨日分配后，`week_view_test`「真实源跨页面」会**挂过 10 分钟**。已排除：
// 排程器本身（`scale_smoke_test` 在本机以基线速度 9.9 秒跑完）。
//
// 该用例的注释点出关键事实：**页面停在加载指示器上时，`pumpAndSettle` 会一路等到超时**。
// 于是"挂住"⟺"三个页面永远没拿到计划"。
//
// `PlanningService.createProposal()` 把引擎放进 `Isolate.run`，并在闭包里显式做了
// `TimeZoneDatabase();` 来预置 isolate 侧的时区数据。跨日分配引入了两个**新类型**
// （`DayAllocationInput` / `DayAllocationPlan`）与一个新的加密依赖
// （`AllocationRotation` 用 `SHA-256` 做轮换键）。它们都不经过 isolate——分配器在
// 引擎内部同步调用——**除非** `ScheduleProblem` 本身已经无法跨 isolate 传递。
//
// ## 本文件要回答的问题
//
// `ScheduleProblem`（含新的 `dailyPolicies`、`weeklyLifeQuotaByWeekStart`）
// 能不能原样穿过 `Isolate.run`？如果**不能**，`createProposal` 就会在 isolate 里
// 抛错或永久挂起，而页面永远等不到提案——那正好解释观测到的现象。
//
// **这条检验不依赖跨日分配接线**：它只测"问题对象能不能过 isolate"，
// 因此在当前 HEAD 上就能跑。
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
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
  final window = TimeRange(
    startUtc: zones.localMidnightToUtc(DateTime(2026, 10, 5), zoneId),
    endUtc: zones.localMidnightToUtc(DateTime(2026, 10, 12), zoneId),
  );

  ScheduleProblem problem() {
    final rules = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
      minimumSleepMinutes: 420,
      defaultFocusMinutes: 50,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
    );
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: const [
        SchedulableTask(
          id: 'task',
          requiredMinutes: 120,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 90,
        ),
      ],
      fixedIntervals: const [],
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
      inputHash: 'isolate-probe',
    );
  }

  test(
    '**`ScheduleProblem` 能原样穿过 `Isolate.run`**（`PlanningService` 走的就是这条路）',
    () async {
      final prepared = problem();
      final blocks = await Isolate.run(() {
        // 与 `PlanningService.createProposal` 里的写法一致：先预置时区数据。
        TimeZoneDatabase();
        return DeterministicScheduleEngine(TimeZoneDatabase())
            .generate(prepared)
            .blocks
            .length;
      });

      expect(
        blocks,
        greaterThan(0),
        reason: 'isolate 里必须能真的排出块；0 说明问题对象过了边界但规则丢了',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('**逐日策略在 isolate 内仍然可用**（不会退回窗口首日规则）', () async {
    // `policyForLocalDate` 缺键时抛 `StateError`。若逐日策略没能过 isolate，
    // 引擎在 isolate 里一取策略就会抛——这条用例因此能区分
    // "对象过了边界但字段丢了" 与 "整体正常"。
    final prepared = problem();
    final minutes = await Isolate.run(() {
      TimeZoneDatabase();
      final engine = DeterministicScheduleEngine(TimeZoneDatabase());
      final proposal = engine.generate(prepared);
      return proposal.blocks.fold<int>(
        0,
        (sum, block) => sum + block.durationMinutes,
      );
    });

    expect(
      minutes,
      greaterThan(0),
      reason: '逐日策略若丢失，引擎会在 isolate 内抛 StateError 而不是返回 0',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
