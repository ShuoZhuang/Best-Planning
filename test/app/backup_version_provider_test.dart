// 备份清单里的版本号来源（路线图 §3.6 最后一条 / §11 Task 10）。
//
// `backup_assembly.dart` 的 `appVersion` 是一个**手写常量**，由
// `test/app/version_consistency_test.dart` 守着与 `pubspec.yaml` 一致。它作为"构建时的代码
// 抄了一行"是诚实的，但运行中的程序有一个**更准的来源**：安装包自己的元数据。
//
// 因此这个装配点改成走注入的版本提供者：
//   · **给了**提供者 —— 清单记的是安装包报出来的版本（真实用户装的是哪个构建）；
//   · **没给**（测试、或平台通道不可用的降级路径）—— 回落到既有常量，`BackupService` 的
//     构造签名与全部既有用例都不受影响。
//
// 这条用例守的是"注入真的接上了"，而不是"默认值还能用"——后者本来就有测试。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/backup_assembly.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/application/plan_undo_service.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/update/update_safety.dart';

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 8, 3);
}

/// 从备份压缩包里读回 `manifest.json`。
Map<String, Object?> _manifestOf(String archivePath) {
  final archive = ZipDecoder().decodeBytes(File(archivePath).readAsBytesSync());
  for (final entry in archive) {
    if (entry.name == 'manifest.json') {
      return jsonDecode(utf8.decode(entry.readBytes()!))
          as Map<String, Object?>;
    }
  }
  throw StateError('备份里没有 manifest.json：${archive.files.map((f) => f.name)}');
}

void main() {
  late Directory workspace;
  late String databasePath;
  late AppDatabase database;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('planner-version-test-');
    databasePath =
        '${workspace.path}${Platform.pathSeparator}personal_planner.sqlite';
    // **必须是一个真实文件库**：`createConsistentSnapshot` 会 checkpoint WAL 再复制文件，
    // 内存库没有文件可复制（那正是这条路径上最容易"看起来通过、其实没跑"的地方）。
    database = AppDatabase.forTesting(NativeDatabase(File(databasePath)));
    // 建表：第一次读设置就会把 schema 落到文件上。
    await database.select(database.settings).get();
  });

  tearDown(() async {
    await database.close();
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  Future<Map<String, Object?>> manifestWith({
    required Future<String> Function()? versions,
  }) async {
    final service = await buildBackupService(
      database: database,
      clock: const _FixedClock(),
      databasePath: databasePath,
      versions: versions,
    );
    final destination = '${workspace.path}${Platform.pathSeparator}out.zip';
    await service.create(destination);
    return _manifestOf(destination);
  }

  test('注入了版本提供者时，清单记的是它报出来的版本', () async {
    final manifest = await manifestWith(versions: () async => '1.9.9+99');
    expect(
      manifest['appVersion'],
      '1.9.9+99',
      reason: '安装包报出来的版本才是"用户装的是哪个构建"，常量只是构建期抄的一行',
    );
  });

  test('没有注入时回落到既有常量：既有备份用例因此不受影响', () async {
    final manifest = await manifestWith(versions: null);
    expect(manifest['appVersion'], appVersion);
  });

  test('版本提供者读不出来时回落到常量，而不是写进一个空版本号', () async {
    // 真实路径：`package_info_plus` 在平台通道不可用时会失败。清单里写一个空串会让
    // "备份来自哪个版本"这条信息彻底丢失，而回落到常量至少还是一个真实的发布号。
    final manifest = await manifestWith(
      versions: () async => throw StateError('读不到'),
    );
    expect(manifest['appVersion'], appVersion);
  });

  test('组合根把同一个安全协调器交给备份服务与撤销服务（UPD-029）', () async {
    final safety = InMemoryUpdateSafetyCoordinator();
    addTearDown(safety.dispose);
    final backups = await buildBackupService(
      database: database,
      clock: const _FixedClock(),
      databasePath: databasePath,
      updateSafety: safety,
    );
    expect(identical(backups.updateSafety, safety), isTrue);

    final undo = PlanUndoService(
      repository: _NoPlanHistory(),
      updateSafety: safety,
    );
    expect(identical(undo.updateSafety, safety), isTrue);
  });
}

final class _NoPlanHistory implements PlanHistoryRepository {
  @override
  Future<ConfirmedPlan?> current() async => null;

  @override
  Future<ConfirmedPlan?> previous() async => null;

  @override
  Future<ConfirmedPlan> restoreAsNewVersion({
    required ConfirmedPlan source,
    required ConfirmedPlan replaced,
  }) => throw UnimplementedError();
}
