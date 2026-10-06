import 'package:personal_planner/application/timetable_conflict_detector.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';
import 'package:personal_planner/domain/services/recurrence_expander.dart';

enum TimetableDuplicateKind { exact, possibleUpdate }

enum TimetableDuplicateResolution { skip, update, create }

final class TimetableDuplicate {
  const TimetableDuplicate({
    required this.courseId,
    required this.kind,
    required this.resolution,
    required this.existingEventIds,
  });

  final String courseId;
  final TimetableDuplicateKind kind;
  final TimetableDuplicateResolution resolution;
  final Set<String> existingEventIds;
}

final class TimetablePreviewSeries {
  const TimetablePreviewSeries({
    required this.id,
    required this.courseId,
    required this.event,
    required this.rule,
    required this.weekSpan,
  });

  final String id;
  final String courseId;
  final CalendarEvent event;
  final RecurrenceRule rule;
  final WeekSpan weekSpan;
}

final class TimetableImportPreview {
  const TimetableImportPreview({
    required this.series,
    required this.occurrences,
    required this.conflicts,
    required this.duplicates,
    required this.reviewReasons,
  });

  final List<TimetablePreviewSeries> series;
  final List<TimetablePreviewOccurrence> occurrences;
  final List<TimetableConflict> conflicts;
  final List<TimetableDuplicate> duplicates;
  final Map<String, Set<TimetableReviewReason>> reviewReasons;
}

final class TimetableImportService {
  TimetableImportService({
    required this.calendarRepository,
    required TimeZoneDatabase zones,
    this.conflictDetector = const TimetableConflictDetector(),
    this.importRepository,
    this.onScheduleInputChanged,
  }) : _zones = zones,
       _expander = RecurrenceExpander(zones);

  final CalendarRepository calendarRepository;
  final TimeZoneDatabase _zones;
  final RecurrenceExpander _expander;
  final TimetableConflictDetector conflictDetector;
  final TimetableImportRepository? importRepository;
  final void Function(ScheduleInputChange change)? onScheduleInputChanged;

