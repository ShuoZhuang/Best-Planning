// **视图源是否会静默报错**（第 39 轮）。
//
// `week_view_test`「真实源跨页面」在接上跨日分配后显示 **0 个计划块**，
// 而该用例**没有注册任何 stream error handler**（实测 `grep errorBuilder|onError|hasError`
// 无结果）。`RepositoryScheduleViewSource.load()` 的错误路径是
//
// ```dart
// } on Object catch (error, stackTrace) {
//   if (closed || mine != generation) return;
//   controller.addError(error, stackTrace);   // ← 页面没有 errorBuilder 时被静默吞掉
// }
// ```
//
// 因此"页面空白"完全可能是**一次被吞掉的异常**，而不是"数据没写进去"。
//
// 这条检验直接用**同样的排程形状**（一周窗口、跨午夜睡眠、单任务 60 分钟）
// 跑一次生成 + 诊断，并把任何异常原样抛出——它比界面用例快得多，
// 且能区分"引擎抛错"与"引擎正常但界面没渲染"。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/task_capacity_analyzer.dart';
import 'package:personal_planner/scheduling/task_placement_diagnostics.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';

  ({
    ScheduleProblem problem,
    AvailabilityAnalysis availability,
    DayCapacityLedger ledger,
  })
  build() {
    final start = zones.localMidnightToUtc(DateTime(2026, 10, 5), zoneId);
    final window = TimeRange(
      startUtc: start,
      endUtc: zones.localMidnightToUtc(DateTime(2026, 10, 12), zoneId),
    );
    final rules = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 0, endMinute: 6 * 60),
      minimumSleepMinutes: 60,
      defaultFocusMinutes: 60,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
      granularityMinutes: 5,
    );
    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: const [
        SchedulableTask(
          id: 'paper',
          requiredMinutes: 60,
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
      inputHash: 'error-probe',
    );
    final availability = AvailabilityBuilder(zones).analyze(
      AvailabilityInput(
        planningWindow: window,
        timeZoneId: zoneId,
        rules: rules,
        dailyPolicies: problem.dailyPolicies,
      ),
    );
    final ledger = buildDayCapacityLedger(
      problem: problem,
      availability: availability,
      baselineBlocks: const [],
      zones: zones,
    );
    return (problem: problem, availability: availability, ledger: ledger);
  }

  test('**生成过程不得抛异常**（界面会把异常静默吞掉，所以在这里抓）', () {
    final harness = build();
    expect(
      () => DeterministicScheduleEngine(zones).generate(harness.problem),
      returnsNormally,
      reason:
          '生成抛异常时，视图源的 `addError` 会被没有 errorBuilder 的页面吞掉，'
          '表现就是"三个页面一个块都没有"',
    );
  });

  test('**任务放置诊断不得抛异常**', () {
    final harness = build();
    expect(
      () => diagnoseTaskPlacement(
        problem: harness.problem,
        task: harness.problem.tasks.first,
        remainingMinutes: 60,
        availability: harness.availability,
        ledger: harness.ledger,
        finalBlocks: const [],
        zones: zones,
      ),
      returnsNormally,
      reason: '诊断在生成末尾调用；它抛错会让整次生成失败（并被界面吞掉）',
    );
  });

  test('**容量分析不得抛异常**', () {
    final harness = build();
    expect(
      () => analyzeTaskCapacity(
        task: harness.problem.tasks.first,
        problem: harness.problem,
        availability: harness.availability,
        ledger: harness.ledger,
        allBlocks: const [],
        zones: zones,
      ),
      returnsNormally,
    );
  });
}
