import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  test('reports the exact shortage without scheduling into sleep', () {
    final zones = TimeZoneDatabase();
    final engine = DeterministicScheduleEngine(zones);
    final day = DateTime.utc(2026, 10, 5);
    final sleep = TimeRange(
      startUtc: day.add(const Duration(hours: 20)),
      endUtc: day.add(const Duration(days: 1, hours: 8)),
    );
    final problem = ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: day,
        endUtc: day.add(const Duration(days: 1)),
      ),
      timeZoneId: 'UTC',
      tasks: [
        SchedulableTask(
          id: 'over-capacity',
          requiredMinutes: 180,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 90,
          dueAtUtc: day.add(const Duration(hours: 20)),
        ),
      ],
      fixedIntervals: const [],
      protectedIntervals: [
        BusyInterval(
          id: 'day-protection',
          range: TimeRange(
            startUtc: day.add(const Duration(hours: 10)),
            endUtc: day.add(const Duration(hours: 20)),
          ),
        ),
      ],
      lockedBlocks: const [],
      rules: DefaultSettings.v1().copyWith(
        sleepRange: LocalTimeRange(startMinute: 20 * 60, endMinute: 8 * 60),
        dailyMovableTaskLimitMinutes: 120,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'over-capacity-v1',
    );

    final proposal = engine.generate(problem);

    expect(proposal.metrics.isFullyFeasible, isFalse);
    // 每日可移动上限是 120 分钟，而"任意两个任务块之间必须保留休息"意味着
    // 120 分钟的窗口放不下 120 分钟的任务：两段之间还要留出 10 分钟间隔，
    // 因此可排上限是 110 分钟（两段各 55 分钟）。
    //
    // 这里断言"缺口被如实报告"这一不变式，而不是某个具体分钟数：具体数值取决于
    // 分配器的贪心选择（当前先取最高分的 90 分钟段，之后 30 分钟因放不下间隔而
    // 无法安排），未来改进求解质量时不应让本测试失败。
    final scheduled = proposal.metrics.scheduledMinutes;
    expect(scheduled, lessThanOrEqualTo(110));
    expect(proposal.metrics.unscheduledMinutes, 180 - scheduled);
    expect(proposal.unscheduled.single.shortageMinutes, 180 - scheduled);
    // **容量缺口只有一个结构化来源**（1.8.0，冻结决策 §1.5）。
    //
    // 本用例此前断言 `conflicts.singleWhere(insufficientCapacity)` ——
    // 那是把"引擎为每条 unscheduled 再补一条冲突"这个**重复建模**固定成了契约
    // （R6，也是截图里"同一任务既说可用时间不足、又说还缺 76 分钟"的成因）。
    // 现在缺口只由 `unscheduled` 表达，冲突列表里不得再有 `insufficientCapacity`。
    expect(
      proposal.conflicts.where(
        (item) => item.code == ConflictCode.insufficientCapacity,
      ),
      isEmpty,
      reason: '同一个缺口在 unscheduled 与 conflicts 里各说一次，用户会以为是两个问题',
    );
    expect(
      proposal.unscheduled.single.shortageMinutes,
      180 - scheduled,
      reason: '缺口分钟必须仍然精确可读',
    );
    expect(
      proposal.blocks.any((block) => block.range.overlaps(sleep)),
      isFalse,
    );
  });

  test('deterministic result is JSON-identical for 100 runs', () {
    final zones = TimeZoneDatabase();
    final engine = DeterministicScheduleEngine(zones);
    final day = DateTime.utc(2026, 10, 5);
    final problem = ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: day,
        endUtc: day.add(const Duration(days: 1)),
      ),
      timeZoneId: 'UTC',
      tasks: const [
        SchedulableTask(
          id: 'b',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
        ),
        SchedulableTask(
          id: 'a',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
        ),
      ],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: DefaultSettings.v1(),
      preferences: const PreferenceProfile(),
      inputHash: 'stable-v1',
    );
    String signature() => jsonEncode([
      for (final block in engine.generate(problem).blocks)
        [block.id, block.taskId, block.startUtc.toIso8601String()],
    ]);
    final expected = signature();

    for (var run = 0; run < 100; run++) {
      expect(signature(), expected);
    }
  });
}
