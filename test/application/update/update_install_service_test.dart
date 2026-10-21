// 安装准备：快照、一次性请求、助手握手（UPD-031 / UPD-033 / UPD-035）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_install_service.dart';
import 'package:personal_planner/application/update/update_snapshot_service.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_doubles.dart';

void main() {
  late Directory directory;
  late UpdateStorageLayout layout;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_install_test_');
    layout = UpdateStorageLayout(root: directory);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<UpdateInstallService> buildService({
    required FakeUpdateHelper helper,
    required Future<void> Function() onExit,
  }) async => UpdateInstallService(
    layout: layout,
    helper: helper,
    snapshotService: UpdateSnapshotService(
      layout: layout,
      sources: const [],
      clock: FakeClock(),
    ),
    processProbe: FakeProcessProbe(),
    clock: FakeClock(),
    dataDirectory: '${directory.path}${Platform.pathSeparator}data',
    onRequestExit: onExit,
  );

  Future<File> writeReadyPackage() async {
    final ready = layout.readyPackage(targetFixture);
    await ready.parent.create(recursive: true);
    await ready.writeAsBytes([1, 2, 3]);
    return ready;
  }

  test('生成一次性请求并在助手确认后才允许退出', () async {
    final ready = await writeReadyPackage();
    final helper = FakeUpdateHelper();
    var exited = false;
    final service = await buildService(
      helper: helper,
      onExit: () async => exited = true,
    );

    final outcome = await service.prepareAndLaunch(
      target: targetFixture,
      state: const UpdateState(phase: UpdatePhase.ready),
      installed: installedFixture,
    );

    expect(outcome.launched, isTrue);
    expect(outcome.transactionId, isNotEmpty);
    expect(outcome.snapshotPath, isNotNull);
    final request = helper.lastRequest!;
    expect(request.packagePath, ready.path);
    expect(request.packageSizeBytes, targetFixture.sizeBytes);
    expect(request.packageSha256, targetFixture.sha256);
    expect(request.fromVersion.value, '1.8.1.0');
    expect(request.toVersion.value, '1.9.0.0');
    expect(request.token, hasLength(64));
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(request.token), isTrue);
    expect(request.expiresAtUtc.isAfter(request.createdAtUtc), isTrue);
    expect(request.mainPid, 4321);
    expect(request.dataDirectory, endsWith('data'));

    // 助手确认前不退出。
    expect(exited, isFalse);
    await service.requestExit();
    expect(exited, isTrue);
  });

  test('快照在启动助手之前生成，并包含数据库', () async {
    await writeReadyPackage();
    final database = File(
      '${directory.path}${Platform.pathSeparator}app.sqlite',
    );
    await database.writeAsBytes([9, 9, 9]);
    final helper = FakeUpdateHelper();
    final service = UpdateInstallService(
      layout: layout,
      helper: helper,
      snapshotService: UpdateSnapshotService(
        layout: layout,
        sources: [SnapshotSource(file: database, relativePath: 'app.sqlite')],
        clock: FakeClock(),
      ),
      processProbe: FakeProcessProbe(),
      clock: FakeClock(),
      onRequestExit: () async {},
    );

    final outcome = await service.prepareAndLaunch(
      target: targetFixture,
      state: const UpdateState(phase: UpdatePhase.ready),
      installed: installedFixture,
    );

    expect(outcome.launched, isTrue);
    expect(outcome.snapshotPath, isNotNull);
    expect(
      await File('${outcome.snapshotPath}${Platform.pathSeparator}app.sqlite')
          .exists(),
      isTrue,
    );
  });

  test('就绪包不存在时不发请求', () async {
    final helper = FakeUpdateHelper();
    final service = await buildService(helper: helper, onExit: () async {});

    final outcome = await service.prepareAndLaunch(
      target: targetFixture,
      state: const UpdateState(phase: UpdatePhase.ready),
      installed: installedFixture,
    );

    expect(outcome.launched, isFalse);
    expect(outcome.failure!.code, UpdateFailureCode.packageFormatInvalid);
    expect(helper.launchCalls, 0);
  });

  test('助手握手失败时整体失败，状态可回到就绪', () async {
    await writeReadyPackage();
    final helper = FakeUpdateHelper(
      launchResult: const HelperLaunchResult.handshakeFailed(
        'UPDATE_HELPER_LAUNCH_FAILED',
      ),
    );
    final service = await buildService(helper: helper, onExit: () async {});

    final outcome = await service.prepareAndLaunch(
      target: targetFixture,
      state: const UpdateState(phase: UpdatePhase.ready),
      installed: installedFixture,
    );

    expect(outcome.launched, isFalse);
    expect(outcome.failure!.code, UpdateFailureCode.helperLaunchFailed);
  });
}
