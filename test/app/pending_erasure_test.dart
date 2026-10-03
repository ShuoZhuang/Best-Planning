// 永久清除（FR-DATA-04／spec §18 第 18 项）的**启动期删除**。
//
// 这一项此前**在真实用户路径上没有入口**：`DataErasureService` 与 `BackupPage` 里那一块都已
// 存在、也各有测试，但组合根从不构造它、路由器刻意不传 `erasure`。原因写在当时的注释里
// ——"删库同样需要关库—换实例—重开"。本轮把它改成**延迟到下次启动执行**（与恢复那条路径
// 同一个套路），因此不需要在运行中换库实例。
//
// 本文件用**真实文件**验证删除逻辑，理由与 `backup_pending_restore_test.dart` 相同：它会
// 删除用户的数据库文件，属于风险最高的一处。最重要的一条不变量是**残留的待恢复文件必须一并
// 删掉**——否则用户以为清干净了，数据却会在下次启动"复活"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/backup_assembly.dart';

void main() {
  late Directory workspace;
  late String databasePath;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('planner-erasure-test-');
    databasePath = '${workspace.path}${Platform.pathSeparator}planner.sqlite';
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  Future<void> seedDatabaseFiles() async {
    await File(databasePath).writeAsString('用户数据');
    await File('$databasePath-wal').writeAsString('WAL');
    await File('$databasePath-shm').writeAsString('SHM');
  }

  test('没有待清除标记时什么都不做', () async {
    await seedDatabaseFiles();

    final erased = await applyPendingErasureFor(databasePath);

    expect(erased, isFalse);
    // **空闲时绝不碰用户的库**：这是最危险的一种"顺手清理"。
    expect(await File(databasePath).readAsString(), '用户数据');
    expect(await File('$databasePath-wal').exists(), isTrue);
  });

  test('有待清除标记时删掉数据库、sidecar 与标记本身', () async {
    await seedDatabaseFiles();
    await File(pendingErasurePath(databasePath)).writeAsString('pending');

    final erased = await applyPendingErasureFor(databasePath);

    expect(erased, isTrue);
    expect(await File(databasePath).exists(), isFalse);
    expect(await File('$databasePath-wal').exists(), isFalse);
    expect(await File('$databasePath-shm').exists(), isFalse);
    // 标记用完即删：留着会让**每次启动**都再清一遍（虽然无害，但它是一条状态，不该残留）。
    expect(await File(pendingErasurePath(databasePath)).exists(), isFalse);
  });

  test('一并删掉残留的待恢复文件与回滚副本（否则数据会"复活"）', () async {
    await seedDatabaseFiles();
    await File(pendingErasurePath(databasePath)).writeAsString('pending');
    // 用户先恢复了备份、之后又决定永久清除：这时待恢复文件还在。
    await File(pendingRestorePath(databasePath)).writeAsString('备份里的数据');
    await File('$databasePath.restore-old').writeAsString('更早的数据');

    await applyPendingErasureFor(databasePath);

    expect(
      await File(pendingRestorePath(databasePath)).exists(),
      isFalse,
      reason: '残留的待恢复文件会在下次启动把数据搬回来——用户以为清干净了，数据却复活了',
    );
    expect(await File('$databasePath.restore-old').exists(), isFalse);
  });

  test('清除优先于恢复：两者同时存在时数据不会被恢复', () async {
    // `preparePlannerDatabase()` 的顺序**先清除、后恢复**。若顺序反了，被恢复的数据会活过
    // 这一整个会话，而用户上一次的动作明明是"永久清除"。
    await seedDatabaseFiles();
    await File(pendingErasurePath(databasePath)).writeAsString('pending');
    await File(pendingRestorePath(databasePath)).writeAsString('备份里的数据');

    final erased = await applyPendingErasureFor(databasePath);
    // 清除跑过之后不该再应用恢复（清除已经把它删掉了，这里显式再调一次也必须是空操作）。
    if (!erased) await applyPendingRestoreFor(databasePath);

    expect(erased, isTrue);
    expect(await File(databasePath).exists(), isFalse);
    expect(await File(pendingRestorePath(databasePath)).exists(), isFalse);
  });
}
