import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/backup_assembly.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

/// 升级前快照（路线图 §4.3）。
///
/// 这些用例全部使用**真实文件**：被保护的不变量是"连接打开之前，磁盘上有一份可读的
/// 旧版本副本"，而内存库没有"打开之前"这个状态，用内存库测等于什么都没测。
///
/// 快照目录由调用方注入（生产里默认是数据库旁边的 `pre-upgrade-backups/`），因此用例
/// 不需要也不应该往用户的真实文档目录里写东西。
void main() {
  late Directory workspace;
  late Directory snapshots;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('planner-pre-migration-');
    snapshots = Directory(
      '${workspace.path}${Platform.pathSeparator}snapshots',
    );
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  String databasePathOf(String name) =>
      '${workspace.path}${Platform.pathSeparator}$name';

  /// 建一个 `user_version` 为 [version] 的 SQLite 文件，带一行可辨认的数据。
  Future<String> writeDatabaseAtVersion(int version) async {
    final path = databasePathOf('personal_planner.sqlite');
    final existing = File(path);
    if (await existing.exists()) await existing.delete();
    final database = sqlite3.open(path);
    database.execute('CREATE TABLE marker (value TEXT NOT NULL)');
    database.execute("INSERT INTO marker VALUES ('v$version 的旧数据')");
    database.execute('PRAGMA user_version = $version');
    database.close();
    return path;
  }

  test('v6 库在连接打开前生成可读副本，文件名含原版本与 UTC 时间', () async {
    final path = await writeDatabaseAtVersion(6);

    final snapshot = await createPreMigrationSnapshotIfNeeded(
      path,
      plannerSchemaVersion,
      snapshotDirectory: () async => snapshots,
    );

    expect(snapshot, isNotNull);
    final file = File(snapshot!);
    expect(await file.exists(), isTrue);
    // 文件名必须回答两个问题："能不能直接换回去"（v6）与"什么时候备的"（UTC 时间）。
    expect(file.path, contains('.v6.'));
    expect(file.path, contains('pre-upgrade-'));
    expect(file.path, matches(RegExp(r'\.bak$')));

    // 副本必须能被独立打开，且带着原库的真实内容——不是 0 字节的空壳。
    final restored = sqlite3.open(snapshot, mode: OpenMode.readOnly);
    addTearDown(restored.close);
    expect(
      restored.select('SELECT value FROM marker').single['value'],
      'v6 的旧数据',
    );
    expect(restored.select('PRAGMA user_version').single.values.first, 6);

    // **原库不动**：这一步只读。
    final original = sqlite3.open(path, mode: OpenMode.readOnly);
    addTearDown(original.close);
    expect(
      original.select('SELECT value FROM marker').single['value'],
      'v6 的旧数据',
    );
  });

  test('已经是最新 schema 版本的库不再备份（没有升级可保护）', () async {
    // **这条原先写死 `writeDatabaseAtVersion(7)`**：当时 v7 恰好就是目标版本，于是"已是最新"
    // 与"v7"是同一个集合，用例读起来像是在测"v7 不备份"。v8 一来它就失败了——而生产逻辑
    // 从来没变过（`currentVersion >= targetSchemaVersion` 返回 null）。所以这里改成直接表达
    // 那条**不变量**：版本已经到目标时，没有升级可保护，因此不生成快照。
    final path = await writeDatabaseAtVersion(plannerSchemaVersion);
    expect(
      await createPreMigrationSnapshotIfNeeded(
        path,
        plannerSchemaVersion,
        snapshotDirectory: () async => snapshots,
      ),
      isNull,
    );

    final newer = await writeDatabaseAtVersion(plannerSchemaVersion + 2);
    expect(
      await createPreMigrationSnapshotIfNeeded(
        newer,
        plannerSchemaVersion,
        snapshotDirectory: () async => snapshots,
      ),
      isNull,
    );
    expect(
      snapshots.existsSync()
          ? snapshots.listSync()
          : const <FileSystemEntity>[],
      isEmpty,
    );
  });

  test('空库（user_version = 0）不备份：它将走 onCreate 而不是迁移', () async {
    final path = databasePathOf('personal_planner.sqlite');
    // 0 字节文件：drift 打开时视作全新库。
    await File(path).writeAsBytes(const []);
    expect(
      await createPreMigrationSnapshotIfNeeded(
        path,
        plannerSchemaVersion,
        snapshotDirectory: () async => snapshots,
      ),
      isNull,
    );
    expect(
      await createPreMigrationSnapshotIfNeeded(
        databasePathOf('never-existed.sqlite'),
        plannerSchemaVersion,
        snapshotDirectory: () async => snapshots,
      ),
      isNull,
    );
  });

  test('备份写入失败时抛异常并清掉半成品，绝不带病继续迁移', () async {
    final path = await writeDatabaseAtVersion(6);
    // 让快照目录指向一个**已存在的普通文件**：`create(recursive: true)` 会失败。
    final blocked = File('${workspace.path}${Platform.pathSeparator}blocked');
    await blocked.writeAsString('not a directory');

    await expectLater(
      createPreMigrationSnapshotIfNeeded(
        path,
        plannerSchemaVersion,
        snapshotDirectory: () async =>
            Directory('${blocked.path}${Platform.pathSeparator}nested'),
      ),
      throwsA(isA<PlannerPreMigrationBackupException>()),
    );

    // 原库完好——失败必须停在原库之外。
    final original = sqlite3.open(path, mode: OpenMode.readOnly);
    addTearDown(original.close);
    expect(
      original.select('SELECT value FROM marker').single['value'],
      'v6 的旧数据',
    );
    expect(
      snapshots.existsSync()
          ? snapshots.listSync()
          : const <FileSystemEntity>[],
      isEmpty,
    );
  });

  test('异常自带面向用户的可操作提示，且不泄露堆栈', () async {
    final path = await writeDatabaseAtVersion(6);
    final blocked = File('${workspace.path}${Platform.pathSeparator}blocked2');
    await blocked.writeAsString('not a directory');

    try {
      await createPreMigrationSnapshotIfNeeded(
        path,
        plannerSchemaVersion,
        snapshotDirectory: () async =>
            Directory('${blocked.path}${Platform.pathSeparator}nested'),
      );
      fail('应当抛出 PlannerPreMigrationBackupException');
    } on PlannerPreMigrationBackupException catch (error) {
      expect(error.userMessage, contains('备份'));
      expect(error.userMessage, contains('重新启动'));
      expect(error.userMessage, isNot(contains('#0')));
      expect(error.databasePath, path);
    }
  });

  test('默认快照目录在数据库旁边的 pre-upgrade-backups 下', () async {
    final path = await writeDatabaseAtVersion(6);
    final snapshot = await createPreMigrationSnapshotIfNeeded(
      path,
      plannerSchemaVersion,
    );
    expect(snapshot, isNotNull);
    expect(
      File(snapshot!).parent.path,
      '${workspace.path}${Platform.pathSeparator}pre-upgrade-backups',
    );
  });

  test('目标版本未到 7 时（例如仍是 v6 目标）不备份', () async {
    final path = await writeDatabaseAtVersion(6);
    expect(
      await createPreMigrationSnapshotIfNeeded(
        path,
        6,
        snapshotDirectory: () async => snapshots,
      ),
      isNull,
    );
  });

  test('plannerSchemaVersion 与 AppDatabase 报告的一致', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    // 两处必须是同一个数字：装配层在**打开连接之前**问不到实例，只能读常量；
    // 常量与 `schemaVersion` 漂移的后果是"该备份时不备份"，而那条规则正是本文件守护的。
    expect(database.schemaVersion, plannerSchemaVersion);
    expect(
      plannerSchemaVersion,
      11,
      reason: 'v11 只新增 day_exceptions 表与索引（算法 20 规范 §8.1/§11）',
    );
  });
}
