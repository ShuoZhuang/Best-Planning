import 'package:personal_planner/core/ids.dart';

enum WeekParity { every, odd, even }

final class WeekSpan {
  const WeekSpan({
    required this.startWeek,
    required this.endWeek,
    this.parity = WeekParity.every,
  }) : assert(startWeek > 0),
       assert(endWeek >= startWeek),
       assert(endWeek <= 60);

  final int startWeek;
  final int endWeek;
  final WeekParity parity;

  @override
  bool operator ==(Object other) =>
      other is WeekSpan &&
      startWeek == other.startWeek &&
      endWeek == other.endWeek &&
      parity == other.parity;

  @override
  int get hashCode => Object.hash(startWeek, endWeek, parity);
}

enum TimetableReviewReason {
  missingName,
  missingWeeks,
  ambiguousWeekday,
  ambiguousPeriods,
  invalidRange,
  unparsedText,
}

final class CourseDraft {
  const CourseDraft({
    required this.id,
    required this.name,
    this.teacher = '',
    this.location = '',
    this.weekday,
    this.startPeriod,
    this.endPeriod,
    this.weekSpans = const [],
    this.areaId,
    this.projectId,
    this.reviewReasons = const {},
    required this.originalText,
  });

  static const Object _unset = Object();

  final String id;
  final String name;
  final String teacher;
  final String location;
  final int? weekday;
  final int? startPeriod;
  final int? endPeriod;
  final List<WeekSpan> weekSpans;
  final EntityId? areaId;
  final EntityId? projectId;
  final Set<TimetableReviewReason> reviewReasons;
  final String originalText;

  CourseDraft copyWith({
    String? id,
    String? name,
    String? teacher,
    String? location,
    Object? weekday = _unset,
    Object? startPeriod = _unset,
    Object? endPeriod = _unset,
    List<WeekSpan>? weekSpans,
    Object? areaId = _unset,
    Object? projectId = _unset,
    Set<TimetableReviewReason>? reviewReasons,
    String? originalText,
  }) => CourseDraft(
    id: id ?? this.id,
    name: name ?? this.name,
    teacher: teacher ?? this.teacher,
    location: location ?? this.location,
    weekday: identical(weekday, _unset) ? this.weekday : weekday as int?,
    startPeriod: identical(startPeriod, _unset)
        ? this.startPeriod
        : startPeriod as int?,
    endPeriod: identical(endPeriod, _unset)
        ? this.endPeriod
        : endPeriod as int?,
    weekSpans: weekSpans ?? this.weekSpans,
    areaId: identical(areaId, _unset) ? this.areaId : areaId as EntityId?,
    projectId: identical(projectId, _unset)
        ? this.projectId
        : projectId as EntityId?,
    reviewReasons: reviewReasons ?? this.reviewReasons,
    originalText: originalText ?? this.originalText,
  );
}

final class TimetableDraft {
  const TimetableDraft({required this.courses, this.detectedTotalWeeks});

  final List<CourseDraft> courses;
  final int? detectedTotalWeeks;
}
