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
/// **它是构建期抄的一行，不是运行时的真实版本**。项目的版本规则是"`pubspec.yaml` 是唯一数值
/// 来源"，而 `pubspec.yaml` 只在构建时可见，因此这个常量必须手工跟随它——这条"手工一致"由
/// `test/app/version_consistency_test.dart` 守着，漂移了测试会红。
///
/// **1.7 起它不再是"用户装的是哪个构建"的答案**（路线图 §3.6 / Task 10）：更新检查改用
/// `AppVersionProvider`（`package_info_plus`，读安装包元数据）。这个常量保留下来只做两件事：
///   ① 作为 [buildBackupService] **没有**注入版本提供者时的回落值（测试与平台通道不可用的
///      降级路径）；
///   ② 作为设置页底部展示的"软件版本"，那里显示的就是这份构建里的号。
///
/// **为什么不同时把设置页也改成读安装包元数据**：两者显示的号对同一份构建必然相同（一致性由
/// 上面那条测试守着），而设置页是**同步渲染**的——为一个显示值引入一个异步来源，会让首帧少一行
/// 或多一次重建。更新判定是另一回事：错了会导致"永远说已是最新"，因此那一处必须读真实元数据。
///
/// 版本规则与历史回填见 `docs/release/version-policy.md`。
const appVersion = '1.7.0+38';

/// 待恢复文件的路径：恢复**不立刻**替换正在使用的数据库，而是写到这里，等下次启动时生效。
String pendingRestorePath(String databasePath) =>
    '$databasePath.restore-pending';

/// 待清除标记的路径：永久清除**不立刻**删库，而是写下这个标记，等下次启动时执行。
///
/// 与 [pendingRestorePath] 完全对称——两件事都必须发生在**没有运行中的连接**的时候。
String pendingErasurePath(String databasePath) => '$databasePath.erase-pending';

/// 升级前快照失败。
///
/// **它必须让启动停下来**（路线图 §4.3 最后一条："备份失败则中止升级并向用户显示可操作
/// 错误，绝不带病继续迁移"）。做成一个独立类型而不是复用一个通用异常，是为了让组合根能
/// 把"备份写不进去"与"数据库本身打不开"分开——两者的处置完全不同，而用户看到的
/// 提示必须能指向真正要修的那件事（磁盘空间／权限／路径）。
final class PlannerPreMigrationBackupException implements Exception {
  const PlannerPreMigrationBackupException({
    required this.databasePath,
    required this.snapshotPath,
    required this.cause,
  });

  final String databasePath;
  final String snapshotPath;
  final Object cause;

  /// 面向用户的可操作提示。**不含堆栈、不含内部实现**：用户要做的是腾出磁盘空间、
  /// 或者把文件移出受保护的目录，而不是读一段栈。
  String get userMessage =>
      '数据库需要升级到新版本，但升级前的备份无法写入：\n'
      '  $snapshotPath\n'
      '请检查该位置的剩余空间与写入权限后重新启动；'
      '在备份成功之前，程序不会改动原数据库。';

  @override
  String toString() =>
      'PlannerPreMigrationBackupException($databasePath → $snapshotPath): $cause';
}

/// 在**打开 Drift 连接之前**为一次 schema 升级创建快照（路线图 §4.3）。
///
/// 返回快照文件路径；不需要或无法创建时返回 `null`。
///
/// 三条规则都是刻意的：
/// - **只在磁盘上的 `PRAGMA user_version < [targetSchemaVersion]` 时创建**。
///   `user_version = 0` 表示这是一个**还没被任何连接创建过**的空文件／不存在的文件，
///   它将要走的是 `onCreate` 而不是迁移，没有旧数据可保，因此不备份——否则每次全新安装
///   都会在用户的文档目录里留下一个空快照。
/// - **读库用只读模式**：这一步只回答问题，不该让任何东西被写入。用 `sqlite3.open` 的
///   `OpenMode.readOnly` 就是这条保证本身。
/// - **失败必须抛**，不能返回 `null` 假装"不需要备份"。调用方（组合根）在得到异常后
///   中止启动：迁移前的库是用户唯一的一份数据，"先迁了再说"的代价是不可逆的。
///
/// **文件名包含原 schema 版本与 UTC 时间**：前者回答"这份快照能不能直接换回去"（换回去
/// 就是旧版本的库），后者让同一台机器上多次失败的升级各自留下证据，而不是互相覆盖。
Future<String?> createPreMigrationSnapshotIfNeeded(
  String databasePath,
  int targetSchemaVersion, {
  Future<Directory> Function()? snapshotDirectory,
}) async {
  final databaseFile = File(databasePath);
  if (!await databaseFile.exists() || await databaseFile.length() == 0) {
    return null;
  }

  final currentVersion = _readSchemaVersion(databasePath);
  if (currentVersion == null || currentVersion <= 0) return null;
  if (currentVersion >= targetSchemaVersion) return null;

  final directory = await _resolveSnapshotDirectory(
    databasePath,
    snapshotDirectory,
  );
  final stamp = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '')
      .replaceAll('-', '');
  final snapshotPath =
      '${directory.path}${Platform.pathSeparator}'
      '${_snapshotBaseName(databasePath)}'
      '.v$currentVersion.pre-upgrade-$stamp.bak';
  try {
    await directory.create(recursive: true);
  } on Object catch (error) {
    // **建目录失败也走同一个异常类型**：它同样会写出一份"升级前快照不存在"的状态，
    // 调用方要做的处置完全相同（停下来，让用户修磁盘／权限）。让两种失败长得不一样，
    // 只会让组合根多一条没人测过的分支。
    throw PlannerPreMigrationBackupException(
      databasePath: databasePath,
      snapshotPath: snapshotPath,
      cause: error,
    );
  }

  Database? source;
  Database? target;
  try {
    source = sqlite3.open(databasePath, mode: OpenMode.readOnly);
    // **SQLite backup API 而不是复制文件**：原库可能带着 `-wal`，此时文件本身缺少尚未
    // checkpoint 的内容；`backup` 拿到的是**逻辑一致**的副本，与
    // `SqliteDatabaseLifecycleAdapter.createConsistentSnapshot` 用的是同一条路径。
    target = sqlite3.open(snapshotPath);
    await source.backup(target, nPage: -1).drain<void>();
  } on Object catch (error) {
    // 半成品快照必须删掉：留下一个能被"恢复"到的残缺文件，比没有快照更危险。
    try {
      if (await File(snapshotPath).exists()) {
        await File(snapshotPath).delete();
      }
    } on Object {
      // 清理失败不改变"备份失败"这个结论。
    }
    throw PlannerPreMigrationBackupException(
      databasePath: databasePath,
      snapshotPath: snapshotPath,
      cause: error,
    );
  } finally {
    target?.close();
    source?.close();
  }
  return snapshotPath;
}

