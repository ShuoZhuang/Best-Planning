import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;

final class DriftFocusEntryStore implements FocusEntryStore {
  const DriftFocusEntryStore(this._database);

  final db.AppDatabase _database;

  @override
  Future<FocusSession?> findOpen() async {
    final query = _database.select(_database.timeEntries)
      ..where((row) => row.endedAtUtc.isNull())
      ..orderBy([(row) => OrderingTerm.desc(row.startedAtUtc)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _toDomain(row);
  }

  @override
  Future<void> save(FocusSession session) {
    final metadata = jsonEncode({
      'schemaVersion': 1,
      'phase': session.phase.name,
      'activeMicroseconds': session.activeDuration.inMicroseconds,
      'lastWallAtUtc': session.lastWallAtUtc.microsecondsSinceEpoch,
      'note': session.note,
    });
    return _database
        .into(_database.timeEntries)
        .insert(
          db.TimeEntriesCompanion(
            id: Value(session.id),
            taskId: Value(session.taskId),
            startedAtUtc: Value(session.startedAtUtc.microsecondsSinceEpoch),
            endedAtUtc: Value(session.endedAtUtc?.microsecondsSinceEpoch),
            pausedMinutes: const Value(0),
            source: Value(metadata),
            recoveryState: Value(session.recoveryState.name),
            // The entry begins when the session starts. Repeated saves while the
            // focus timer runs would otherwise reset the creation time, so the
            // conflict branch below leaves it alone (FR-DATA-08).
            createdAtUtc: Value(session.startedAtUtc.microsecondsSinceEpoch),
            updatedAtUtc: Value(session.lastWallAtUtc.microsecondsSinceEpoch),
          ),
          onConflict: DoUpdate(
            (old) => db.TimeEntriesCompanion(
              endedAtUtc: Value(session.endedAtUtc?.microsecondsSinceEpoch),
              pausedMinutes: const Value(0),
              source: Value(metadata),
              recoveryState: Value(session.recoveryState.name),
              updatedAtUtc: Value(session.lastWallAtUtc.microsecondsSinceEpoch),
            ),
          ),
        );
  }

  @override
  Future<List<FocusSession>> confirmedEntries() async {
    final query = _database.select(_database.timeEntries)
      ..where(
        (row) =>
            row.recoveryState.equals(FocusRecoveryState.confirmed.name) &
            row.endedAtUtc.isNotNull(),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.startedAtUtc)]);
    return (await query.get()).map(_toDomain).toList(growable: false);
  }

  FocusSession _toDomain(db.TimeEntry row) {
    final metadata = jsonDecode(row.source) as Map<String, Object?>;
    return FocusSession(
      id: row.id,
      taskId: row.taskId,
      startedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row.startedAtUtc,
        isUtc: true,
      ),
      endedAtUtc: row.endedAtUtc == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(row.endedAtUtc!, isUtc: true),
      lastWallAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        metadata['lastWallAtUtc'] as int,
        isUtc: true,
      ),
      phase: FocusPhase.values.byName(metadata['phase'] as String),
      activeDuration: Duration(
        microseconds: metadata['activeMicroseconds'] as int,
      ),
      recoveryState: FocusRecoveryState.values.byName(row.recoveryState),
      note: metadata['note'] as String? ?? '',
    );
  }
}
