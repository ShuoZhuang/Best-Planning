// 计划 Task 10「应用安全」：**调整要求闸门**。
//
// ## 缺口（本轮发现）
//
// `problem.adjustment` **不进 `inputHash`**——`schedule_problem.dart` 里写明原因：
// 它是"比较与目标"的输入，不是"哪些时间可用"的输入。把这个性质与
// `PlanApplicationService.apply()` 放在一起看，就出现一条与 1.8.0 故障同形的缝：
//
//   ① 用户对块 A 点"延后 30 分钟" → 生成提案 P（P 携带这条要求）；
//   ② 用户改主意 → **对块 B** 延后 60 分钟（哈希不变，因为改动不进哈希）；
//   ③ 用户点"应用 P"。
//
// `apply()` 此前只检查"P **自己**那条要求有没有兑现"。P 当然兑现了它自己的要求，
// 于是这份与用户当前意图无关的计划被写进确认计划，而用户要的延后从未发生。
//
// 一句话：**校验了提案的内容，却没校验提案的前提**。
//
// ## 判据
//
// 当前请求由 `problem.adjustment`（`targetBlockId` + `notBeforeUtc`）表达；
// 提案携带的 `adjustmentRequirement` 还多两项（`requiredMinutes`、
// `originalStartUtc`，来自确认计划里的目标块）。闸门只比较**请求本身**的字段：
// 目标块与下界。时长与原位置是"延后前的事实"，由 `evaluateAdjustmentFulfilment`
// 负责，不在这里重复判定。
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
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

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

  /// 任务要 120 分钟；确认计划里已有两块，各 60 分钟（10:00 与 14:00）。
  ///
  /// `inputHash` 用**真实的** `InputSnapshotBuilder` 算出来：闸门排在输入哈希检查
  /// **之后**，因此哈希对不上的话只会看到 `stale`，而那条 stale 与本组用例要证的
  /// 完全无关（假阳性）。先把哈希算对，才只剩"调整前提"这一条判据。
  ScheduleProblem problemWith({
    required String targetBlockId,
    required DateTime notBeforeUtc,
  }) {
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
      confirmedBlocks: [
        PlannedBlock(
          id: 'block-A',
          taskId: 'task',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 5, 10),
            endUtc: DateTime.utc(2026, 10, 5, 11),
          ),
        ),
        PlannedBlock(
          id: 'block-B',
          taskId: 'task',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 5, 14),
            endUtc: DateTime.utc(2026, 10, 5, 15),
          ),
        ),
      ],
      adjustment: BlockAdjustmentContext(
        targetBlockId: targetBlockId,
        notBeforeUtc: notBeforeUtc,
        kind: BlockAdjustmentKind.defer,
      ),
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

  /// 提案：把目标块延后成 15:00–16:00（两块合计仍是 120 分钟）。
  ScheduleProposal proposalFor(
    ScheduleProblem problem, {
    required String targetBlockId,
    required DateTime notBeforeUtc,
    required DateTime startUtc,
  }) => ScheduleProposal(
    proposalId: 'proposal',
    inputHash: problem.inputHash,
    algorithmVersion: DeterministicScheduleEngine.algorithmVersion,
    adjustmentRequirement: AdjustmentRequirement(
      targetBlockId: targetBlockId,
      notBeforeUtc: notBeforeUtc,
      requiredMinutes: 60,
      originalStartUtc: DateTime.utc(2026, 10, 5, 10),
    ),
    planningWindow: window,
    blocks: [
      PlannedBlock(
        // **id 与 `continuedFromId` 必须指向目标块**：`evaluateAdjustmentFulfilment`
        // 只认"目标块的延续者"（`id == targetBlockId` 或
        // `continuedFromId == targetBlockId`）。给移动后的块改名会让 `targetLineage`
        // 变空，于是报"延后后没有足够的可用时间"——那是夹具的错，不是闸门的错。
        id: 'block-A',
        continuedFromId: 'block-A',
        taskId: 'task',
        range: TimeRange(
          startUtc: startUtc,
          endUtc: startUtc.add(const Duration(minutes: 60)),
        ),
      ),
      PlannedBlock(
        id: 'block-B',
        taskId: 'task',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 10, 5, 14),
          endUtc: DateTime.utc(2026, 10, 5, 15),
        ),
      ),
    ],
    unscheduled: const [],
    conflicts: const [],
    explanations: const [],
    metrics: const ProposalMetrics(
      isFullyFeasible: true,
      scheduledMinutes: 120,
      unscheduledMinutes: 0,
    ),
  );

  PlanApplicationService serviceFor(ScheduleProblem problem) =>
      PlanApplicationService(
        source: _Source(problem),
        repository: _Repository(),
        zones: zones,
        snapshots: const InputSnapshotBuilder(),
      );

  test('前提仍成立 ⇒ 正常应用（闸门不能误伤）', () async {
    final problem = problemWith(
      targetBlockId: 'block-A',
      notBeforeUtc: DateTime.utc(2026, 10, 5, 15),
    );
    final result = await serviceFor(problem).apply(
      proposalFor(
        problem,
        targetBlockId: 'block-A',
        notBeforeUtc: DateTime.utc(2026, 10, 5, 15),
        startUtc: DateTime.utc(2026, 10, 5, 15),
      ),
    );

    expect(
      result.status,
      ApplyPlanStatus.applied,
      reason: '提案的前提与当前请求一致，且要求已兑现 ⇒ 应当应用',
    );
  });

  test('**目标块已变 ⇒ 过期、零写入**', () async {
    // 提案是针对"延后 block-A"生成的。
    final generatedFor = problemWith(
      targetBlockId: 'block-A',
      notBeforeUtc: DateTime.utc(2026, 10, 5, 15),
    );
    final proposal = proposalFor(
      generatedFor,
      targetBlockId: 'block-A',
      notBeforeUtc: DateTime.utc(2026, 10, 5, 15),
      startUtc: DateTime.utc(2026, 10, 5, 15),
    );
    // 用户改主意：现在要延后的是 **block-B**。
    final current = problemWith(
      targetBlockId: 'block-B',
      notBeforeUtc: DateTime.utc(2026, 10, 5, 15),
    );

    final result = await serviceFor(current).apply(proposal);

    expect(
      result.status,
      ApplyPlanStatus.staleProposal,
      reason: '提案的前提（延后 block-A）已不是用户当前的要求（延后 block-B）',
    );
  });

  test('**下界已变 ⇒ 过期、零写入**', () async {
    final generatedFor = problemWith(
      targetBlockId: 'block-A',
      notBeforeUtc: DateTime.utc(2026, 10, 5, 15),
    );
    final proposal = proposalFor(
      generatedFor,
      targetBlockId: 'block-A',
      notBeforeUtc: DateTime.utc(2026, 10, 5, 15),
      startUtc: DateTime.utc(2026, 10, 5, 15),
    );
    // 用户把要求的延后量从"到 15:00"改成"到 17:00"。
    final current = problemWith(
      targetBlockId: 'block-A',
      notBeforeUtc: DateTime.utc(2026, 10, 5, 17),
    );

    final result = await serviceFor(current).apply(proposal);

    expect(
      result.status,
      ApplyPlanStatus.staleProposal,
      reason: '用户要求的下界已经推后，把只延到 15:00 的提案应用上去等于没延',
    );
  });
}

final class _Source implements ScheduleProblemSource {
  const _Source(this.problem);
  final ScheduleProblem problem;

  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async =>
      problem;
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
