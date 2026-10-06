import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/time_range.dart';

enum CalendarEventSourceKind {
  manual('manual'),
  timetableImport('timetableImport');

  const CalendarEventSourceKind(this.storageValue);

  final String storageValue;

  static CalendarEventSourceKind fromStorage(String value) =>
      CalendarEventSourceKind.values.firstWhere(
        (kind) => kind.storageValue == value,
        orElse: () => CalendarEventSourceKind.manual,
      );
}

final class CalendarEvent {
  CalendarEvent({
    required this.id,
    required String title,
    required this.startAtUtc,
    required this.endAtUtc,
    required this.timeZoneId,
    this.recurrenceRuleId,
    this.exceptionOfId,
    this.locked = true,
    this.areaId,
    this.projectId,
    String location = '',
    String notes = '',
    this.sourceKind = CalendarEventSourceKind.manual,
    this.importBatchId,
    this.logicalCourseId,
    required this.updatedAtUtc,
  }) : title = title.trim(),
       location = location.trim(),
       notes = notes.trim() {
    if (this.title.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Cannot be empty.');
    }
    TimeRange(startUtc: startAtUtc, endUtc: endAtUtc);
    if (!updatedAtUtc.isUtc) {
      throw ArgumentError.value(updatedAtUtc, 'updatedAtUtc', 'Must be UTC.');
    }
    if (timeZoneId.trim().isEmpty) {
      throw ArgumentError.value(timeZoneId, 'timeZoneId', 'Cannot be empty.');
    }
  }

  static const Object _unset = Object();

  final EntityId id;
  final String title;
  final DateTime startAtUtc;
  final DateTime endAtUtc;
  final String timeZoneId;
  final EntityId? recurrenceRuleId;
  final EntityId? exceptionOfId;
  final bool locked;
  final EntityId? areaId;
  final EntityId? projectId;
  final String location;
  final String notes;
  final CalendarEventSourceKind sourceKind;
  final EntityId? importBatchId;
  final EntityId? logicalCourseId;
  final DateTime updatedAtUtc;

  TimeRange get range => TimeRange(startUtc: startAtUtc, endUtc: endAtUtc);

  CalendarEvent copyWith({
    EntityId? id,
    String? title,
    DateTime? startAtUtc,
    DateTime? endAtUtc,
    String? timeZoneId,
    Object? recurrenceRuleId = _unset,
    Object? exceptionOfId = _unset,
    bool? locked,
    Object? areaId = _unset,
    Object? projectId = _unset,
    String? location,
    String? notes,
    CalendarEventSourceKind? sourceKind,
    Object? importBatchId = _unset,
    Object? logicalCourseId = _unset,
    DateTime? updatedAtUtc,
  }) => CalendarEvent(
    id: id ?? this.id,
    title: title ?? this.title,
    startAtUtc: startAtUtc ?? this.startAtUtc,
    endAtUtc: endAtUtc ?? this.endAtUtc,
    timeZoneId: timeZoneId ?? this.timeZoneId,
    recurrenceRuleId: identical(recurrenceRuleId, _unset)
        ? this.recurrenceRuleId
        : recurrenceRuleId as EntityId?,
    exceptionOfId: identical(exceptionOfId, _unset)
        ? this.exceptionOfId
        : exceptionOfId as EntityId?,
    locked: locked ?? this.locked,
    areaId: identical(areaId, _unset) ? this.areaId : areaId as EntityId?,
    projectId: identical(projectId, _unset)
        ? this.projectId
        : projectId as EntityId?,
    location: location ?? this.location,
    notes: notes ?? this.notes,
    sourceKind: sourceKind ?? this.sourceKind,
    importBatchId: identical(importBatchId, _unset)
        ? this.importBatchId
        : importBatchId as EntityId?,
    logicalCourseId: identical(logicalCourseId, _unset)
        ? this.logicalCourseId
        : logicalCourseId as EntityId?,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}

final class RecurrenceRule {
  RecurrenceRule({
    required this.id,
    required Set<int> weekdays,
    required this.localStartMinute,
    required this.durationMinutes,
    this.intervalWeeks = 1,
    required this.validFromLocalDate,
    this.validUntilLocalDate,
    required this.timeZoneId,
  }) : weekdays = Set.unmodifiable(weekdays) {
    if (weekdays.isEmpty || weekdays.any((day) => day < 1 || day > 7)) {
      throw ArgumentError.value(weekdays, 'weekdays');
    }
    if (localStartMinute < 0 || localStartMinute >= 24 * 60) {
      throw ArgumentError.value(localStartMinute, 'localStartMinute');
    }
    if (durationMinutes <= 0) {
      throw ArgumentError.value(durationMinutes, 'durationMinutes');
    }
    if (intervalWeeks < 1 || intervalWeeks > 52) {
      throw ArgumentError.value(
        intervalWeeks,
        'intervalWeeks',
        'Must be between 1 and 52.',
      );
    }
    if (validUntilLocalDate != null &&
        validUntilLocalDate!.isBefore(validFromLocalDate)) {
      throw ArgumentError(
        'validUntilLocalDate cannot precede validFromLocalDate.',
      );
    }
  }

  final EntityId id;
  final Set<int> weekdays;
  final int localStartMinute;
  final int durationMinutes;
  final int intervalWeeks;
  final DateTime validFromLocalDate;
  final DateTime? validUntilLocalDate;
  final String timeZoneId;
}

final class CalendarOccurrence {
  CalendarOccurrence({
    required this.eventId,
    required this.title,
    required this.range,
    required this.locked,
    this.areaId,
    this.projectId,
    this.location = '',
    this.notes = '',
    this.sourceKind = CalendarEventSourceKind.manual,
    this.importBatchId,
    this.logicalCourseId,
  });

  final EntityId eventId;
  final String title;
  final TimeRange range;
  final bool locked;
  final EntityId? areaId;
  final EntityId? projectId;
  final String location;
  final String notes;
  final CalendarEventSourceKind sourceKind;
  final EntityId? importBatchId;
  final EntityId? logicalCourseId;
}
