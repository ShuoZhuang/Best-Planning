// 1.8.0（设计规范 §11.4 第 6 条，计划 Task 13）：坏空档因子进入候选评分。
//
// `unusable_gap_test.dart` 钉的是**判据**（哪些空档算无法利用）；本文件钉的是
// **它进了评分**、以及它与既有的 `fragmentation`（块的形状）是两件不同的事。
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

  test('没有坏空档时这一项为 0', () {
    final result = score(CandidateScoringContext(task: task()));

    expect(result.factors[ScoringFactor.unusableGap], 0);
  });

  test('坏空档越深扣得越多，且上限就是权重里的那一项', () {
    final shallow = score(
      CandidateScoringContext(task: task(), unusableGapPenaltyPermille: 250),
    );
    final deep = score(
      CandidateScoringContext(task: task(), unusableGapPenaltyPermille: 1000),
    );

    expect(shallow.factors[ScoringFactor.unusableGap], -125);
    expect(
      deep.factors[ScoringFactor.unusableGap],
      const SchedulingWeights.v1().maximumUnusableGapPenalty,
      reason: '千分比到 1000 时取满权重',
    );
    expect(
      deep.factors[ScoringFactor.unusableGap]!,
      lessThan(shallow.factors[ScoringFactor.unusableGap]!),
    );
  });

  test('这一项**不影响** fragmentation：块形状与空档可用性是两件事', () {
    // 同一个形状的候选（拆分任务的 60 分钟块，落在 30–90 之间），
    // 换坏空档的深度，fragmentation 必须逐值不变。
    final clean = score(CandidateScoringContext(task: task()));
    final gappy = score(
      CandidateScoringContext(task: task(), unusableGapPenaltyPermille: 800),
    );

    expect(
      gappy.factors[ScoringFactor.fragmentation],
      clean.factors[ScoringFactor.fragmentation],
    );
    expect(
      gappy.totalScore,
      lessThan(clean.totalScore!),
      reason: '坏空档必须让总分变低，否则它进了因子也不影响选择',
    );
  });

  test('千分比超出 0..1000 时被夹紧，不会把总分打到负无穷', () {
    final result = score(
      CandidateScoringContext(task: task(), unusableGapPenaltyPermille: 5000),
    );

    expect(
      result.factors[ScoringFactor.unusableGap],
      const SchedulingWeights.v1().maximumUnusableGapPenalty,
    );
  });
}
