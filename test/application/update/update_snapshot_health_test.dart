// 数据快照与健康确认（UPD-035 / UPD-037）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_health_service.dart';
import 'package:personal_planner/application/update/update_snapshot_service.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_doubles.dart';

void main() {
  late Directory directory;
  late UpdateStorageLayout layout;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_snapshot_test_');
    layout = UpdateStorageLayout(root: directory);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('快照复制文件并写入带摘要的清单，检查点先于复制', () async {
    final database = File('${directory.path}${Platform.pathSeparator}app.sqlite');
    await database.writeAsBytes([1, 2, 3, 4]);
    final settings = File(
      '${directory.path}${Platform.pathSeparator}settings.json',
    );
    await settings.writeAsString('{"theme":"liquid"}');

    var checkpointed = false;
    final service = UpdateSnapshotService(
      layout: layout,
      sources: [
        SnapshotSource(file: database, relativePath: 'app.sqlite'),
        SnapshotSource(file: settings, relativePath: 'settings.json'),
        SnapshotSource(
          file: File('${directory.path}${Platform.pathSeparator}missing'),
          relativePath: 'missing.json',
        ),
      ],
      clock: FakeClock(),
      checkpoint: () async {
        checkpointed = true;
        expect(await database.exists(), isTrue);
      },
    );

    final snapshot = await service.create(transactionId: 'tx-1');

    expect(checkpointed, isTrue);
    expect(snapshot.files, 2);
    final manifestFile = File(snapshot.manifestPath);
    expect(await manifestFile.exists(), isTrue);
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
    expect(manifest['transactionId'], 'tx-1');
    expect(manifest['schemaVersion'], 1);
    final files = (manifest['files']! as List).cast<Map<String, Object?>>();
    expect(files.map((file) => file['relative']), containsAll(['app.sqlite', 'settings.json']));
    expect(files.first['sha256'], hasLength(64));
    expect(
      await File(
        '${snapshot.directoryPath}${Platform.pathSeparator}app.sqlite',
      ).readAsBytes(),
      [1, 2, 3, 4],
    );
  });

  test('快照拒绝绝对路径与目录穿越', () async {
    final source = File('${directory.path}${Platform.pathSeparator}app.sqlite');
    await source.writeAsString('x');
    for (final relative in ['../evil', 'C:/evil', '/absolute', 'a/../../b']) {
      final service = UpdateSnapshotService(
        layout: layout,
        sources: [SnapshotSource(file: source, relativePath: relative)],
        clock: FakeClock(),
      );
      await expectLater(
        service.create(transactionId: 'tx-bad'),
        throwsA(isA<StateError>()),
        reason: '不应接受 $relative',
      );
    }
  });

  test('健康确认包含事务号、版本与各项检查，且 ok 只在全部通过时为真', () async {
    final service = UpdateHealthService(layout: layout, clock: FakeClock());
    final path = await service.writeConfirmation(
      transactionId: 'tx-1',
      version: const MsixVersion(1, 9, 0, 0),
    );

    final json =
        jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
    expect(json['transactionId'], 'tx-1');
    expect(json['version'], '1.9.0.0');
    expect(json['ok'], isTrue);
    expect((json['checks']! as Map)['databaseOpened'], isTrue);

    final failedPath = await service.writeConfirmation(
      transactionId: 'tx-2',
      version: const MsixVersion(1, 9, 0, 0),
      databaseOpened: false,
    );
    final failed =
        jsonDecode(await File(failedPath).readAsString()) as Map<String, Object?>;
    expect(failed['ok'], isFalse);
    expect((failed['checks']! as Map)['databaseOpened'], isFalse);
  });

  test('进度心跳写入目标版本目录', () async {
    final service = UpdateHealthService(layout: layout, clock: FakeClock());
    await service.writeProgress(
      transactionId: 'tx-1',
      version: const MsixVersion(1, 9, 0, 0),
    );

    final file = File(
      '${layout.versionDirectory(const MsixVersion(1, 9, 0, 0)).path}'
      '${Platform.pathSeparator}health-progress.json',
    );
    expect(await file.exists(), isTrue);
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(json['transactionId'], 'tx-1');
  });
}
