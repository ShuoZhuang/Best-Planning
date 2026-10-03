// 备份恢复的**启动期替换**：把 `<库>.restore-pending` 换成当前数据库。
//
// 这是本次改动里唯一会**替换用户数据库文件**的逻辑，因此用真实文件验证，而不是只测页面渲染。
// 三条用例覆盖：确实替换（并留下回滚副本、清掉旧 sidecar）、没有待恢复文件时**什么都不做**、
// 以及空闲时**不碰** `-wal`（误删当前库的 WAL 会造成数据丢失，这是最危险的一种"顺手清理"）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/backup_assembly.dart';

void main() {
  late Directory workspace;
  late String databasePath;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('planner-restore-test-');
    databasePath = '${workspace.path}${Platform.pathSeparator}planner.sqlite';
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('有待恢复文件时替换数据库，并留下回滚副本、清掉旧 sidecar', () async {
    await File(databasePath).writeAsString('当前数据');
    await File('$databasePath-wal').writeAsString('旧 WAL');
    await File('$databasePath-shm').writeAsString('旧 SHM');
    await File(pendingRestorePath(databasePath)).writeAsString('备份数据');

    await applyPendingRestoreFor(databasePath);

    expect(await File(databasePath).readAsString(), '备份数据');
    // 待恢复文件用完即删：留着会让**每次启动**都再替换一遍。
    expect(await File(pendingRestorePath(databasePath)).exists(), isFalse);
    // 替换前先留一份旧库，用户拿到坏备份时还能手工找回原文件。
    expect(await File('$databasePath.restore-old').readAsString(), '当前数据');
    // 旧 sidecar 属于被替换掉的那个库：留着会让新库读到自己不该有的内容。
    expect(await File('$databasePath-wal').exists(), isFalse);
    expect(await File('$databasePath-shm').exists(), isFalse);
  });

  test('没有待恢复文件时什么都不做', () async {
    await File(databasePath).writeAsString('当前数据');
    await File('$databasePath-wal').writeAsString('当前 WAL');

    await applyPendingRestoreFor(databasePath);

    expect(await File(databasePath).readAsString(), '当前数据');
    // 空闲时**不得**清理 sidecar：那是当前库正在用的 WAL，删掉就是数据丢失。
    expect(await File('$databasePath-wal').readAsString(), '当前 WAL');
    expect(await File('$databasePath.restore-old').exists(), isFalse);
  });

  test('数据库文件不存在时也能应用恢复（首次安装后直接恢复）', () async {
    await File(pendingRestorePath(databasePath)).writeAsString('备份数据');

    await applyPendingRestoreFor(databasePath);

    expect(await File(databasePath).readAsString(), '备份数据');
    // 没有旧库就没有回滚副本，也不该凭空造一个空文件。
    expect(await File('$databasePath.restore-old').exists(), isFalse);
  });
}
