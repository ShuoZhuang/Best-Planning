import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/platform/files/sqlite_database_lifecycle_adapter.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late String databasePath;
  late Database writer;
  Database? keeper;
  var writerClosed = false;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('planner-snapshot-');
    databasePath = '${directory.path}${Platform.pathSeparator}planner.sqlite';
    writerClosed = false;
    writer = sqlite3.open(databasePath);
    writer.execute('PRAGMA journal_mode = WAL');
    writer.execute('CREATE TABLE notes (id TEXT PRIMARY KEY, body TEXT)');
    writer.execute("INSERT INTO notes (id, body) VALUES ('n1', 'hello')");
    // 保留第二个连接：这样关闭 writer 不会触发"最后一个连接关闭"时的自动
    // checkpoint，-wal 中会残留已提交数据，从而复现静默丢数据的场景。
    keeper = sqlite3.open(databasePath);
  });

  tearDown(() async {
    keeper?.close();
    keeper = null;
    if (!writerClosed) writer.close();
    await directory.delete(recursive: true);
  });

  test('WAL 中残留已提交数据时备份快照仍然完整', () async {
    final adapter = SqliteDatabaseLifecycleAdapter(
      databasePath: databasePath,
      supportedSchemaVersion: 1,
      closeDatabase: () async {
        writer.close();
        writerClosed = true;
      },
      reopenDatabase: () async {},
    );
    final destination =
        '${directory.path}${Platform.pathSeparator}snapshot.sqlite';

    await adapter.createConsistentSnapshot(destination);

    final snapshot = sqlite3.open(destination, mode: OpenMode.readOnly);
    try {
      expect(
        snapshot.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'notes'",
        ),
        isNotEmpty,
        reason: '主库副本必须已包含 WAL 中已提交的结构与数据',
      );
      expect(snapshot.select('SELECT body FROM notes').single['body'], 'hello');
    } finally {
      snapshot.close();
    }
  });
}
