import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_plan_preview_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';
import 'execution/execution_test_support.dart';

final class _FixedSource implements ScheduleProblemSource {
  _FixedSource(this.problem);

  final ScheduleProblem problem;

  @override
  Future<ScheduleProblem> load({
    ScheduleRuleOverride? override,
    TimeRange? window,
  }) async => problem;
}

void main() {
  test('执行预览被拒绝后，普通生成仍能产出计划且不残留预排块', () async {
    final harness = await ExecutionTestHarness.create();
    addTearDown(harness.close);
    final zones = TimeZoneDatabase();
    final now = harness.clock.nowUtc();
    final window = TimeRange(
      startUtc: now,
      endUtc: now.add(const Duration(days: 7)),
    );
    final rules = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 23 * 60, endMinute: 7 * 60),
      minimumSleepMinutes: 300,
      defaultFocusMinutes: 45,
      breakMinutes: 5,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
      minChunkMinutes: 25,
      maxChunkMinutes: 90,
    );
    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: 'Asia/Shanghai',
      tasks: [
        SchedulableTask(
          id: 'task-1',
          requiredMinutes: 45,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 25,
          maxChunkMinutes: 90,
          availableFromUtc: now,
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
        timeZoneId: 'Asia/Shanghai',
      ),
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
        zones: zones,
        window: window,
        rules: rules,
        timeZoneId: 'Asia/Shanghai',
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'hash',
    );
    final planning = PlanningService(
      source: _FixedSource(problem),
      engine: DeterministicScheduleEngine(zones),
      clock: harness.clock,
    );
    final previews = PendingPlanPreviewService(
      repository: DriftRecurringExecutionRepository(
        harness.database,
        clock: harness.clock,
        idGenerator: harness.ids,
      ),
      plans: DriftPlanRepository(harness.database),
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final first = await planning.createProposal();
    await previews.saveProposal(
      proposal: first,
      basePlanVersionId: 'plan-1',
      window: window,
      timeZoneId: 'Asia/Shanghai',
    );
    await previews.reject(first.proposalId, reason: '不想提前排');
    expect(await previews.active(), isNull);

    final normal = await planning.createProposal();
    expect(normal.blocks, isNotEmpty);
    expect(normal.blocks.map((block) => block.taskId), everyElement('task-1'));
  });
}
