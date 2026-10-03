import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/models/calendar_event.dart' as domain;
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';

final class DriftCalendarRepository implements CalendarRepository {
  DriftCalendarRepository(this._database);

  final db.AppDatabase _database;

  @override
  Future<List<domain.CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    if (!startUtc.isUtc || !endUtc.isUtc || !endUtc.isAfter(startUtc)) {
      throw ArgumentError('A valid UTC query range is required.');
    }
    final query = _database.select(_database.calendarEvents)
      ..where(
        (row) =>
            row.startAtUtc.isSmallerThanValue(endUtc.microsecondsSinceEpoch) &
            row.endAtUtc.isBiggerThanValue(startUtc.microsecondsSinceEpoch),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.startAtUtc)]);
    final rows = await query.get();
    return rows
        .map(
          (row) => domain.CalendarOccurrence(
            eventId: row.id,
            title: row.title,
            range: TimeRange(
              startUtc: DateTime.fromMicrosecondsSinceEpoch(
                row.startAtUtc,
                isUtc: true,
              ),
              endUtc: DateTime.fromMicrosecondsSinceEpoch(
                row.endAtUtc,
                isUtc: true,
              ),
            ),
            locked: row.locked,
            areaId: row.areaId,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> save(domain.CalendarEvent event) {
    final modifiedAt = event.updatedAtUtc.microsecondsSinceEpoch;
    return _database
        .into(_database.calendarEvents)
        .insert(
          db.CalendarEventsCompanion(
            id: Value(event.id),
            title: Value(event.title),
            startAtUtc: Value(event.startAtUtc.microsecondsSinceEpoch),
            endAtUtc: Value(event.endAtUtc.microsecondsSinceEpoch),
            timeZoneId: Value(event.timeZoneId),
            recurrenceRuleId: Value(event.recurrenceRuleId),
            exceptionOfId: Value(event.exceptionOfId),
            locked: Value(event.locked),
            areaId: Value(event.areaId),
            createdAtUtc: Value(modifiedAt),
            updatedAtUtc: Value(modifiedAt),
          ),
          // A brand new event is created and modified at the same instant. For an
          // existing one the conflict branch preserves the recorded creation time
          // and only advances the modification time (FR-DATA-08).
          onConflict: DoUpdate(
            (old) => db.CalendarEventsCompanion(
              title: Value(event.title),
              startAtUtc: Value(event.startAtUtc.microsecondsSinceEpoch),
              endAtUtc: Value(event.endAtUtc.microsecondsSinceEpoch),
              timeZoneId: Value(event.timeZoneId),
              recurrenceRuleId: Value(event.recurrenceRuleId),
              exceptionOfId: Value(event.exceptionOfId),
              locked: Value(event.locked),
              areaId: Value(event.areaId),
              updatedAtUtc: Value(modifiedAt),
            ),
          ),
        );
  }
}
