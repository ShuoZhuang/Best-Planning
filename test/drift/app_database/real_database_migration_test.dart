// 路线图 §12「schema v6→v7 在真实 `1.6.2` 数据上升级成功，数据和外键检查通过」
// 与 §11 Task 13 Step 6。
//
// **为什么这条必须用真实数据而不是合成数据**：`schema_migration_test.dart` 已经用
// `drift_dev` 的 schema 版本器造过 v6 库并逐列比对——它证明的是"迁移逻辑对**它造的那张表**
// 正确"。真实库里有的东西它造不出来：20 张表在一年里被多次迁移改过的**实际列集合**、
// 真实的外键取值、真实的空值分布，以及 `sqlite_sequence` / 索引这类被历史影响的残留。
// 用户报告过的数据事故（卸载前后哈希一致这类检查）都是在这个层面上才看得见的。
//
// **数据来源**：工作区里的 `planner-backup.zip`——应用自己产出的真实备份，内含
// `planner.sqlite`。**刻意不用 `F:\Documents\personal_planner.sqlite`**：那个文件正被运行中的
// 应用占用，而且装着用户唯一的真实数据；为了验证去碰它不可接受。备份同样真实，且没有占用。
//
// **这个文件在本机之外会自己跳过**：备份不入版本库（它是用户数据），因此 CI 上没有它。
// 跳过时给出的是一句说明，而不是一个静默通过的绿勾——"没跑"与"跑过了"必须能分辨。
import 'dart:io';

import 'package:archive/archive.dart';
// `drift` 与 `matcher` 都导出 `isNull` / `isNotNull`，同时导入会歧义；drift 的那两个是查询
// 构造用的，这里用不到，因此把它们挡掉——比给每条断言写 `matcher.isNull` 干净。
import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/backup_assembly.dart';
import 'package:personal_planner/data/database/app_database.dart';

