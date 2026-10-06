import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/application/data_erasure_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';
import 'package:personal_planner/platform/files/backup_archive_adapter.dart';
import 'package:personal_planner/platform/files/sqlite_database_lifecycle_adapter.dart';
import 'package:sqlite3/sqlite3.dart';

/// 应用的版本号，写进备份清单。
///
/// **必须与 `pubspec.yaml` 的 `version` 手工保持一致**：本项目没有 `package_info` 一类依赖，
/// 运行时读不到真实版本。这是**已知的诚实下限**——清单里记的是这个常量，而不是假装它自动
/// 跟随构建。日后若加入版本读取依赖，只需改这一处。
///
/// 这条"手工一致"由 `test/app/version_consistency_test.dart` 守着——漂移了测试会红。
/// 版本规则与历史回填见 `docs/release/version-policy.md`。
const appVersion = '1.4.0+19';

/// 待恢复文件的路径：恢复**不立刻**替换正在使用的数据库，而是写到这里，等下次启动时生效。
String pendingRestorePath(String databasePath) =>
    '$databasePath.restore-pending';

/// 待清除标记的路径：永久清除**不立刻**删库，而是写下这个标记，等下次启动时执行。
///
/// 与 [pendingRestorePath] 完全对称——两件事都必须发生在**没有运行中的连接**的时候。
String pendingErasurePath(String databasePath) => '$databasePath.erase-pending';

/// 解析数据库文件路径，并在打开数据库**之前**应用待生效的清除与恢复。
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
///
/// **为什么清除也要等到启动**：同一个理由，而且更严重——`eraseAll` 在 `DataErasureService`
/// 里是**最后一步**，前面已经清掉了密码锁凭据与全部通知。若此时删库在 Windows 上因共享冲突
/// 抛错，用户会留下**半清除状态**（锁没了、提醒没了、数据还在），而屏幕上只有一条错误。
typedef PlannerDirectoryProbe = Future<bool> Function(Directory directory);

/// 解析一个当前进程真正可写的数据库目录，并在首次切换路径时安全迁移旧库。
///
/// Windows 的“文档”目录可能能被资源管理器访问，却被当前应用身份以只读方式打开。仅凭路径
/// 存在不能证明 SQLite 可写，所以必须先做真实写入探针；若默认目录不可写，则把旧库通过
/// SQLite backup API 复制到便携程序的用户数据目录。原库不删除，作为迁移保险。
Future<String> preparePlannerDatabase({
  Future<Directory> Function()? documentsDirectory,
  List<Directory>? fallbackDirectories,
  PlannerDirectoryProbe? writableProbe,
}) async {
  final documents =
      await (documentsDirectory ?? getApplicationDocumentsDirectory)();
  final fallbacks =
      fallbackDirectories ??
      [
        Directory(
          '${File(Platform.resolvedExecutable).parent.path}'
          '${Platform.pathSeparator}user-data',
        ),
        if (Platform.environment['LOCALAPPDATA'] case final localAppData?)
          Directory('$localAppData${Platform.pathSeparator}PersonalPlanner'),
      ];
  final probe = writableProbe ?? _canWritePlannerDirectory;
  final candidates = [documents, ...fallbacks];
  Directory? selected;
  for (final candidate in candidates) {
    if (await probe(candidate)) {
      selected = candidate;
      break;
    }
  }
  if (selected == null) {
    throw FileSystemException(
      '找不到可写的应用数据目录',
      candidates.map((directory) => directory.path).join('; '),
    );
  }

  final legacyPath =
      '${documents.path}${Platform.pathSeparator}personal_planner.sqlite';
  final databasePath =
      '${selected.path}${Platform.pathSeparator}personal_planner.sqlite';
  if (!_samePath(databasePath, legacyPath)) {
    await _migrateLegacyPlannerDatabase(
      legacyPath: legacyPath,
      databasePath: databasePath,
    );
  }
  // **顺序是刻意的：先处理清除**。若先应用恢复，被恢复的数据会活过这一整个会话，而用户
  // 上一次的动作明明是"永久清除"。
  final erased = await applyPendingErasureFor(databasePath);
  if (!erased) await applyPendingRestoreFor(databasePath);
  return databasePath;
}

Future<bool> _canWritePlannerDirectory(Directory directory) async {
  final probe = File(
    '${directory.path}${Platform.pathSeparator}'
    '.planner-write-probe-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await directory.create(recursive: true);
    await probe.writeAsString('writable', flush: true);
    await probe.delete();
    return true;
  } on FileSystemException {
    if (await probe.exists()) {
      try {
        await probe.delete();
      } on FileSystemException {
        // 探针清理失败不改变“该目录不可可靠写入”的结论。
      }
    }
    return false;
  }
}

bool _samePath(String left, String right) {
  final leftAbsolute = File(left).absolute.path;
  final rightAbsolute = File(right).absolute.path;
  if (Platform.isWindows) {
    return leftAbsolute.toLowerCase() == rightAbsolute.toLowerCase();
  }
  return leftAbsolute == rightAbsolute;
}

String _legacyMigrationMarker(String databasePath) =>
    '$databasePath.legacy-migration-complete';

