import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';

final class DriftTimetableImportRepository
    implements TimetableImportRepository {
  DriftTimetableImportRepository(this._database, {DateTime Function()? now})
    : _now = now ?? (() => DateTime.now().toUtc());

  final db.AppDatabase _database;
  final DateTime Function() _now;

  @override
  Future<TimetableImportBatch> commit(TimetableImportCommit request) async {
    final duplicate =
        await (_database.select(_database.timetableImportBatches)
              ..where(
                (row) =>
                    row.termId.equals(request.termId) &
                    row.sourceImageHash.equals(request.sourceImageHash) &
                    row.status.equals(
                      TimetableImportBatchStatus.committed.storageValue,
                    ),
              )
              ..limit(1))
            .getSingleOrNull();
    if (duplicate != null) {
      throw DuplicateTimetableImportException(duplicate.id);
    }

    final timestamp = request.createdAtUtc.microsecondsSinceEpoch;
    final fileName = request.sourceFileName.split(RegExp(r'[\\/]')).last;
    await _database.transaction(() async {
      await _database
          .into(_database.timetableImportBatches)
          .insert(
            db.TimetableImportBatchesCompanion.insert(
              id: request.batchId,
              termId: request.termId,
              sourceImageHash: request.sourceImageHash,
              sourceFileName: fileName,
              status: TimetableImportBatchStatus.committed.storageValue,
              createdEventCount: request.series.length,
              createdAtUtc: timestamp,
              updatedAtUtc: timestamp,
            ),
          );
      for (final series in request.series) {
        if (series.event.recurrenceRuleId != series.rule.id) {
          throw ArgumentError('Event and recurrence rule ids must match.');
        }
        await _database
            .into(_database.recurrenceRules)
            .insert(
              db.RecurrenceRulesCompanion.insert(
                id: series.rule.id,
                weekdaysMask: _weekdaysMask(series.rule.weekdays),
                localStartMinute: series.rule.localStartMinute,
                durationMinutes: series.rule.durationMinutes,
                intervalWeeks: Value(series.rule.intervalWeeks),
                validFromLocalDate: _date(series.rule.validFromLocalDate),
                validUntilLocalDate: Value(
                  series.rule.validUntilLocalDate == null
                      ? null
                      : _date(series.rule.validUntilLocalDate!),
                ),
                timeZoneId: series.rule.timeZoneId,
                createdAtUtc: Value(timestamp),
                updatedAtUtc: Value(timestamp),
              ),
            );
        final event = series.event;
        await _database
            .into(_database.calendarEvents)
            .insert(
              db.CalendarEventsCompanion.insert(
                id: event.id,
                title: event.title,
                startAtUtc: event.startAtUtc.microsecondsSinceEpoch,
                endAtUtc: event.endAtUtc.microsecondsSinceEpoch,
                timeZoneId: event.timeZoneId,
                recurrenceRuleId: Value(event.recurrenceRuleId),
                exceptionOfId: Value(event.exceptionOfId),
                locked: const Value(true),
                areaId: Value(event.areaId),
                projectId: Value(event.projectId),
                location: Value(event.location),
                notes: Value(event.notes),
                sourceKind: Value(
                  CalendarEventSourceKind.timetableImport.storageValue,
                ),
                importBatchId: Value(request.batchId),
                logicalCourseId: Value(event.logicalCourseId),
                createdAtUtc: Value(timestamp),
                updatedAtUtc: timestamp,
              ),
            );
        for (final exclusion in series.exclusions) {
          await _database
              .into(_database.calendarEvents)
              .insert(
                db.CalendarEventsCompanion(
                  id: Value(exclusion.id),
                  title: Value(event.title),
                  startAtUtc: Value(
                    exclusion.occurrenceStartUtc.microsecondsSinceEpoch,
                  ),
                  endAtUtc: Value(
                    exclusion.occurrenceStartUtc.microsecondsSinceEpoch,
                  ),
                  timeZoneId: Value(event.timeZoneId),
                  exceptionOfId: Value(event.id),
                  locked: const Value(true),
                  sourceKind: Value(
                    CalendarEventSourceKind.timetableImport.storageValue,
                  ),
                  importBatchId: Value(request.batchId),
                  logicalCourseId: Value(event.logicalCourseId),
                  createdAtUtc: Value(timestamp),
                  updatedAtUtc: Value(timestamp),
                ),
              );
        }
      }
    });
    return TimetableImportBatch(
      id: request.batchId,
      termId: request.termId,
      sourceImageHash: request.sourceImageHash,
      sourceFileName: fileName,
      status: TimetableImportBatchStatus.committed,
      createdEventCount: request.series.length,
      createdAtUtc: request.createdAtUtc,
      updatedAtUtc: request.createdAtUtc,
    );
  }

  @override
  Future<RollbackPreview> inspectRollback(String batchId) async {
    final batch =
        await (_database.select(_database.timetableImportBatches)
              ..where((row) => row.id.equals(batchId))
              ..limit(1))
            .getSingleOrNull();
    if (batch == null) {
      return RollbackPreview(
        batchId: batchId,
        eventIds: const {},
        protectedEventIds: const {},
      );
    }
    final events =
        await (_database.select(_database.calendarEvents)..where(
              (row) =>
                  row.importBatchId.equals(batchId) &
                  row.exceptionOfId.isNull(),
            ))
            .get();
    final ids = {for (final event in events) event.id};
    final exceptionAnchors = <String>{};
    if (ids.isNotEmpty) {
      final exceptions = await (_database.select(
        _database.calendarEvents,
      )..where((row) => row.exceptionOfId.isIn(ids))).get();
      exceptionAnchors.addAll(
        exceptions
            .where((event) => event.importBatchId != batchId)
            .map((event) => event.exceptionOfId)
            .whereType<String>(),
      );
    }
    final protected = {
      for (final event in events)
        if (event.updatedAtUtc != batch.createdAtUtc ||
            exceptionAnchors.contains(event.id))
          event.id,
    };
    return RollbackPreview(
      batchId: batchId,
      eventIds: Set.unmodifiable(ids),
      protectedEventIds: Set.unmodifiable(protected),
    );
  }

  @override
  Future<RollbackResult> rollback(
    String batchId, {
    Set<String> forceEventIds = const {},
  }) async {
    final preview = await inspectRollback(batchId);
    final unapproved = preview.protectedEventIds.difference(forceEventIds);
    if (unapproved.isNotEmpty) {
      throw ProtectedTimetableEventsException(Set.unmodifiable(unapproved));
    }
    if (preview.eventIds.isEmpty) {
      await (_database.update(
        _database.timetableImportBatches,
      )..where((row) => row.id.equals(batchId))).write(
        db.TimetableImportBatchesCompanion(
          status: Value(TimetableImportBatchStatus.rolledBack.storageValue),
          updatedAtUtc: Value(_now().toUtc().microsecondsSinceEpoch),
        ),
      );
      return RollbackResult(batchId: batchId, deletedEventCount: 0);
    }
    final events = await (_database.select(
      _database.calendarEvents,
    )..where((row) => row.id.isIn(preview.eventIds))).get();
    final ruleIds = events
        .map((event) => event.recurrenceRuleId)
        .whereType<String>()
        .toSet();
    await _database.transaction(() async {
      await (_database.delete(
        _database.calendarEvents,
      )..where((row) => row.exceptionOfId.isIn(preview.eventIds))).go();
      await (_database.delete(
        _database.calendarEvents,
      )..where((row) => row.id.isIn(preview.eventIds))).go();
      if (ruleIds.isNotEmpty) {
        await (_database.delete(
          _database.recurrenceRules,
        )..where((row) => row.id.isIn(ruleIds))).go();
      }
      await (_database.update(
        _database.timetableImportBatches,
      )..where((row) => row.id.equals(batchId))).write(
        db.TimetableImportBatchesCompanion(
          status: Value(TimetableImportBatchStatus.rolledBack.storageValue),
          updatedAtUtc: Value(_now().toUtc().microsecondsSinceEpoch),
        ),
      );
    });
    return RollbackResult(
      batchId: batchId,
      deletedEventCount: preview.eventIds.length,
    );
  }
}

int _weekdaysMask(Set<int> weekdays) =>
    weekdays.fold(0, (mask, day) => mask | (1 << (day - 1)));

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
