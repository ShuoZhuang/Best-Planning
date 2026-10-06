import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/backup_assembly.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'planner-database-path-test-',
    );
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('默认文档目录不可写时，将旧数据库迁移到可写目录且不删除原库', () async {
    final documents = Directory(
      '${workspace.path}${Platform.pathSeparator}documents',
    );
    final portable = Directory(
      '${workspace.path}${Platform.pathSeparator}portable-data',
    );
    await documents.create(recursive: true);

    final legacyPath =
        '${documents.path}${Platform.pathSeparator}personal_planner.sqlite';
    final legacy = sqlite3.open(legacyPath);
    legacy.execute('CREATE TABLE marker (value TEXT NOT NULL)');
    legacy.execute("INSERT INTO marker VALUES ('旧数据')");
    legacy.close();

    final selected = await preparePlannerDatabase(
      documentsDirectory: () async => documents,
      fallbackDirectories: [portable],
      writableProbe: (directory) async => directory.path == portable.path,
    );

    expect(
      selected,
      '${portable.path}${Platform.pathSeparator}personal_planner.sqlite',
    );
    expect(await File(legacyPath).exists(), isTrue, reason: '迁移不得删除用户的原数据库');
    final migrated = sqlite3.open(selected, mode: OpenMode.readOnly);
    addTearDown(migrated.close);
    expect(migrated.select('SELECT value FROM marker').single['value'], '旧数据');
  });

  test('AppDatabase 使用调用方解析出的路径，而不是再次回到默认文档目录', () async {
    final databasePath =
        '${workspace.path}${Platform.pathSeparator}selected.sqlite';
    final database = AppDatabase.openDefault(
      databasePath: databasePath,
      tempDirectoryPath: () async => workspace.path,
    );
    addTearDown(database.close);

    await database.customStatement(
      'INSERT INTO settings (key, json_value, updated_at_utc, created_at_utc) '
      'VALUES (?, ?, ?, ?)',
      ['proof', '"written"', 1, 1],
    );
    await database.close();

    final direct = sqlite3.open(databasePath, mode: OpenMode.readOnly);
    addTearDown(direct.close);
    expect(
      direct
          .select("SELECT json_value FROM settings WHERE key = 'proof'")
          .single['json_value'],
      '"written"',
    );
  });
}
