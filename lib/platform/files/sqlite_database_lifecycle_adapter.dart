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
      _exclusive(() async {
        await _checkpointWriteAheadLog();
        await File(databasePath).copy(destination);
      });

  /// 备份前把 WAL 中已提交的内容显式并回主库（技术设计 §11.1）。
  ///
  /// 关闭最后一个连接时 SQLite 通常会自动 checkpoint 并删除 `-wal`，但该行为
  /// 只在"确实是最后一个连接且 checkpoint 成功"时成立。若其他连接仍然打开，
  /// `-wal` 会连同未并回的已提交数据一起保留，此时直接复制主库会得到一份
  /// **结构完整但内容过期**的快照：manifest 长度、SHA-256 与
  /// `PRAGMA integrity_check` 全部通过，丢失的数据无法被察觉。
  ///
  /// 因此这里显式执行 FULL checkpoint，并以 `busy` 判断其是否真正完成；
  /// 未完成时让备份失败，而不是静默产出过期快照。
  ///
  /// 这里刻意不要求 `-wal` 为空：FULL checkpoint 保证所有已提交帧都已写入主库，
  /// 但不截断 WAL；只有 TRUNCATE 模式才会清空文件，而它在其他连接仅处于打开
  /// 状态时就可能返回 busy，从而让正常备份失败。快照只复制主库文件，因此
  /// "帧已并回主库"才是正确的判据。
  Future<void> _checkpointWriteAheadLog() async {
    final wal = File('$databasePath-wal');
    if (!await wal.exists()) return;
    final database = sqlite3.open(databasePath);
    var busy = 0;
    try {
      final rows = database.select('PRAGMA wal_checkpoint(FULL)');
      if (rows.isNotEmpty) busy = rows.first['busy'] as int? ?? 0;
    } finally {
      database.close();
    }
    if (busy != 0) {
      throw const BackupValidationException('walNotCheckpointed');
    }
  }

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
