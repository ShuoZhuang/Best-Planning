import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/platform/files/backup_archive_adapter.dart';
import 'package:personal_planner/platform/files/sqlite_database_lifecycle_adapter.dart';

/// 应用的版本号，写进备份清单。
///
/// **必须与 `pubspec.yaml` 的 `version` 手工保持一致**：本项目没有 `package_info` 一类依赖，
/// 运行时读不到真实版本。这是**已知的诚实下限**——清单里记的是这个常量，而不是假装它自动
/// 跟随构建。日后若加入版本读取依赖，只需改这一处。
const appVersion = '1.0.0';

/// 待恢复文件的路径：恢复**不立刻**替换正在使用的数据库，而是写到这里，等下次启动时生效。
String pendingRestorePath(String databasePath) => '$databasePath.restore-pending';

/// 解析数据库文件路径，并在打开数据库**之前**应用待生效的恢复。
///
/// **路径必须按 `drift_flutter` 的同一条规则算出**：包内默认是
/// `getApplicationDocumentsDirectory()` 拼 `<name>.sqlite`（读包源码确认，见 pub 缓存
/// `drift_flutter-0.3.1/lib/src/native.dart:37-50`）。猜目录会让应用打开一个**空库**，
/// 看起来就是"数据全没了"，所以这里与包内默认保持一致，而不是随手选一个目录。
///
/// **为什么恢复要等到启动**：`DatabaseLifecyclePort` 的接口假定替换发生在运行中（因此需要
/// close/reopen 回调），而当前数据库实例被任务、日程、计划、设置、统计、领域、标签、修正记录
/// 等十余处服务持有，"关掉当前库再打开"等于要它们全部换用新实例。在运行中替换文件而连接仍
/// 指向旧文件会留下**半恢复状态**，因此这里改成"启动前替换"：没有运行中的连接，就没有这个
/// 问题，而且用户看到的提示与真实行为一致。
Future<String> preparePlannerDatabase() async {
  final documents = await getApplicationDocumentsDirectory();
  final databasePath =
      '${documents.path}${Platform.pathSeparator}personal_planner.sqlite';
  await applyPendingRestoreFor(databasePath);
  return databasePath;
}

/// 应用待生效的恢复：把 `<库>.restore-pending` 换成当前数据库。
///
/// 公开而不是私有，是为了**能被直接测试**：这段逻辑会**替换用户的数据库文件**，属于本文件里
/// 风险最高的一处，值得用真实文件验证（含"没有待恢复文件时什么都不做"这条）。
Future<void> applyPendingRestoreFor(String databasePath) async {
  final pending = File(pendingRestorePath(databasePath));
  if (!await pending.exists()) return;
  final current = File(databasePath);
  // 替换前先留一份旧库：即便用户拿到的是坏备份，也还能手工找回原文件。
  if (await current.exists()) {
    await current.copy('$databasePath.restore-old');
  }
  await pending.copy(databasePath);
  await pending.delete();
  // 旧的 WAL/SHM 属于被替换掉的那个数据库，留着会让新库读到自己不该有的内容。
  for (final suffix in const ['-wal', '-shm']) {
    final sidecar = File('$databasePath$suffix');
    if (await sidecar.exists()) await sidecar.delete();
  }
}

/// 装配备份服务（W3 最后一条缺失路由：数据备份页）。
Future<BackupService> buildBackupService({
  required AppDatabase database,
  required Clock clock,
  required String databasePath,
}) async {
  return BackupService(
    database: _PendingRestoreLifecycle(
      databasePath: databasePath,
      supportedSchemaVersion: database.schemaVersion,
    ),
    archives: const BackupArchiveAdapter(),
    hashes: const Sha256FileHashAdapter(),
    clock: clock,
    appVersion: appVersion,
    // "全部设置序列化"：设置表本身就是 key → JSON 字符串，因此直接导出整表。逐键枚举会随
    // 新增设置**静默漏键**，而备份恰恰是"以后要能读回来"的东西。
    settingsJson: () async {
      final rows = await database.select(database.settings).get();
      return jsonEncode({for (final row in rows) row.key: row.jsonValue});
    },
  );
}

/// 备份用的数据库生命周期端口：**读取型操作复用既有适配器，替换改为写入待恢复文件**。
///
/// 复用而不是重写：`createConsistentSnapshot` 会先 checkpoint WAL 再复制（技术设计 §11.1），
/// `inspect` 会用 `sqlite3.open` 复核完整性，这些都需要真正打开文件；只有"替换正在使用的文件"
/// 这一件事必须换掉（见 [preparePlannerDatabase] 的说明）。
final class _PendingRestoreLifecycle implements DatabaseLifecyclePort {
  _PendingRestoreLifecycle({
    required String databasePath,
    required this.supportedSchemaVersion,
  }) : _delegate = SqliteDatabaseLifecycleAdapter(
         databasePath: databasePath,
         supportedSchemaVersion: supportedSchemaVersion,
         // 两个回调在这条路径上**不会被调用**（替换已改为"写待恢复文件"），因此留空实现并
         // 在这里写明，而不是假装它们能安全地关掉并重开十余处服务持有的库实例。
         closeDatabase: () async {},
         reopenDatabase: () async {},
       ),
       _databasePath = databasePath;

  final SqliteDatabaseLifecycleAdapter _delegate;
  final String _databasePath;

  @override
  final int supportedSchemaVersion;

  @override
  Future<void> createConsistentSnapshot(String destination) =>
      _delegate.createConsistentSnapshot(destination);

  @override
  Future<DatabaseInspection> inspect(String candidate) =>
      _delegate.inspect(candidate);

  @override
  Future<void> replaceWith(String validatedDatabase) async {
    final pending = File(pendingRestorePath(_databasePath));
    await pending.parent.create(recursive: true);
    await File(validatedDatabase).copy(pending.path);
  }

  @override
  Future<void> eraseAll() => _delegate.eraseAll();
}
