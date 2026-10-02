import 'dart:io';

import 'package:personal_planner/application/backup_service.dart';
import 'package:sqlite3/sqlite3.dart';

final class SqliteDatabaseLifecycleAdapter implements DatabaseLifecyclePort {
  const SqliteDatabaseLifecycleAdapter({
    required this.databasePath,
    required this.supportedSchemaVersion,
    required this.closeDatabase,
    required this.reopenDatabase,
  });

  final String databasePath;
  @override
  final int supportedSchemaVersion;
  final Future<void> Function() closeDatabase;
  final Future<void> Function() reopenDatabase;

  @override
  Future<void> createConsistentSnapshot(String destination) =>
      _exclusive(() => File(databasePath).copy(destination).then<void>((_) {}));

  @override
  Future<DatabaseInspection> inspect(String candidate) async {
    Database? database;
    try {
      database = sqlite3.open(candidate, mode: OpenMode.readOnly);
      final integrity = database
          .select('PRAGMA integrity_check')
          .single
          .values
          .single;
      return DatabaseInspection(
        schemaVersion: database.userVersion,
        integrityOk: integrity == 'ok',
      );
    } catch (_) {
      return const DatabaseInspection(schemaVersion: -1, integrityOk: false);
    } finally {
      database?.close();
    }
  }

  @override
  Future<void> replaceWith(String validatedDatabase) async {
    await _exclusive(() async {
      final current = File(databasePath);
      final replacement = File('$databasePath.restore-new');
      final rollback = File('$databasePath.restore-old');
      await _deleteIfExists(replacement);
      await _deleteIfExists(rollback);
      await File(validatedDatabase).copy(replacement.path);
      try {
        if (await current.exists()) await current.rename(rollback.path);
        await replacement.rename(current.path);
        await _deleteIfExists(rollback);
        await _deleteSidecars();
      } catch (_) {
        await _deleteIfExists(current);
        if (await rollback.exists()) await rollback.rename(current.path);
        rethrow;
      } finally {
        await _deleteIfExists(replacement);
      }
    });
  }

  @override
  Future<void> eraseAll() async {
    await _exclusive(() async {
      await _deleteIfExists(File(databasePath));
      await _deleteSidecars();
    });
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    await closeDatabase();
    try {
      return await operation();
    } finally {
      await reopenDatabase();
    }
  }

  Future<void> _deleteSidecars() async {
    await _deleteIfExists(File('$databasePath-wal'));
    await _deleteIfExists(File('$databasePath-shm'));
  }

  static Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }
}

final class FileBackupIndexAdapter implements BackupIndexPort {
  const FileBackupIndexAdapter(this.indexPath);
  final String indexPath;

  @override
  Future<void> clear() async {
    final file = File(indexPath);
    if (await file.exists()) await file.delete();
  }
}
