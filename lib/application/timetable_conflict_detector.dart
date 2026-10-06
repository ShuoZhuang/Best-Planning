import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';

final class TimetablePreviewOccurrence {
  const TimetablePreviewOccurrence({
    required this.seriesId,
    required this.courseId,
    required this.weekNumber,
    required this.range,
  });

  final String seriesId;
  final String courseId;
  final int weekNumber;
  final TimeRange range;
}

final class TimetableConflict {
  const TimetableConflict({required this.imported, required this.existing});

  final TimetablePreviewOccurrence imported;
  final CalendarOccurrence existing;
}

final class TimetableConflictDetector {
  const TimetableConflictDetector();

  List<TimetableConflict> detect(
    List<TimetablePreviewOccurrence> imported,
    List<CalendarOccurrence> existing,
  ) {
    final conflicts = <TimetableConflict>[];
    for (final occurrence in imported) {
      for (final fixed in existing) {
        if (fixed.locked && occurrence.range.overlaps(fixed.range)) {
          conflicts.add(
            TimetableConflict(imported: occurrence, existing: fixed),
          );
        }
      }
    }
    conflicts.sort((a, b) {
      final start = a.imported.range.startUtc.compareTo(
        b.imported.range.startUtc,
      );
      if (start != 0) return start;
      return a.existing.eventId.compareTo(b.existing.eventId);
    });
    return List.unmodifiable(conflicts);
  }
}