  Future<TimetableImportBatch> commit(TimetableImportCommit request) async {
    final repository = importRepository;
    if (repository == null) {
      throw StateError('Timetable import persistence is not configured.');
    }
    final batch = await repository.commit(request);
    onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '导入课表',
        kind: DomainChangeKind.fixedEventCreated,
      ),
    );
    return batch;
  }

  Future<RollbackPreview> inspectRollback(String batchId) {
    final repository = importRepository;
    if (repository == null) {
      throw StateError('Timetable import persistence is not configured.');
    }
    return repository.inspectRollback(batchId);
  }

  Future<RollbackResult> rollback(
    String batchId, {
    Set<String> forceEventIds = const {},
  }) async {
    final repository = importRepository;
    if (repository == null) {
      throw StateError('Timetable import persistence is not configured.');
    }
    final result = await repository.rollback(
      batchId,
      forceEventIds: forceEventIds,
    );
    onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '撤销课表导入',
        kind: DomainChangeKind.fixedEventChanged,
      ),
    );
    return result;
  }

  Future<TimetableImportPreview> preview(
    TimetableDraft draft,
    AcademicTerm term,
    PeriodTemplate periods,
  ) async {
    final termStartUtc = _zones.localDateTimeToUtc(
      term.firstWeekMonday,
      0,
      term.timeZoneId,
    );
    final afterTerm = term.firstWeekMonday.add(
      Duration(days: term.totalWeeks * DateTime.daysPerWeek),
    );
    final termEndUtc = _zones.localDateTimeToUtc(afterTerm, 0, term.timeZoneId);
    final window = TimeRange(startUtc: termStartUtc, endUtc: termEndUtc);
    final existing = await calendarRepository.occurrencesBetween(
      termStartUtc,
      termEndUtc,
    );
    final byPeriod = {
      for (final entry in periods.entries) entry.periodNumber: entry,
    };
    final series = <TimetablePreviewSeries>[];
    final occurrences = <TimetablePreviewOccurrence>[];
    final review = <String, Set<TimetableReviewReason>>{};

    for (final course in draft.courses) {
      final reasons = {...course.reviewReasons};
      final firstPeriod = course.startPeriod == null
          ? null
          : byPeriod[course.startPeriod];
      final lastPeriod = course.endPeriod == null
          ? null
          : byPeriod[course.endPeriod];
      if (course.weekday == null) {
        reasons.add(TimetableReviewReason.ambiguousWeekday);
      }
      if (firstPeriod == null || lastPeriod == null) {
        reasons.add(TimetableReviewReason.ambiguousPeriods);
      }
      if (course.weekSpans.isEmpty) {
        reasons.add(TimetableReviewReason.missingWeeks);
      }
      if (reasons.isNotEmpty) review[course.id] = Set.unmodifiable(reasons);
      if (course.weekday == null || firstPeriod == null || lastPeriod == null) {
        continue;
      }
      if (lastPeriod.endMinute <= firstPeriod.startMinute) {
        review[course.id] = Set.unmodifiable({
          ...reasons,
          TimetableReviewReason.invalidRange,
        });
        continue;
      }

      for (final (spanIndex, span) in course.weekSpans.indexed) {
        final effective = _effectiveWeeks(span);
        if (effective == null || effective.$2 > term.totalWeeks) {
          review[course.id] = Set.unmodifiable({
            ...reasons,
            TimetableReviewReason.invalidRange,
          });
          continue;
        }
        final firstDate = term.firstWeekMonday.add(
          Duration(
            days:
                (effective.$1 - 1) * DateTime.daysPerWeek +
                course.weekday! -
                DateTime.monday,
          ),
        );
        final lastDate = term.firstWeekMonday.add(
          Duration(
            days:
                (effective.$2 - 1) * DateTime.daysPerWeek +
                course.weekday! -
                DateTime.monday,
          ),
        );
        final id = 'preview-${course.id}-$spanIndex';
        final rule = RecurrenceRule(
          id: '$id-rule',
          weekdays: {course.weekday!},
          localStartMinute: firstPeriod.startMinute,
          durationMinutes: lastPeriod.endMinute - firstPeriod.startMinute,
          intervalWeeks: span.parity == WeekParity.every ? 1 : 2,
          validFromLocalDate: firstDate,
          validUntilLocalDate: lastDate,
          timeZoneId: term.timeZoneId,
        );
        final startUtc = _zones.localDateTimeToUtc(
          firstDate,
          firstPeriod.startMinute,
          term.timeZoneId,
        );
        final event = CalendarEvent(
          id: '$id-event',
          title: course.name,
          startAtUtc: startUtc,
          endAtUtc: startUtc.add(Duration(minutes: rule.durationMinutes)),
          timeZoneId: term.timeZoneId,
          recurrenceRuleId: rule.id,
          locked: true,
          areaId: course.areaId,
          projectId: course.projectId,
          location: course.location,
          notes: course.teacher,
          sourceKind: CalendarEventSourceKind.timetableImport,
          logicalCourseId: course.id,
          updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true),
        );
        series.add(
          TimetablePreviewSeries(
            id: id,
            courseId: course.id,
            event: event,
            rule: rule,
            weekSpan: span,
          ),
        );
        for (final expanded in _expander.expand(rule, window, const [])) {
          occurrences.add(
            TimetablePreviewOccurrence(
              seriesId: id,
              courseId: course.id,
              weekNumber: AcademicWeekCalculator.weekNumber(
                firstWeekMonday: term.firstWeekMonday,
                date: expanded.localDate,
              ),
              range: expanded.range,
            ),
          );
        }
      }
    }

    series.sort((a, b) => _seriesOrder(a, b));
    occurrences.sort((a, b) {
      final course = a.courseId.compareTo(b.courseId);
      if (course != 0) return course;
      return a.range.startUtc.compareTo(b.range.startUtc);
    });
    final duplicates = _duplicates(draft, occurrences, existing);
    return TimetableImportPreview(
      series: List.unmodifiable(series),
      occurrences: List.unmodifiable(occurrences),
      conflicts: conflictDetector.detect(occurrences, existing),
      duplicates: duplicates,
      reviewReasons: Map.unmodifiable(review),
    );
  }

  static (int, int)? _effectiveWeeks(WeekSpan span) {
    var first = span.startWeek;
    var last = span.endWeek;
    if (span.parity == WeekParity.odd) {
      if (first.isEven) first++;
      if (last.isEven) last--;
    } else if (span.parity == WeekParity.even) {
      if (first.isOdd) first++;
      if (last.isOdd) last--;
    }
    return first <= last ? (first, last) : null;
  }

  static int _seriesOrder(TimetablePreviewSeries a, TimetablePreviewSeries b) {
    final course = a.event.title.compareTo(b.event.title);
    if (course != 0) return course;
    final weekday = a.rule.weekdays.single.compareTo(b.rule.weekdays.single);
    if (weekday != 0) return weekday;
    return a.rule.localStartMinute.compareTo(b.rule.localStartMinute);
  }

  static List<TimetableDuplicate> _duplicates(
    TimetableDraft draft,
    List<TimetablePreviewOccurrence> imported,
    List<CalendarOccurrence> existing,
  ) {
    final duplicates = <TimetableDuplicate>[];
    for (final course in draft.courses) {
      final courseOccurrences = imported
          .where((item) => item.courseId == course.id)
          .toList();
      if (courseOccurrences.isEmpty) continue;
      final candidates = existing
          .where(
            (item) =>
                item.sourceKind == CalendarEventSourceKind.timetableImport &&
                _normalize(item.title) == _normalize(course.name),
          )
          .toList();
      final matched = <CalendarOccurrence>[];
      for (final occurrence in courseOccurrences) {
        final match = candidates.where(
          (item) =>
              item.range.startUtc == occurrence.range.startUtc &&
              item.range.endUtc == occurrence.range.endUtc,
        );
        if (match.isEmpty) {
          matched.clear();
          break;
        }
        matched.add(match.first);
      }
      if (matched.length != courseOccurrences.length) continue;
      final metadataSame = matched.every(
        (item) =>
            item.location.trim() == course.location.trim() &&
            item.notes.trim() == course.teacher.trim(),
      );
      duplicates.add(
        TimetableDuplicate(
          courseId: course.id,
          kind: metadataSame
              ? TimetableDuplicateKind.exact
              : TimetableDuplicateKind.possibleUpdate,
          resolution: metadataSame
              ? TimetableDuplicateResolution.skip
              : TimetableDuplicateResolution.update,
          existingEventIds: {for (final item in matched) item.eventId},
        ),
      );
    }
    duplicates.sort((a, b) => a.courseId.compareTo(b.courseId));
    return List.unmodifiable(duplicates);
  }

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s　·・•]+'), '');
}