/// 从当前目录逐级向上找 `planner-backup.zip`；找不到返回 `null`。
///
/// 向上找而不是写死路径：测试的工作目录是包根（worktree 里的 `native-implementation`），
/// 而备份在工作区根（它的上一层）。将来备份若被拷进包根，这里也照样找得到。
File? _findRealBackup() {
  var directory = Directory.current;
  for (var depth = 0; depth < 4; depth++) {
    final candidate = File(
      '${directory.path}${Platform.pathSeparator}planner-backup.zip',
    );
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}

/// 以**只读**方式打开库做核对，返回一个原始 `sqlite3` 连接。
///
/// **为什么不复用 drift 的 `QueryExecutor` 做核对**：drift 一打开就会拿
/// `schemaVersion`（本应用是 7）去比对库里的 `user_version`，不等就执行迁移——
/// 于是"只读核对"的连接会去写 `PRAGMA user_version`，在只读模式下抛
/// `attempt to write a readonly database`（实测）。核对代码只需要几条裸 SQL，
/// 用 `sqlite3` 直接读正是它该有的样子：**它不该、也不能触发迁移**。
Database _openReadOnly(String path) =>
    sqlite3.open(path, mode: OpenMode.readOnly);

int _scalarInt(Database database, String sql) {
  final result = database.select(sql);
  if (result.isEmpty) return 0;
  final value = result.first.values.first;
  return value is int ? value : int.tryParse('$value') ?? 0;
}

List<String> _tableNames(Database database) => [
  for (final row in database.select(
    "SELECT name FROM sqlite_master WHERE type='table' "
    "AND name NOT LIKE 'sqlite_%' ORDER BY name",
  ))
    row['name']! as String,
];

/// 每张表的行数。迁移"成功"的最低标准是**一行都没少**。
Map<String, int> _rowCounts(Database database) => {
  for (final table in _tableNames(database))
    table: _scalarInt(database, 'SELECT count(*) FROM "$table"'),
};

List<String> _foreignKeyViolations(Database database) => [
  for (final row in database.select('PRAGMA foreign_key_check'))
    row.values.join('/'),
];

void main() {
  // AppDatabase.openDefault 走 driftDatabase，而后者要经 path_provider 拿临时目录——
  // 那是个 MethodChannel，没有绑定就会抛 "Binding has not yet been initialized"。
  TestWidgetsFlutterBinding.ensureInitialized();

  final backup = _findRealBackup();

  // 用例用过的临时目录，统一在**所有用例跑完之后**清。
  //
  // **为什么不放在 `setUp` 的 `addTearDown` 里**：那个回调只保证晚于用例主体，不保证晚于
  // 用例自己注册的 `addTearDown(executor.close)`——实测删除会撞上"另一个程序正在使用此文件"
  // （SQLite 还持着句柄）。`tearDownAll` 在所有 teardown 之后运行，因此顺序是确定的。
  // 清理失败也不该让一条**已经通过**的验证变成红：临时目录留在系统 temp 里是可接受的代价，
  // 而"因为删不掉目录所以判迁移失败"会掩盖真正要看的结论。
  final scratchDirectories = <Directory>[];
  tearDownAll(() async {
    for (final directory in scratchDirectories) {
      try {
        if (directory.existsSync()) await directory.delete(recursive: true);
      } on Object {
        // 故意吞掉：见上面那段说明。
      }
    }
  });

  group('路线图 §12：真实 v6 数据升级到 v7', () {
    late Directory scratch;

    setUp(() async {
      // 每一条用例拿到**自己的一份副本**：迁移会写文件，共用一份会让用例互相污染。
      scratch = await Directory.systemTemp.createTemp('real-migration-');
      scratchDirectories.add(scratch);
    });

    test('备份里的库确实是 schema v6，且带着真实数据', () async {
      if (backup == null) {
        markTestSkipped('找不到 planner-backup.zip（它不是版本库内容）；这条真实数据用例只在有备份的机器上跑');
        return;
      }
      final source = await _extractBackupDatabase(backup, scratch);

      final executor = _openReadOnly(source.path);
      addTearDown(executor.dispose);
      expect(
        _scalarInt(executor, 'PRAGMA user_version'),
        6,
        reason: '前置条件：真实备份必须是 v6，否则这条用例证明不了 v6 → v7',
      );
      // 防空跑：一个空的 v6 库也能"迁移成功"，却什么也没证明。
      expect(
        (_rowCounts(executor))['tasks'],
        greaterThan(0),
        reason: '真实库里必须有任务，否则"记录逐值不变"是无意义的',
      );
      expect((_rowCounts(executor))['calendar_events'], greaterThan(0));
    });

    test('升级前快照按原 schema 版本与 UTC 时间命名，且是**可读的副本**', () async {
      if (backup == null) {
        markTestSkipped('找不到 planner-backup.zip');
        return;
      }
      final source = await _extractBackupDatabase(backup, scratch);

      final snapshot = await createPreMigrationSnapshotIfNeeded(
        source.path,
        plannerSchemaVersion,
        // **显式指定快照目录**：不指定时它落到应用文档目录，测试就会往真实数据目录里堆快照。
        snapshotDirectory: () async => scratch,
      );
      expect(snapshot, isNotNull, reason: '磁盘上是 v6，因此必须生成快照');
      final file = File(snapshot!);
      expect(file.existsSync(), isTrue);

      // 文件名要能自证：原版本号与 UTC 时间都在里面（否则出事后分不清是哪一次升级的快照）。
      final name = file.uri.pathSegments.last;
      expect(name, contains('v6'), reason: '文件名要含原 schema 版本：$name');
      expect(
        // `backup_assembly.dart` 的写法是 `toIso8601String()` 去掉 `:` 与 `-`，因此形如
        // `20261008T112030.123456Z`——**`T` 前没有连字符**，而且带微秒与小数点。
        // 第一版写成 `\d{8}T\d{6}Z`，被微秒挡住而误报失败。
        RegExp(r'\d{8}T\d{6}(\.\d+)?Z').hasMatch(name),
        isTrue,
        reason: '文件名要含 UTC 时间戳：$name',
      );

      // 快照必须是**能打开的** SQLite，且与源库逐表行数一致——"备份了但打不开"等于没备份。
      final snapshotExecutor = _openReadOnly(file.path);
      addTearDown(snapshotExecutor.dispose);
      expect(_scalarInt(snapshotExecutor, 'PRAGMA user_version'), 6);
      final sourceExecutor = _openReadOnly(source.path);
      addTearDown(sourceExecutor.dispose);
      expect(
        _rowCounts(snapshotExecutor),
        _rowCounts(sourceExecutor),
        reason: '快照与源库的每张表行数必须一致',
      );
    });

    test('真实 v6 库打开后升到 v7：一行不少、外键干净、新表可用', () async {
      if (backup == null) {
        markTestSkipped('找不到 planner-backup.zip');
        return;
      }
      final source = await _extractBackupDatabase(backup, scratch);

      // 迁移前记下基线。
      final before = _openReadOnly(source.path);
      final beforeCounts = _rowCounts(before);
      final beforeTables = _tableNames(before);
      final beforeViolations = _foreignKeyViolations(before);
      before.dispose();
      expect(beforeViolations, isEmpty, reason: '前置条件：真实库升级前外键就是干净的');

      // **打开就会迁移**：`AppDatabase` 的 schemaVersion 是 7，drift 见到 6 就走 onUpgrade。
      final database = AppDatabase.openDefault(
        databasePath: source.path,
        // 显式给出临时目录：默认实现会去问 path_provider（另一个 MethodChannel），
        // 而这件事与本次验证无关——验证只需要它别去写真实数据目录。
        tempDirectoryPath: () async => scratch.path,
      );
      addTearDown(database.close);
      // 真的连上了才算迁移发生（drift 是懒打开的）。
      final taskCount = await database
          .customSelect('SELECT count(*) AS c FROM tasks')
          .getSingle();
      expect(taskCount.read<int>('c'), beforeCounts['tasks']);

      final after = _openReadOnly(source.path);
      addTearDown(after.dispose);

      expect(
        _scalarInt(after, 'PRAGMA user_version'),
        7,
        reason: '迁移后磁盘上的 user_version 必须是 7',
      );

      // ① **一张表都没少**，且每张旧表的行数逐个相等。用 map 相等而不是只比总数：
      //    总数相同但分布变了（比如任务被搬去了新表）是更隐蔽的破坏。
      final afterCounts = _rowCounts(after);
      for (final table in beforeTables) {
        expect(
          afterCounts[table],
          beforeCounts[table],
          reason: '表 $table 的行数在迁移后变了',
        );
      }

      // ② **只多了 v7 的两张表与 drift 的内部表**，没有旧表被删。
      final newTables = (_tableNames(after)).toSet()
        ..removeAll(beforeTables.toSet());
      expect(
        newTables,
        containsAll(<String>[
          'recurring_task_templates',
          'recurring_task_cycles',
        ]),
        reason: 'v7 新增的两张表必须存在；实际新增：$newTables',
      );

      // ③ **外键检查干净**——§12 点名要求这一项。
      expect(_foreignKeyViolations(after), isEmpty, reason: '迁移后不得出现外键违规');

      // ④ 新表在真实库上**可用**（不只是建出来了）：插入一个模板，读回来。
      await database.customStatement(
        "INSERT INTO recurring_task_templates ("
        'id, title, area_id, project_id, target_minutes, priority, energy_level, '
        'split_mode, min_chunk_minutes, max_chunk_minutes, pace, '
        'allowed_weekdays_mask, carry_over_unfinished, starts_on_local_date, '
        'ends_on_local_date, paused_until_local_date, time_zone_id, status, '
        'created_at_utc, updated_at_utc'
        ") VALUES ('real-migration-template', '每周英语 180 分钟', NULL, NULL, "
        "180, 'medium', 'medium', 'splittable', 30, 60, 'even', 127, 0, "
        "'2026-10-05', NULL, NULL, 'Asia/Shanghai', 'active', 0, 0)",
      );
      final readBack = await database
          .customSelect(
            "SELECT target_minutes FROM recurring_task_templates "
            "WHERE id = 'real-migration-template'",
          )
          .getSingle();
      expect(readBack.read<int>('target_minutes'), 180);
    });

    test('已经升到 v7 的库不会重复迁移，也不会再生成快照', () async {
      if (backup == null) {
        markTestSkipped('找不到 planner-backup.zip');
        return;
      }
      final source = await _extractBackupDatabase(backup, scratch);

      // 第一次：v6 → v7。
      final first = AppDatabase.openDefault(
        databasePath: source.path,
        // 显式给出临时目录：默认实现会去问 path_provider（另一个 MethodChannel），
        // 而这件事与本次验证无关——验证只需要它别去写真实数据目录。
        tempDirectoryPath: () async => scratch.path,
      );
      await first.customSelect('SELECT count(*) AS c FROM tasks').getSingle();
      await first.close();

      // 第二次：磁盘上已经是 7，快照函数必须返回 null（§4.3：只在 `< 7` 时建快照）。
      expect(
        await createPreMigrationSnapshotIfNeeded(
          source.path,
          plannerSchemaVersion,
          snapshotDirectory: () async => scratch,
        ),
        isNull,
        reason: 'v7 库不该重复备份——否则每次启动都会堆一份快照',
      );

      // 再打开一次也不该改变任何东西（幂等）。
      final before = _openReadOnly(source.path);
      final countsBefore = _rowCounts(before);
      before.dispose();

      final second = AppDatabase.openDefault(
        databasePath: source.path,
        // 显式给出临时目录：默认实现会去问 path_provider（另一个 MethodChannel），
        // 而这件事与本次验证无关——验证只需要它别去写真实数据目录。
        tempDirectoryPath: () async => scratch.path,
      );
      await second.customSelect('SELECT count(*) AS c FROM tasks').getSingle();
      await second.close();

      final after = _openReadOnly(source.path);
      addTearDown(after.dispose);
      expect(_rowCounts(after), countsBefore, reason: '重复打开不得改动数据');
      expect(_scalarInt(after, 'PRAGMA user_version'), 7);
    });
  });
}

/// 从备份 ZIP 里取出 `planner.sqlite` 到 [scratch]，返回那**一份副本**。
///
/// **取副本而不是直接用备份里的条目**：迁移会写文件；在副本上做，原备份逐字节不变。
/// 这一点值得写在注释里——"验证过程本身改了被验证的东西"是这类测试最容易犯的错。
Future<File> _extractBackupDatabase(File backup, Directory scratch) async {
  final target = File('${scratch.path}${Platform.pathSeparator}planner.sqlite');
  // 用 `dart:io` 的 `Archive`？项目没有 `archive` 的读 ZIP 支持吗？有的——`archive` 是直接依赖。
  // 这里用它的 `ZipDecoder`，与备份服务写 ZIP 用的是同一个包，往返因此是同一套语义。
  final bytes = await backup.readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final entry in archive) {
    if (entry.name == 'planner.sqlite') {
      await target.writeAsBytes(entry.content as List<int>);
      return target;
    }
  }
  throw StateError('备份里没有 planner.sqlite：${backup.path}');
}
