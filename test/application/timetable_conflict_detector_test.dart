import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/timetable_conflict_detector.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';

void main() {
  test('reports overlaps but not adjacent fixed events', () {
    final detector = TimetableConflictDetector();
    final imported = TimetablePreviewOccurrence(
      seriesId: 'series-1',
      courseId: 'course-1',
      weekNumber: 1,
      range: TimeRange(
        startUtc: DateTime.utc(2026, 9, 7, 1),
        endUtc: DateTime.utc(2026, 9, 7, 2, 40),
      ),
    );
    final existing = [
      CalendarOccurrence(
        eventId: 'overlap',
        title: '早会',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 9, 7, 2),
          endUtc: DateTime.utc(2026, 9, 7, 3),
        ),
        locked: true,
      ),
      CalendarOccurrence(
        eventId: 'adjacent',
        title: '上一节课',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 9, 7, 0),
          endUtc: DateTime.utc(2026, 9, 7, 1),
        ),
        locked: true,
      ),
    ];

    final conflicts = detector.detect([imported], existing);

    expect(conflicts, hasLength(1));
    expect(conflicts.single.existing.eventId, 'overlap');
  });
}
