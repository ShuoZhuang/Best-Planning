import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  test('generates 30 to 90 minute chunks at five-minute steps', () {
    const generator = CandidateGenerator();
    final task = SchedulableTask(
      id: 'research',
      requiredMinutes: 360,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
    );
    final start = DateTime.utc(2026, 10, 2, 9);
    final candidates = generator.generate(task, [
      AvailabilitySlot(
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(const Duration(hours: 2)),
        ),
        localDate: DateTime(2026, 10, 2),
      ),
    ]);

    expect(candidates, hasLength(169));
    expect(candidates.map((item) => item.durationMinutes).toSet(), {
      for (var minutes = 30; minutes <= 90; minutes += 5) minutes,
    });
    expect(
      candidates.every(
        (item) =>
            item.durationMinutes % 5 == 0 &&
            item.startUtc.difference(start).inMinutes % 5 == 0,
      ),
      isTrue,
    );
  });

  test('continuous tasks only produce a whole-task candidate', () {
    const generator = CandidateGenerator();
    final task = SchedulableTask(
      id: 'movie',
      requiredMinutes: 120,
      splitMode: TaskSplitMode.continuous,
      minChunkMinutes: 30,
      maxChunkMinutes: 180,
    );
    final start = DateTime.utc(2026, 10, 2, 19);
    final candidates = generator.generate(task, [
      AvailabilitySlot(
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(const Duration(hours: 3)),
        ),
        localDate: DateTime(2026, 10, 2),
      ),
    ]);

    expect(candidates, hasLength(13));
    expect(candidates.every((item) => item.durationMinutes == 120), isTrue);
  });
}
