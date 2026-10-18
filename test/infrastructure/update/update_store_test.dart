// 状态文件与日志存储（UPD-019 / UPD-041）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/infrastructure/update/file_update_state_store.dart';
import 'package:personal_planner/infrastructure/update/update_log_store.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_store_test_');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  group('FileUpdateStateStore', () {
    test('原子保存后可以读回', () async {
      final store = FileUpdateStateStore(
        file: File('${directory.path}${Platform.pathSeparator}state.json'),
      );
      final state = UpdateState(
        phase: UpdatePhase.updateAvailable,
        receivedBytes: 12,
        lastCheckedUtc: DateTime.utc(2026, 10, 18),
      );
      await store.save(state);
      final loaded = await store.load();
      expect(loaded.phase, UpdatePhase.updateAvailable);
      expect(loaded.receivedBytes, 12);
      expect(store.lastLoadWasCorrupt, isFalse);
      // 临时文件不残留。
      final leftovers = directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('损坏的状态文件返回全新状态并标记损坏', () async {
      final file = File('${directory.path}${Platform.pathSeparator}state.json');
      await file.writeAsString('{broken');
      final store = FileUpdateStateStore(file: file);

      final loaded = await store.load();
      expect(loaded.phase, UpdatePhase.idle);
      expect(store.lastLoadWasCorrupt, isTrue);
    });

    test('不支持的结构版本也按损坏处理', () async {
      final file = File('${directory.path}${Platform.pathSeparator}state.json');
      await file.writeAsString('{"schemaVersion": 99, "phase": "ready"}');
      final store = FileUpdateStateStore(file: file);

      expect((await store.load()).phase, UpdatePhase.idle);
      expect(store.lastLoadWasCorrupt, isTrue);
    });

    test('reset 删除状态文件', () async {
      final file = File('${directory.path}${Platform.pathSeparator}state.json');
      final store = FileUpdateStateStore(file: file);
      await store.save(const UpdateState(phase: UpdatePhase.ready));
      expect(await file.exists(), isTrue);

      await store.reset();
      expect(await file.exists(), isFalse);
      expect((await store.load()).phase, UpdatePhase.idle);
    });
  });

  group('FileUpdateLogStore', () {
    test('写入失败详情并保留时间与结果码，不写入业务内容', () async {
      final store = FileUpdateLogStore(directory: directory);
      store.write(
        UpdateFailure(
          UpdateFailureCode.networkHttpFailed,
          detail: 'HTTP 403',
          windowsResultCode: 0x80070005,
          attempt: 2,
        ),
      );
      final lines = await store.readRecent();
      expect(lines, hasLength(1));
      expect(lines.single, contains('UPDATE_NETWORK_HTTP_FAILED'));
      expect(lines.single, contains('hresult=0x80070005'));
      expect(lines.single, contains('attempt=2'));
      expect(lines.single, isNot(contains('任务标题')));
    });

    test('敏感字段被替换成占位符', () async {
      final store = FileUpdateLogStore(directory: directory);
      store.writeLine('request token=SECRET123 Authorization: Bearer abc');
      final lines = await store.readRecent();
      expect(lines.single, isNot(contains('SECRET123')));
      expect(lines.single, isNot(contains('abc')));
      expect(lines.single, contains('<redacted>'));
    });

    test('超过 2 MB 时轮转，最多保留 5 个轮转文件', () async {
      final store = FileUpdateLogStore(
        directory: directory,
        maxBytesPerFile: 64,
        maxFiles: 5,
      );
      for (var i = 0; i < 40; i++) {
        store.writeLine('line-$i-xxxxxxxxxxxxxxxxxxxxxxxx');
      }
      final rotated = directory
          .listSync()
          .whereType<File>()
          .where((file) => RegExp(r'update\.log\.\d+$').hasMatch(file.path))
          .toList();
      expect(rotated.length, lessThanOrEqualTo(5));
      expect(await store.logFile.exists(), isTrue);
    });

    test('clear 只删除日志，不动更新目录里的其他文件', () async {
      final store = FileUpdateLogStore(directory: directory);
      store.writeLine('hello');
      final package = File('${directory.path}${Platform.pathSeparator}package.msix.ready');
      await package.writeAsBytes([1, 2, 3]);

      await store.clear();

      expect(await store.logFile.exists(), isFalse);
      expect(await package.exists(), isTrue);
    });
  });
}
