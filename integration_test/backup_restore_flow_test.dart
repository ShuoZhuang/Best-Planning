import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/platform/files/backup_archive_adapter.dart';
import 'package:personal_planner/platform/files/sqlite_database_lifecycle_adapter.dart';
import 'package:sqlite3/sqlite3.dart';

/// 端到端流程：备份 → 修改 → 校验并恢复。
///
/// 与 `test/application/backup_service_test.dart` 的区别在于这里使用的是**真实的**
/// `SqliteDatabaseLifecycleAdapter`，而不是测试替身，因此会真正走到快照生成路径。
/// 场景特意让已提交数据停留在 WAL 中（保留第二个连接，使关闭写入连接时不触发
/// 自动 checkpoint），以确认快照不会以"结构完整但内容过期"的形式静默丢数据。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('WAL 中已提交的数据会进入备份快照并可完整恢复', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'planner-flow-backup-',
    );
    addTearDown(() async {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    });
    final separator = Platform.pathSeparator;
    final databasePath = '${workspace.path}${separator}planner.sqlite';
    final backupPath = '${workspace.path}${separator}backup.zip';

    final writer = sqlite3.open(databasePath);
    writer.execute('PRAGMA journal_mode = WAL');
    writer.execute(
      'CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL)',
    );
    writer.execute("INSERT INTO tasks (id, title) VALUES ('t1', '完成课程论文')");
    writer.execute('PRAGMA user_version = 1');
    // 第二个连接让 `-wal` 在关闭 writer 后仍然保留。
    final keeper = sqlite3.open(databasePath);

    var writerClosed = false;
    addTearDown(() {
      try {
        keeper.close();
      } catch (_) {
        // 连接可能已被测试体关闭。
      }
      if (!writerClosed) {
        try {
          writer.close();
        } catch (_) {
          // 连接可能已被适配器关闭。
        }
      }
    });

    final lifecycle = SqliteDatabaseLifecycleAdapter(
      databasePath: databasePath,
      supportedSchemaVersion: 1,
      closeDatabase: () async {
        if (writerClosed) return;
        writer.close();
        writerClosed = true;
      },
      reopenDatabase: () async {},
    );
    final service = BackupService(
      database: lifecycle,
      archives: const BackupArchiveAdapter(),
      hashes: const Sha256FileHashAdapter(),
      clock: const SystemClock(),
      appVersion: '1.0.0+1',
      settingsJson: () async => '{"theme":"system"}',
    );

    final manifest = await service.create(backupPath);

    // 快照取自 checkpoint 之后的主库：schema 版本与数据都必须在。
    // 若快照取自未并回 WAL 的主库文件，这里会是 0。
    expect(
      manifest.schemaVersion,
      1,
      reason: '快照必须在 WAL 并回主库之后生成',
    );

    // 关闭第二个连接，避免 Windows 文件占用影响后续恢复。
    keeper.close();

    final validated = await service.validate(backupPath);
    expect(validated.sha256, manifest.sha256);

    // 修改数据，恢复后应回到备份时刻。
    final mutate = sqlite3.open(databasePath);
    mutate.execute("UPDATE tasks SET title = '已被修改'");
    mutate.close();

    await service.restore(backupPath);

    final restored = sqlite3.open(databasePath);
    addTearDown(restored.close);
    expect(
      restored.select('SELECT title FROM tasks').single['title'],
      '完成课程论文',
    );
    expect(restored.userVersion, 1);
  });
}
