import 'package:drift/drift.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/domain/repositories/settings_repository.dart';

final class DriftSettingsRepository implements SettingsRepository {
  DriftSettingsRepository(this._database, this._clock);

  final db.AppDatabase _database;
  final Clock _clock;

  @override
  Future<String?> read(String key) async {
    final query = _database.select(_database.settings)
      ..where((row) => row.key.equals(key));
    return (await query.getSingleOrNull())?.jsonValue;
  }

  @override
  Future<void> write(String key, String value) => _database
      .into(_database.settings)
      .insertOnConflictUpdate(
        db.SettingsCompanion(
          key: Value(key),
          jsonValue: Value(value),
          updatedAtUtc: Value(_clock.nowUtc().microsecondsSinceEpoch),
        ),
      );

  @override
  Future<void> remove(String key) => (_database.delete(
    _database.settings,
  )..where((row) => row.key.equals(key))).go();
}
