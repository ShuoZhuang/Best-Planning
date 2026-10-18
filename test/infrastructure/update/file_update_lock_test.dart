// 跨进程更新锁（UPD-021）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/infrastructure/update/file_update_lock.dart';

import '../../support/update_doubles.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_lock_test_');
    file = File('${directory.path}${Platform.pathSeparator}update.lock');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<FileUpdateLock> buildLock({FakeProcessProbe? probe}) async =>
      FileUpdateLock(
        file: file,
        processProbe: probe ?? FakeProcessProbe(),
      );

  Future<bool> acquire(FileUpdateLock lock, {String operation = 'download'}) async {
    final process = await lock.processProbe.current();
    return lock.acquire(
      transactionId: 'tx-1',
      pid: process.pid,
      processStartedAtUtc: process.startedAtUtc,
      token: 'a' * 64,
      operation: operation,
      targetVersion: '1.9.0.0',
    );
  }

  test('第一次获取成功，第二次被拒绝，释放后可再次获取', () async {
    final first = await buildLock();
    final second = await buildLock();

    expect(await acquire(first), isTrue, reason: '${first.lastError}');
    expect(await acquire(second), isFalse);

    final inspection = await second.inspect();
    expect(inspection.isHeld, isTrue);
    expect((await first.readRecord())!['pid'], 4321);
    expect((await first.readRecord())!['operation'], 'download');

    await first.release();
    expect((await second.inspect()).isHeld, isFalse);
    expect(await acquire(second), isTrue);
    await second.release();
  });

  test('PID 或启动时间不匹配时拒绝获取（PID 复用）', () async {
    final lock = FileUpdateLock(
      file: file,
      processProbe: FakeProcessProbe(pid: 9999),
    );

    final acquired = await lock.acquire(
      transactionId: 'tx-1',
      pid: 4321,
      processStartedAtUtc: DateTime.utc(2026, 10, 18, 11),
      token: 'a' * 64,
      operation: 'download',
      targetVersion: '1.9.0.0',
    );

    expect(acquired, isFalse);
  });

  test('进程退出留下的记录不会阻止下一次获取', () async {
    await file.writeAsString(
      '{"schemaVersion":1,"pid":1234,'
      '"processStartedAtUtc":"2026-10-18T00:00:00Z","operation":"install"}',
    );
    final lock = await buildLock();

    expect(await acquire(lock, operation: 'install'), isTrue);
    await lock.release();
  });

  test('锁文件记录事务号、操作与目标版本，便于诊断', () async {
    final lock = await buildLock();
    await acquire(lock, operation: 'install');

    final record = await lock.readRecord();
    expect(record!['transactionId'], 'tx-1');
    expect(record['operation'], 'install');
    expect(record['targetVersion'], '1.9.0.0');
    expect(record['pid'], 4321);

    await lock.release();
    expect(await file.exists(), isFalse);
  });
}



