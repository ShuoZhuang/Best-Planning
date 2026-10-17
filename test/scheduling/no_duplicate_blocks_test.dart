// **重复块检验**（第 33 轮定位）。
//
// `week_view_test`「真实源跨页面」在接上跨日分配后抛 `Bad state: Too many elements`
// ——一个 `.single`／`find.*.single` 看到**多个**匹配。最可能的来源是引擎输出了
// **重复的计划块**：同一个任务在同一时段被排了两次。
//
// 这条检验不看界面，直接检查引擎输出：
// 1. 块 id 不得重复（`PlanValidator` 的硬约束之一）；
// 2. 同一任务的块不得在时间上重叠；
// 3. 同一任务的总分钟不得超过它的目标。
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
      inputHash: 'dup-probe',
    );
  }

  test('**引擎不得输出重复 id 的块**', () {
    final proposal = DeterministicScheduleEngine(zones).generate(problem());
    final ids = proposal.blocks.map((block) => block.id).toList();
    expect(
      ids.toSet().length,
      ids.length,
      reason:
          '块 id 重复会让界面侧的 `.single` 抛 `Bad state: Too many elements`；'
          '实际 ids=$ids',
    );
  });

  test('**同一任务的块不得在时间上重叠**', () {
    final proposal = DeterministicScheduleEngine(zones).generate(problem());
    for (final taskId in {'a', 'b'}) {
      final own = proposal.blocks
          .where((block) => block.taskId == taskId)
          .toList();
      for (var i = 0; i < own.length; i++) {
        for (var j = i + 1; j < own.length; j++) {
          expect(
            own[i].range.overlaps(own[j].range),
            isFalse,
            reason:
                '$taskId 的两个块重叠：${own[i].range.startUtc} 与 ${own[j].range.startUtc}',
          );
        }
      }
    }
  });

  test('**同一任务的总分钟不得超过目标**', () {
    final proposal = DeterministicScheduleEngine(zones).generate(problem());
    for (final entry in {'a': 120, 'b': 210}.entries) {
      final total = proposal.blocks
          .where((block) => block.taskId == entry.key)
          .fold<int>(0, (sum, block) => sum + block.durationMinutes);
      expect(
        total,
        lessThanOrEqualTo(entry.value),
        reason: '${entry.key} 排了 $total 分钟，超过目标 ${entry.value}',
      );
    }
  });
}