int? _readSchemaVersion(String databasePath) {
  Database? database;
  try {
    database = sqlite3.open(databasePath, mode: OpenMode.readOnly);
    return database.select('PRAGMA user_version').single.values.first as int?;
  } on Object {
    // 打不开（被占用、不是 SQLite 文件）时**返回 null 而不是抛**：接下来的
    // `openDefault()` 会给出准确得多的错误（它知道自己在做什么），在这里抢先报错只会
    // 掩盖真正的原因。
    return null;
  } finally {
    database?.close();
  }
}

String _snapshotBaseName(String databasePath) {
  final name = databasePath.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/// 快照放哪。
///
/// **默认开在数据库旁边的 `pre-upgrade-backups` 子目录**，而不是系统临时目录：
/// 用户在"升级把数据弄坏了"之后要找的是**这份快照**，而临时目录会被系统清理，也不会
/// 出现在他熟悉的那个文件夹里。数据库所在目录已经由 `preparePlannerDatabase` 的真实
/// 写入探针证明可写，因此这是唯一一个"确定写得进去"的位置。
Future<Directory> _resolveSnapshotDirectory(
  String databasePath,
  Future<Directory> Function()? override,
) async {
  if (override != null) return override();
  return Directory(
    '${File(databasePath).parent.path}'
    '${Platform.pathSeparator}pre-upgrade-backups',
  );
}

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
///
/// [versions] 是**运行时版本的读取方式**（路线图 §3.6 / Task 10）。它返回一个字符串而不是
/// `AppVersion`，是刻意的：这一层只负责往清单里写一个号，不需要认识版本语义；调用方（组合根）
/// 从 `AppVersionProvider` 读出真实安装版本，`toString()` 之后就交过来。
///
/// **为空时回落到 [appVersion]**，因此既有调用方与全部既有备份用例都不必改；而注入了就优先信
/// 注入的那个——**安装包元数据比源码里抄的一行更接近"用户装的是哪个构建"**。
Future<BackupService> buildBackupService({
  required AppDatabase database,
  required Clock clock,
  required String databasePath,
  Future<String> Function()? versions,
}) async {
  return BackupService(
    database: _DeferredLifecycle(
      databasePath: databasePath,
      supportedSchemaVersion: database.schemaVersion,
    ),
    archives: const BackupArchiveAdapter(),
    hashes: const Sha256FileHashAdapter(),
    clock: clock,
    appVersion: await _resolveAppVersion(versions),
    // "全部设置序列化"：设置表本身就是 key → JSON 字符串，因此直接导出整表。逐键枚举会随
    // 新增设置**静默漏键**，而备份恰恰是"以后要能读回来"的东西。
    settingsJson: () async {
      final rows = await database.select(database.settings).get();
      return jsonEncode({for (final row in rows) row.key: row.jsonValue});
    },
  );
}

/// 解析要写进清单的版本号：优先注入的来源，读不出来时回落常量。
///
/// **读失败必须回落而不是抛**：备份是用户在"怕丢数据"时做的事，为一个显示用的版本号让整次
/// 备份失败是本末倒置。回落值虽然来自源码，但它至少是一个真实的发布号（由
/// `version_consistency_test` 守着与 `pubspec.yaml` 一致）。
///
/// **空串也回落**：一个空版本号比一个可能过期的版本号更糟——它会静默丢掉"这份备份来自哪个
/// 版本"这条信息，而恢复时正是靠它判断兼容性。
Future<String> _resolveAppVersion(Future<String> Function()? versions) async {
  if (versions == null) return appVersion;
  try {
    final value = await versions();
    return value.isEmpty ? appVersion : value;
  } on Object {
    return appVersion;
  }
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
