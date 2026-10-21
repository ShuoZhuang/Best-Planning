// 计划 Task 9／Task 12 人工场景 F：**应用层必须挡住"未决/异常"的提案**。
//
// ## 缺口
//
// `ScheduleProposal.outcome` 记录了本次搜索的结果种类，但 `PlanApplicationService.apply()`
// 此前完全不看它。于是一个 `budgetExhausted`（搜索达预算、**既没证明有解也没证明无解**）
// 的提案会落到 `unscheduled.isNotEmpty` 那一支：
//
// | 模式 | 修复前的行为 | 应当 |
// | --- | --- | --- |
// | `completeOnly` | 返回 `partialConfirmationRequired`——把"未决"说成"要不要就这样应用" | 拒绝 |
// | `allowPartial` | **直接写库** | 拒绝 |
//
// 两种都是一次静默的错误应用，而计划 §1.2 第 9 条与 ALG-47 明令预算耗尽
// **不得**与"真的无解"混为一谈。`invariantViolation`（引擎还有合法候选却留缺口）
// 同理：那不是"装不下"，用户要做的不是腾时间。
//
// 本文件钉住的是**应用层的闸门**，与 `scenario_f_budget_exhausted_test.dart`
// （界面可见的组合行为）互补：那条管"用户看到什么"，这条管"数据会不会被写坏"。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';

import '../support/daily_policies.dart';

void main() {
  const zoneId = 'UTC';
  final zones = TimeZoneDatabase();
  final window = TimeRange(
    startUtc: DateTime.utc(2026, 10, 5),
    endUtc: DateTime.utc(2026, 10, 6),
  );
  final rules = PlanningRules(
    energyWindows: const [],
    sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
    minimumSleepMinutes: 420,
    defaultFocusMinutes: 50,
    breakMinutes: 10,
    dailyMovableTaskLimitMinutes: 600,
    weeklyLifeQuotaMinutes: 0,
  );

  /// 任务要 120 分钟，但提案只排了 60（因此 `unscheduled` 非空）——
  /// 这正是"预算耗尽"最容易被误当成"装不下"的形状。
  ScheduleProblem problem() {
    final base = ScheduleProblem(
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
      inputHash: 'pending',
    );
    return withInputHash(
      base,
      const InputSnapshotBuilder().hash(InputSnapshot(problem: base)),
    );
  }

  ScheduleProposal proposalFor(
    ScheduleProblem current,
    SearchOutcomeKind outcome,
  ) => ScheduleProposal(
    proposalId: 'proposal',
    inputHash: current.inputHash,
    algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
    planningWindow: window,
    blocks: [
      PlannedBlock(
        id: 'block-0',
        taskId: 'task',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 10, 5, 9),
          endUtc: DateTime.utc(2026, 10, 5, 10),
        ),
      ),
    ],
    unscheduled: const [UnscheduledTask(taskId: 'task', shortageMinutes: 60)],
    conflicts: const [],
    explanations: const [],
    metrics: const ProposalMetrics(
      isFullyFeasible: false,
      scheduledMinutes: 60,
      unscheduledMinutes: 60,
    ),
    outcome: outcome,
  );

  ({PlanApplicationService service, _Repository repository}) build(
    ScheduleProblem current,
  ) {
    final repository = _Repository();
    return (
      service: PlanApplicationService(
        source: _Source(current),
        repository: repository,
        zones: zones,
        snapshots: const InputSnapshotBuilder(),
      ),
      repository: repository,
    );
  }

  for (final outcome in [
    SearchOutcomeKind.budgetExhausted,
    SearchOutcomeKind.invariantViolation,
  ]) {
    test('**$outcome 在两种模式下都被拒绝且零写入**', () async {
      final current = problem();
      for (final mode in PlanApplyMode.values) {
        final harness = build(current);
        final result = await harness.service.apply(
          proposalFor(current, outcome),
          mode: mode,
        );
        expect(
          result.status,
          ApplyPlanStatus.invalidProposal,
          reason: '$outcome + $mode 必须被拒：它既没证明有解也没证明无解',
        );
        expect(
          harness.repository.appliedCount,
          0,
          reason: '$outcome + $mode 不得写库',
        );
      }
    });
  }

  test('`hardInfeasible` 在 `allowPartial` 下**仍可应用**（闸门不能误伤）', () async {
    final current = problem();
    final harness = build(current);
    final result = await harness.service.apply(
      proposalFor(current, SearchOutcomeKind.hardInfeasible),
      mode: PlanApplyMode.allowPartial,
    );
    expect(
      result.status,
      ApplyPlanStatus.applied,
      reason: '真的无解 + 用户显式授权 ⇒ 应写部分计划（ALG-41）',
    );
    expect(harness.repository.appliedCount, 1);
  });

  test('`hardInfeasible` 在完整模式下要求授权（不静默写部分计划）', () async {
    final current = problem();
    final harness = build(current);
    final result = await harness.service.apply(
      proposalFor(current, SearchOutcomeKind.hardInfeasible),
    );
    expect(result.status, ApplyPlanStatus.partialConfirmationRequired);
    expect(harness.repository.appliedCount, 0);
  });
}

final class _Source implements ScheduleProblemSource {
  const _Source(this.problem);
  final ScheduleProblem problem;

  @override
  Future<ScheduleProblem> load({
    ScheduleRuleOverride? override,
    TimeRange? window,
  }) async => problem;
}

final class _Repository implements PlanRepository {
  var appliedCount = 0;

  @override
  Future<ConfirmedPlan?> current() async => null;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async {
    appliedCount++;
    return ApplyPlanResult.applied(
      ConfirmedPlan(
        id: proposal.proposalId,
        inputHash: proposal.inputHash,
        algorithmVersion: proposal.algorithmVersion,
        blocks: proposal.blocks,
      ),
    );
  }
}
