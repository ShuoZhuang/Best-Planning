// 1.8.0（2026-10-12 故障；计划 Task 8 Step 3 的**短余量矩阵**）。
//
// 人工验收里那张矩阵（计划 §Task 8 Step 3）说的每一行，都必须是**可自动化**的：
//
// | required | min/max | granularity | 必须结果 |
// | ---: | --- | ---: | --- |
// | 15 | 30–90 | 5 | 排 15，无 invalid |
// | 12 | 30–90 | 5 | 排 10、缺 2；可明确应用部分 |
// | 3 | 30–90 | 5 | 不排、缺 3；无伪造块 |
// | 100 | 30–90 | 5 | 最多一个短尾，且恰为剩下的那份余量（§2.2） |
// | 20 continuous | 30–90 | 5 | 单一 20 分钟块，无片段长度 invalid |
// | 20 | 30–90 | 10 | 单一 20 分钟块，全部落 10 分钟网格 |
//
// 因此这里把矩阵**逐行跑成自动化证据**：既走引擎，也走
// `PlanApplicationService`（"能不能真的应用"才是用户关心的事）。
// 人工验收于是只需要核对"运行时行为与这张表一致"，而不是替自动化去发现规则。
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
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/proposal_disposition.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  final day = DateTime.utc(2026, 10, 12);

  /// 一天的空窗口，除睡眠外没有别的占用——容量充足，唯一的阻碍只可能是片段规则。
  ScheduleProblem problem({
    required SchedulableTask task,
    int granularityMinutes = 5,
  }) {
    final window = TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    );
    const zoneId = 'UTC';
    final rules = PlanningRules(
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 23 * 60, endMinute: 7 * 60),
      minimumSleepMinutes: 420,
      defaultFocusMinutes: 50,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
      granularityMinutes: granularityMinutes,
    );
    return ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: [task],
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
      inputHash: 'short-matrix-$granularityMinutes',
    );
  }

  SchedulableTask task({
    required int requiredMinutes,
    int minChunk = 30,
    int maxChunk = 90,
    TaskSplitMode splitMode = TaskSplitMode.splittable,
  }) => SchedulableTask(
    id: 'short',
    requiredMinutes: requiredMinutes,
    splitMode: splitMode,
    minChunkMinutes: minChunk,
    maxChunkMinutes: maxChunk,
  );

  ScheduleProposal generate(SchedulableTask t, {int granularityMinutes = 5}) =>
      DeterministicScheduleEngine(zones)
          .generate(problem(task: t, granularityMinutes: granularityMinutes));

  int scheduledOf(ScheduleProposal proposal) => proposal.blocks
      .where((b) => b.taskId == 'short')
      .fold(0, (sum, b) => sum + b.durationMinutes);

  /// 把引擎产出的提案改成"生成阶段"的形状：**输入哈希必须与来源重放出来的一致**，
  /// 否则应用服务会（正确地）判它过期——而本用例要验的是 partial 授权，不是过期检测。
  ///
  /// 组合根里这一步由 `PlanningService.createProposal` 完成（`_withInputHash`）。
  ScheduleProposal proposalForApply(
    ScheduleProposal generated,
    ScheduleProblem p,
  ) => ScheduleProposal(
    proposalId: generated.proposalId,
    inputHash: withCurrentInputHash(p, const InputSnapshotBuilder()).inputHash,
    algorithmVersion: generated.algorithmVersion,
    planningWindow: generated.planningWindow,
    blocks: generated.blocks,
    unscheduled: generated.unscheduled,
    conflicts: generated.conflicts,
    explanations: generated.explanations,
    metrics: generated.metrics,
  );

  List<PlanningConflict> invalidOf(ScheduleProposal proposal) => proposal
      .conflicts
      .where((c) => c.code == ConflictCode.invalidInput)
      .toList();

  test('矩阵第 1 行：15 分钟、30–90、粒度 5 ⇒ 排 15，无 invalid', () {
    final proposal = generate(task(requiredMinutes: 15));

    expect(scheduledOf(proposal), 15);
    expect(invalidOf(proposal), isEmpty);
    expect(proposal.unscheduled, isEmpty);
    expect(classifyProposal(proposal), ProposalDisposition.fullyApplicable);
  });

  test('矩阵第 2 行：12 分钟、30–90、粒度 5 ⇒ 排 10、缺 2，可明确应用部分', () async {
    final t = task(requiredMinutes: 12);
    final p = problem(task: t);
    final proposal = DeterministicScheduleEngine(zones).generate(p);

    expect(scheduledOf(proposal), 10);
    expect(proposal.unscheduled.single.shortageMinutes, 2);
    expect(invalidOf(proposal), isEmpty, reason: '10 分钟是唯一合法候选，不是非法输入');

    // **"可明确应用部分"必须真的可应用**：completeOnly 拒绝，allowPartial 通过。
    final repository = _CountingPlanRepository();
    final service = PlanApplicationService(
      source: _FixedSource(p),
      repository: repository,
      zones: zones,
    );
    final applicable = proposalForApply(proposal, p);

    final refused = await service.apply(applicable);
    expect(refused.status, ApplyPlanStatus.partialConfirmationRequired);
    expect(repository.writes, 0, reason: '未确认前不得写库');

    final applied = await service.apply(
      applicable,
      mode: PlanApplyMode.allowPartial,
    );
    expect(applied.status, ApplyPlanStatus.applied);
    expect(repository.writes, 1);
  });

  test('矩阵第 3 行：3 分钟、30–90、粒度 5 ⇒ 不排、缺 3，不伪造块', () async {
    final t = task(requiredMinutes: 3);
    final p = problem(task: t);
    final proposal = DeterministicScheduleEngine(zones).generate(p);

    expect(
      proposal.blocks.where((b) => b.taskId == 'short'),
      isEmpty,
      reason: '不足一个粒度 ⇒ 如实不排，绝不伪造片段',
    );
    expect(proposal.unscheduled.single.shortageMinutes, 3);
    expect(invalidOf(proposal), isEmpty, reason: '"排不下"是缺口，不是"输入无效"');

    // 应用层的处置：缺口 ⇒ 需要确认（不是结构性错误，也不是"可以静默应用"）。
    final repository = _CountingPlanRepository();
    final result = await PlanApplicationService(
      source: _FixedSource(p),
      repository: repository,
      zones: zones,
    ).apply(proposalForApply(proposal, p));
    expect(result.status, ApplyPlanStatus.partialConfirmationRequired);
    expect(repository.writes, 0);
  });

  test('矩阵第 4 行：100 分钟、30–90、粒度 5 ⇒ 最多一个短尾，且恰为剩下的那份余量', () {
    final t = task(requiredMinutes: 100);
    final proposal = generate(t);

    expect(proposal.blocks, isNotEmpty);
    for (final block in proposal.blocks) {
      expect(block.durationMinutes, lessThanOrEqualTo(90));
      expect(block.durationMinutes % 5, 0, reason: '所有块都落在 5 分钟网格上');
    }
    // **1.8.0 冻结决策 §2.2**：低于最小片段的块最多一个，且必须恰好等于
    // `shortRemainderAllowance(required − 常规块之和, 粒度)`。
    // 原先这里是"任何块都不得小于 30"，它把最后那一段**合法**的短尾也一并禁掉了，
    // 于是 100 分钟的任务永远排不满（候选生成与最终校验读的不是同一份规则）。
    final shortBlocks = proposal.blocks
        .where((block) => block.durationMinutes < t.minChunkMinutes)
        .toList();
    expect(
      shortBlocks.length,
      lessThanOrEqualTo(1),
      reason: '宽免只针对唯一的最终短尾；两个短块就是普遍放宽',
    );
    final regularTotal = proposal.blocks
        .where((block) => block.durationMinutes >= t.minChunkMinutes)
        .fold<int>(0, (sum, block) => sum + block.durationMinutes);
    for (final block in shortBlocks) {
      expect(
        block.durationMinutes,
        shortRemainderAllowance(
          requiredMinutes: t.requiredMinutes - regularTotal,
          granularityMinutes: 5,
        ),
        reason: '短尾必须恰好是常规块排完之后剩下的那份余量',
      );
    }
    expect(invalidOf(proposal), isEmpty);
  });

  test('矩阵第 5 行：20 分钟**连续**、30–90、粒度 5 ⇒ 单一 20 分钟块，无片段长度 invalid', () {
    final proposal = generate(
      task(requiredMinutes: 20, splitMode: TaskSplitMode.continuous),
    );

    final blocks = proposal.blocks.where((b) => b.taskId == 'short').toList();
    expect(blocks, hasLength(1), reason: '连续任务只允许一个完整块');
    expect(blocks.single.durationMinutes, 20);
    expect(
      invalidOf(proposal),
      isEmpty,
      reason: '连续任务不受可拆分任务的 min/max 片段检查（R5）',
    );
    expect(
      proposal.conflicts.where(
        (c) => c.code == ConflictCode.continuousBlockUnavailable,
      ),
      isEmpty,
    );
  });

  test('矩阵第 6 行：20 分钟、30–90、**粒度 10** ⇒ 单一 20 分钟块，全部落 10 分钟网格', () {
    final proposal = generate(
      task(requiredMinutes: 20),
      granularityMinutes: 10,
    );

    final blocks = proposal.blocks.where((b) => b.taskId == 'short').toList();
    expect(blocks, hasLength(1));
    expect(blocks.single.durationMinutes, 20);
    final step = const Duration(minutes: 10).inMicroseconds;
    expect(
      blocks.single.startUtc.microsecondsSinceEpoch % step,
      0,
      reason: '规则粒度 10 ⇒ 起点必须落在 10 分钟网格上（UTC 纪元对齐）',
    );
    expect(blocks.single.durationMinutes % 10, 0);
    expect(invalidOf(proposal), isEmpty);
  });

  test('矩阵每行都被校验器接受（生成与校验是同一份规则）', () {
    for (final row in [
      (required: 15, granularity: 5, split: TaskSplitMode.splittable),
      (required: 12, granularity: 5, split: TaskSplitMode.splittable),
      (required: 3, granularity: 5, split: TaskSplitMode.splittable),
      (required: 100, granularity: 5, split: TaskSplitMode.splittable),
      (required: 20, granularity: 5, split: TaskSplitMode.continuous),
      (required: 20, granularity: 10, split: TaskSplitMode.splittable),
    ]) {
      final t = task(requiredMinutes: row.required, splitMode: row.split);
      final p = problem(task: t, granularityMinutes: row.granularity);
      final proposal = DeterministicScheduleEngine(zones).generate(p);
      final conflicts = PlanValidator(zones).validate(p, proposal.blocks);
      expect(
        conflicts.where((c) => c.code == ConflictCode.invalidInput),
        isEmpty,
        reason:
            '**生成器与校验器必须互相接受**（R4 的契约分裂就是它们不一致）。'
            '这一行：required=${row.required}, granularity=${row.granularity}, '
            'split=${row.split.name}',
      );
    }
  });
}

/// 固定的排程输入来源。
///
/// **它返回的 problem 必须带上正确的 `inputHash`**：`PlanApplicationService` 重放输入后
/// 会比对哈希，`inputHash: ''` 会被判成 `staleProposal` ——
/// 我第一版就是这么写的，于是"可应用部分"那条实测拿到 `staleProposal`
/// 而不是 `partialConfirmationRequired`（夹具错误，不是产品行为）。
final class _FixedSource implements ScheduleProblemSource {
  _FixedSource(ScheduleProblem problem)
    : problem = withCurrentInputHash(problem, const InputSnapshotBuilder());

  final ScheduleProblem problem;

  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async =>
      problem;
}

/// 记账用的计划仓储：**只数写入次数**，因为本文件关心的是"该不该写"。
final class _CountingPlanRepository implements PlanRepository {
  int writes = 0;

  @override
  Future<ConfirmedPlan?> current() async => null;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async {
    if (proposal.inputHash != expectedInputHash) {
      return ApplyPlanResult.stale();
    }
    writes++;
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
