import 'package:personal_planner/domain/models/calendar_event.dart';

enum TimetableImportBatchStatus {
  draft('draft'),
  committed('committed'),
  rolledBack('rolledBack');

  const TimetableImportBatchStatus(this.storageValue);
  final String storageValue;

  static TimetableImportBatchStatus fromStorage(String value) =>
      TimetableImportBatchStatus.values.firstWhere(
        (status) => status.storageValue == value,
      );
}

final class TimetableImportBatch {
  const TimetableImportBatch({
    required this.id,
    required this.termId,
    required this.sourceImageHash,
    required this.sourceFileName,
    required this.status,
    required this.createdEventCount,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });

  final String id;
  final String termId;
  final String sourceImageHash;
  final String sourceFileName;
  final TimetableImportBatchStatus status;
  final int createdEventCount;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

final class TimetableImportSeriesWrite {
  const TimetableImportSeriesWrite({
    required this.event,
    required this.rule,
    this.exclusions = const [],
  });

  final CalendarEvent event;
  final RecurrenceRule rule;
  final List<TimetableImportExclusion> exclusions;

  TimetableImportSeriesWrite copyWith({
    CalendarEvent? event,
    RecurrenceRule? rule,
    List<TimetableImportExclusion>? exclusions,
  }) => TimetableImportSeriesWrite(
    event: event ?? this.event,
    rule: rule ?? this.rule,
    exclusions: exclusions ?? this.exclusions,
  );
}

final class TimetableImportExclusion {
  const TimetableImportExclusion({
    required this.id,
    required this.occurrenceStartUtc,
  });

  final String id;
  final DateTime occurrenceStartUtc;
}

final class TimetableImportCommit {
  TimetableImportCommit({
    required this.batchId,
    required this.termId,
    required this.sourceImageHash,
    required this.sourceFileName,
    required this.createdAtUtc,
    required List<TimetableImportSeriesWrite> series,
  }) : series = List.unmodifiable(series) {
    if (!createdAtUtc.isUtc) {
      throw ArgumentError.value(createdAtUtc, 'createdAtUtc', 'Must be UTC.');
    }
  }

  final String batchId;
  final String termId;
  final String sourceImageHash;
  final String sourceFileName;
  final DateTime createdAtUtc;
  final List<TimetableImportSeriesWrite> series;

  TimetableImportBatch get batch => TimetableImportBatch(
    id: batchId,
    termId: termId,
    sourceImageHash: sourceImageHash,
    sourceFileName: sourceFileName,
    status: TimetableImportBatchStatus.committed,
    createdEventCount: series.length,
    createdAtUtc: createdAtUtc,
    updatedAtUtc: createdAtUtc,
  );
}

final class RollbackPreview {
  const RollbackPreview({
    required this.batchId,
    required this.eventIds,
    required this.protectedEventIds,
  });

  final String batchId;
  final Set<String> eventIds;
  final Set<String> protectedEventIds;
}

final class RollbackResult {
  const RollbackResult({
    required this.batchId,
    required this.deletedEventCount,
  });

  final String batchId;
  final int deletedEventCount;
}

final class DuplicateTimetableImportException implements Exception {
  const DuplicateTimetableImportException(this.existingBatchId);
  final String existingBatchId;
}

final class ProtectedTimetableEventsException implements Exception {
  const ProtectedTimetableEventsException(this.eventIds);
  final Set<String> eventIds;
}

abstract interface class TimetableImportRepository {
  Future<TimetableImportBatch> commit(TimetableImportCommit request);

  Future<RollbackPreview> inspectRollback(String batchId);

  Future<RollbackResult> rollback(
    String batchId, {
    Set<String> forceEventIds = const {},
  });
}
