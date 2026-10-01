import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/scheduling/pressure_calculator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  const calculator = PressureCalculator();

  SchedulableTask task({DateTime? dueAtUtc}) => SchedulableTask(
    id: 'thesis',
    requiredMinutes: 360,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
    dueAtUtc: dueAtUtc,
  );

  test('paces a six-hour task evenly across a 21-day capacity window', () {
    final result = calculator.calculate(
      task(dueAtUtc: DateTime.utc(2026, 10, 22)),
      const CapacityModel(
        horizonCapacityMinutes: 420,
        capacityAfterHorizonBeforeDueMinutes: 840,
      ),
    );

    expect(result.requiredNowMinutes, 0);
    expect(result.pacedNowMinutes, 120);
    expect(result.targetMinutes, 120);
  });

  test('raises the current target when later capacity is insufficient', () {
    final result = calculator.calculate(
      task(dueAtUtc: DateTime.utc(2026, 10, 22)),
      const CapacityModel(
        horizonCapacityMinutes: 420,
        capacityAfterHorizonBeforeDueMinutes: 180,
      ),
    );

    expect(result.requiredNowMinutes, 180);
    expect(result.pacedNowMinutes, 252);
    expect(result.targetMinutes, 252);
  });

  test('does not invent deadline pressure for a task without a due date', () {
    final result = calculator.calculate(
      task(),
      const CapacityModel(
        horizonCapacityMinutes: 420,
        capacityAfterHorizonBeforeDueMinutes: 0,
      ),
    );

    expect(result.hasDeadlinePressure, isFalse);
    expect(result.targetMinutes, 0);
  });

  test('capacity estimation never expands beyond 180 days', () {
    final now = DateTime.utc(2026, 10, 1);
    final model = CapacityModel.estimate(
      nowUtc: now,
      horizonEndUtc: now.add(const Duration(days: 7)),
      dueAtUtc: now.add(const Duration(days: 365)),
      capacityForRange: (start, end) => end.difference(start).inDays * 60,
    );

    expect(model.evaluatedUntilUtc, now.add(const Duration(days: 180)));
    expect(model.horizonCapacityMinutes, 420);
    expect(model.capacityAfterHorizonBeforeDueMinutes, 10380);
  });
}
