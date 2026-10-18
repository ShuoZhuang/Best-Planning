// 原子落盘（实施计划 §9.3 / §9.5）。
//
// 这些用例覆盖"真实 Windows 上会失败的那一步"：目标文件被占用、或目标位置不是文件。
// 不依赖 mock：用真实的句柄占用触发 `PathAccessException`，与用户机器上的 sharing violation
// 是同一类错误。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/infrastructure/update/atomic_file.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('atomic_file_test_');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  File fileNamed(String name) =>
      File('${directory.path}${Platform.pathSeparator}$name');

  test('写入后替换既有内容，且不留下临时文件', () async {
    final file = fileNamed('state.json');
    await writeTextAtomically(file, 'first');
    await writeTextAtomically(file, 'second');

    expect(await file.readAsString(), 'second');
    expect(
      directory
          .listSync()
          .whereType<File>()
          .where((entry) => entry.path.endsWith('.tmp'))
          .toList(),
      isEmpty,
    );
  });

  test('目标被占用时失败，旧内容保持不变且只清理本次临时文件', () async {
    final file = fileNamed('state.json');
    await writeTextAtomically(file, '{"old":true}');

    // 占住目标：Windows 上重命名到被独占打开的文件会返回访问拒绝（sharing violation）。
    final handle = await file.open(mode: FileMode.append);
    try {
      await expectLater(
        writeTextAtomically(file, '{"new":true}'),
        throwsA(isA<AtomicFileException>()),
      );
    } finally {
      await handle.close();
    }

    expect(await file.readAsString(), '{"old":true}', reason: '最后一份有效状态不能被破坏');
    expect(
      directory
          .listSync()
          .whereType<File>()
          .where((entry) => entry.path.endsWith('.tmp'))
          .toList(),
      isEmpty,
      reason: '本次临时文件必须被清理',
    );

    // 解除占用后同一份内容可以正常覆盖。
    await writeTextAtomically(file, '{"new":true}');
    expect(await file.readAsString(), '{"new":true}');
  });

  test('目标位置是目录时失败，并给出操作名与 Windows 错误码', () async {
    final target = Directory('${directory.path}${Platform.pathSeparator}state.json');
    await target.create();

    try {
      await writeTextAtomically(File(target.path), 'x');
      fail('目标为目录时不可能成功');
    } on AtomicFileException catch (error) {
      expect(error.operation, 'replace');
      expect(error.diagnosticDetail, contains('op=replace'));
      expect(error.osErrorCode, isNotNull);
      expect(error.diagnosticDetail, contains('os='));
      // 诊断里不能出现完整用户目录。
      expect(error.diagnosticDetail, isNot(contains(directory.path)));
    }
    expect(await target.exists(), isTrue);
  });

  test('提升：成功时源文件消失、目标出现', () async {
    final source = fileNamed('package.msix.partial');
    final target = fileNamed('package.msix.ready');
    await source.writeAsBytes([1, 2, 3]);

    await promoteVerifiedFile(source, target);

    expect(await source.exists(), isFalse);
    expect(await target.readAsBytes(), [1, 2, 3]);
  });

  test('提升失败时保留已验证的源文件', () async {
    final source = fileNamed('package.msix.partial');
    final target = fileNamed('package.msix.ready');
    final body = List<int>.generate(64, (index) => index);
    await source.writeAsBytes(body);

    // 目标位置是目录 → 提升一定失败。
    await Directory(target.path).create();

    try {
      await promoteVerifiedFile(source, target);
      fail('目标为目录时不可能成功');
    } on AtomicFileException catch (error) {
      expect(error.operation, 'promote');
      expect(error.diagnosticDetail, contains('op=promote'));
      expect(error.osErrorCode, isNotNull);
    }
    expect(await source.exists(), isTrue, reason: '完整且哈希正确的字节必须保留');
    expect(await source.readAsBytes(), body);
  });
}