Future<void> _migrateLegacyPlannerDatabase({
  required String legacyPath,
  required String databasePath,
}) async {
  final destination = File(databasePath);
  final marker = File(_legacyMigrationMarker(databasePath));
  await destination.parent.create(recursive: true);
  if (await marker.exists()) return;

  if (!await destination.exists() &&
      !await File(pendingErasurePath(legacyPath)).exists()) {
    final pendingRestore = File(pendingRestorePath(legacyPath));
    final source = await pendingRestore.exists()
        ? pendingRestore
        : File(legacyPath);
    if (await source.exists()) {
      await _backupSqliteDatabase(source.path, databasePath);
    }
  }

  // 标记独立于数据库文件。这样用户在新目录执行“永久清除”后，旧目录里保留的迁移保险不会
  // 在下一次启动时又被导入，造成数据“复活”。
  await marker.writeAsString('complete', flush: true);
}

Future<void> _backupSqliteDatabase(String sourcePath, String targetPath) async {
  Database? source;
  Database? target;
  try {
    source = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
    target = sqlite3.open(targetPath);
    await source.backup(target, nPage: -1).drain<void>();
  } finally {
    target?.close();
    source?.close();
  }
}

/// 应用待生效的**永久清除**：删掉数据库、它的 sidecar，以及任何残留的待恢复/回滚文件。
///
/// **必须一并删掉 `.restore-pending` 与 `.restore-old`**：否则一个残留的待恢复文件会在下次
/// 启动把数据搬回来——用户以为已经清干净了，数据却"复活"了。这是本函数最重要的一条不变量。
///
/// 返回是否真的执行了清除（没有标记时为 `false`）。公开而不是私有，是为了能被直接测试：
/// 它会**删除用户的数据库文件**，属于本文件里风险最高的一处。
Future<bool> applyPendingErasureFor(String databasePath) async {
  final marker = File(pendingErasurePath(databasePath));
  if (!await marker.exists()) return false;
  for (final path in [
    databasePath,
    '$databasePath-wal',
    '$databasePath-shm',
    pendingRestorePath(databasePath),
    '$databasePath.restore-old',
  ]) {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
  await marker.delete();
  return true;
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
    database: _DeferredLifecycle(
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

/// 备份与**永久清除**用的数据库生命周期端口：**读取型操作复用既有适配器，破坏性操作改为
/// 写待处理文件**。
///
/// 复用而不是重写：`createConsistentSnapshot` 会先 checkpoint WAL 再复制（技术设计 §11.1），
/// `inspect` 会用 `sqlite3.open` 复核完整性，这些都需要真正打开文件；只有"替换/删除正在使用
/// 的文件"这两件事必须换掉（见 [preparePlannerDatabase] 的说明）。
final class _DeferredLifecycle implements DatabaseLifecyclePort {
  _DeferredLifecycle({
    required String databasePath,
    required this.supportedSchemaVersion,
  }) : _delegate = SqliteDatabaseLifecycleAdapter(
         databasePath: databasePath,
         supportedSchemaVersion: supportedSchemaVersion,
         // 两个回调在这条路径上**不会被调用**（替换与删除都已改为"写待处理文件"），因此留空
         // 实现并在这里写明，而不是假装它们能安全地关掉并重开十余处服务持有的库实例。
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

  /// 写下"待清除"标记，而不是当场删库。
  ///
  /// 直接委托 `SqliteDatabaseLifecycleAdapter.eraseAll()` 会**立刻删除**数据库文件与
  /// `-wal`/`-shm`，而运行中的 drift 连接仍指向那个文件：要么界面还显示着数据、重启后才真的
  /// 空，要么在 Windows 上因共享冲突直接抛错——而它是 `DataErasureService` 的**最后一步**，
  /// 前面已经清掉凭据与通知，失败就会留下半清除状态。因此与 [replaceWith] 一样写成待处理标记，
  /// 由下次启动的 [applyPendingErasureFor] 在没有连接的情况下执行。
  @override
  Future<void> eraseAll() async {
    final marker = File(pendingErasurePath(_databasePath));
    await marker.parent.create(recursive: true);
    await marker.writeAsString('pending');
  }
}

/// 装配**永久清除**服务（FR-DATA-04／spec §18 第 18 项）。
///
/// **刻意不传 `backupIndex`**：`BackupIndexPort` 目前在生产里**没有任何写入方**
/// （`FileBackupIndexAdapter` 只被测试构造），因此生产里没有"备份索引"这个东西可清。传一个
/// 指向没人写过的文件的适配器，等于用一个假依赖把接口填满——那正是"看起来接好了、其实没有"。
/// 该参数因此改为可选，服务在为空时跳过它。
DataErasureService buildDataErasureService({
  required AppDatabase database,
  required String databasePath,
  required NotificationPort notifications,
  required AppLockCredentialStore credentials,
}) => DataErasureService(
  database: _DeferredLifecycle(
    databasePath: databasePath,
    supportedSchemaVersion: database.schemaVersion,
  ),
  notifications: notifications,
  credentials: credentials,
);
