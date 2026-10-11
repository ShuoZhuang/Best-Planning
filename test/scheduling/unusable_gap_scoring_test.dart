// 1.8.0（设计规范 §11.4 第 6 条，计划 Task 13）：坏空档因子进入候选评分。
//
// `unusable_gap_test.dart` 钉的是**判据**（哪些空档算无法利用）；本文件钉的是
// **它进了评分**、它与既有的 `fragmentation`（块的形状）是两件不同的事，
// 以及**它当前被刻意关掉**这件事（见第一条用例与 `SchedulingWeights` 的注释）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/candidate_scorer.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/scheduling_weights.dart';

void main() {
  final base = DateTime.utc(2026, 10, 12, 9);

  SchedulableTask task({int minChunkMinutes = 30, int maxChunkMinutes = 90}) =>
      SchedulableTask(
        id: 't1',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: minChunkMinutes,
        maxChunkMinutes: maxChunkMinutes,
        priority: TaskPriority.medium,
        energyLevel: TaskEnergyLevel.medium,
      );

  SchedulingCandidate candidate({int offsetMinutes = 0, int duration = 60}) =>
      SchedulingCandidate(
        id: 'c1',
        taskId: 't1',
        range: TimeRange(
          startUtc: base.add(Duration(minutes: offsetMinutes)),
          endUtc: base.add(Duration(minutes: offsetMinutes + duration)),
        ),
        localDate: base,
      );

  const scorer = CandidateScorer();

  CandidateScore score(CandidateScoringContext context) =>
      scorer.score(candidate(), context);

  test('这一项当前**刻意关掉**：权重为 0，因此不影响任何选择', () {
    // 打开它会让 `schedule_engine_test.dart` 的两条既有用例变红
    // （`golden week` 的缺口 30 → 90、"不区分任务类型"的间隔 10 → 60）。
    // 根因与重开的条件写在 `SchedulingWeights.maximumUnusableGapPenalty` 的注释里。
    expect(
      const SchedulingWeights.v1().maximumUnusableGapPenalty,
      0,
      reason: '重开这一项必须同时让那两条既有用例通过，而不是把权重改大就完事',
    );
  });

  test('无论千分比多大，权重为 0 时因子恒为 0', () {
    for (final permille in const [0, 250, 1000]) {
      final result = score(
        CandidateScoringContext(
          task: task(),
          unusableGapPenaltyPermille: permille,
        ),
      );
      expect(result.factors[ScoringFactor.unusableGap], 0);
    }
  });

  test('这一项**不影响** fragmentation：块形状与空档可用性是两件事', () {
    // 同一个形状的候选（可拆分任务的 60 分钟块，落在 30–90 之间），
    // 换坏空档的深度，fragmentation 必须逐值不变。
    final clean = score(CandidateScoringContext(task: task()));
    final gappy = score(
      CandidateScoringContext(task: task(), unusableGapPenaltyPermille: 800),
    );

    expect(
      gappy.factors[ScoringFactor.fragmentation],
      clean.factors[ScoringFactor.fragmentation],
    );
    expect(gappy.totalScore, clean.totalScore);
  });

  test('因子确实被算出来并按千分比折算（用一份非零权重的配置验证）', () {
    // **不能只靠 `SchedulingWeights.v1` 验证**：它当前是 0，于是"因子接没接上"
    // 这条断言会永远通过。这里换一份非零权重的配置，把折算逻辑本身钉住——
    // 这也正是将来重开这一项时唯一需要改的地方。
    const weighted = CandidateScorer(
      weights: SchedulingWeights.testing(maximumUnusableGapPenalty: -600),
    );

    final shallow = weighted.score(
      candidate(),
      CandidateScoringContext(task: task(), unusableGapPenaltyPermille: 250),
    );
    final deep = weighted.score(
      candidate(),
      CandidateScoringContext(task: task(), unusableGapPenaltyPermille: 1000),
    );

    expect(shallow.factors[ScoringFactor.unusableGap], -150);
    expect(deep.factors[ScoringFactor.unusableGap], -600);
    expect(deep.totalScore, lessThan(shallow.totalScore!));
  });

  test('千分比超出 0..1000 时被夹紧', () {
    const weighted = CandidateScorer(
      weights: SchedulingWeights.testing(maximumUnusableGapPenalty: -600),
    );

    final result = weighted.score(
      candidate(),
      CandidateScoringContext(task: task(), unusableGapPenaltyPermille: 5000),
    );

    expect(result.factors[ScoringFactor.unusableGap], -600);
  });
}
