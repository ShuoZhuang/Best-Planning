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
}
