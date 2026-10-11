import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/candidate_scorer.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  const scorer = CandidateScorer();
  final range = TimeRange(
    startUtc: DateTime.utc(2026, 10, 2, 9),
    endUtc: DateTime.utc(2026, 10, 2, 10),
  );
  final candidate = SchedulingCandidate(
    id: 'candidate',
    taskId: 'task',
    range: range,
    localDate: DateTime(2026, 10, 2),
  );

  SchedulableTask task({
    TaskEnergyLevel energy = TaskEnergyLevel.high,
    bool isLifeTask = false,
  }) => SchedulableTask(
    id: 'task',
    requiredMinutes: 60,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
    energyLevel: energy,
    isLifeTask: isLifeTask,
  );

  test('a high-cognitive task prefers a high-energy window', () {
    final high = scorer.score(
      candidate,
      CandidateScoringContext(task: task(), slotEnergyLevel: EnergyLevel.high),
    );
    final low = scorer.score(
      candidate,
      CandidateScoringContext(task: task(), slotEnergyLevel: EnergyLevel.low),
    );

    expect(high.isEligible, isTrue);
    expect(high.totalScore, greaterThan(low.totalScore!));
    expect(high.factors[ScoringFactor.energyMatch], 800);
    expect(low.factors[ScoringFactor.energyMatch], -800);
  });

  test('a life-quota deficit boosts an entertainment task', () {
    final withDeficit = scorer.score(
      candidate,
      CandidateScoringContext(
        task: task(isLifeTask: true),
        lifeQuotaTargetMinutes: 360,
        plannedLifeMinutes: 60,
      ),
    );
    final quotaMet = scorer.score(
      candidate,
      CandidateScoringContext(
        task: task(isLifeTask: true),
        lifeQuotaTargetMinutes: 360,
        plannedLifeMinutes: 360,
      ),
    );

    expect(
      withDeficit.factors[ScoringFactor.lifeQuota],
      greaterThan(quotaMet.factors[ScoringFactor.lifeQuota]!),
    );
    expect(withDeficit.totalScore, greaterThan(quotaMet.totalScore!));
  });

  test('hard-constraint failure rejects even an otherwise excellent score', () {
    final result = scorer.score(
      candidate,
      CandidateScoringContext(
        task: task(isLifeTask: true),
        slotEnergyLevel: EnergyLevel.high,
        deadlineRiskPermille: 1000,
        progressPressurePermille: 1000,
        preferredTimeScore: 500,
        lifeQuotaTargetMinutes: 360,
        plannedLifeMinutes: 0,
        sameTaskAdjacent: true,
        hardConstraintsSatisfied: false,
      ),
    );

    expect(result.isEligible, isFalse);
    expect(result.totalScore, isNull);
    expect(result.factors, isEmpty);
  });

  test('eligible scores are integers with a complete factor breakdown', () {
    final result = scorer.score(
      candidate,
      CandidateScoringContext(task: task()),
    );

    expect(result.totalScore, isA<int>());
    expect(result.factors.keys.toSet(), ScoringFactor.values.toSet());
  });

  test('规范 §12.2 点名的四项都在 breakdown 里，且各有明确定义', () {
    // §12.2 原文要求在 `CandidateScoreBreakdown` 增加可解释项：
    // `orphanGapBefore`、`orphanGapAfter`、`adjustmentDisplacement`、
    // `adjustmentMovedBlockCount`。计划 Task 13 的 Interfaces 一栏把它们列为交付项。
    //
    // **不能只验"键存在"**：上面那条完备性断言已经覆盖了键，而它无法区分
    // "这一项算出来了"与"这一项被塞了个 0 占位"。因此这里分开验两类：
    // 前者（空档那两项）属于候选级、当前也必须能被解释；后者属于**整份方案**级，
    // 在候选级**按定义恒为 0**，由 `LocalRepairPlan.compare` 处理。
    final result = scorer.score(
      candidate,
      CandidateScoringContext(task: task()),
    );

    for (final factor in const [
      ScoringFactor.orphanGapBefore,
      ScoringFactor.orphanGapAfter,
      ScoringFactor.adjustmentDisplacement,
      ScoringFactor.adjustmentMovedBlockCount,
    ]) {
      expect(
        result.factors.containsKey(factor),
        isTrue,
        reason: '§12.2 点名的 ${factor.name} 必须出现在 breakdown 里',
      );
    }

    // 整份方案级的这两项在候选级恒为 0 —— 这是**设计**而不是遗漏：
    // 候选是一次放置，而"总位移"与"移动块数"是整份方案的性质。
    // 若哪天它们变成非 0，说明有人把方案级比较搬到了候选级，
    // 那会让 §11.4 的字典序失去唯一入口。
    expect(result.factors[ScoringFactor.adjustmentDisplacement], 0);
    expect(result.factors[ScoringFactor.adjustmentMovedBlockCount], 0);
  });
}
