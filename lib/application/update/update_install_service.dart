// 安装准备服务（规格 §12.2 / §12.3 第 1～9 步 / UPD-031 / UPD-033 / UPD-035）。
//
// 它把"用户点了就绪入口"之后主程序该做的全部事情收在一处：
//   冻结写入（由调用方的安全协调器负责）→ 生成快照 → 写一次性请求 → 启动助手 →
//   确认助手取得请求 → 交给调用方退出主程序。
//
// **助手没有确认之前，主程序绝不退出**：这里只在 [UpdateHelper.launch] 返回成功后把控制权
// 交给 `requestExit`。
import 'dart:io';
import 'dart:math';

import 'package:personal_planner/application/update/update_snapshot_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

final class UpdateInstallService implements UpdateInstallCoordinator {
  UpdateInstallService({
    required this.layout,
    required this.helper,
    required this.snapshotService,
    required this.processProbe,
    required this.clock,
    required this.onRequestExit,
    this.dataDirectory,
    this.requestValidity = const Duration(minutes: 10),
  });

  final UpdateStorageLayout layout;
  final UpdateHelper helper;
  final UpdateSnapshotService snapshotService;
  final ProcessIdentityProbe processProbe;
  final Clock clock;
  final Future<void> Function() onRequestExit;
  final String? dataDirectory;
  final Duration requestValidity;

  @override
  Future<InstallPreparationOutcome> prepareAndLaunch({
    required UpdateTarget target,
    required UpdateState state,
    required InstalledPackage installed,
  }) async {
    final ready = layout.readyPackage(target);
    if (!await ready.exists()) {
      return const InstallPreparationOutcome.failed(
        UpdateFailure(UpdateFailureCode.packageFormatInvalid),
      );
    }

    final now = clock.nowUtc();
    final transactionId = _newTransactionId();
    final token = _randomHex(32);
    final UpdateSnapshotResult snapshot;
    try {
      snapshot = await snapshotService.create(transactionId: transactionId);
    } on Object {
      return const InstallPreparationOutcome.failed(
        UpdateFailure(UpdateFailureCode.snapshotFailed),
      );
    }

    final ProcessIdentity mainProcess;
    try {
      mainProcess = await processProbe.current();
    } on Object {
      return const InstallPreparationOutcome.failed(
        UpdateFailure(UpdateFailureCode.helperRequestInvalid),
      );
    }

    final baseline = state.baseline;
    final request = UpdateHelperRequest(
      schemaVersion: 1,
      transactionId: transactionId,
      fromVersion: installed.version,
      toVersion: target.msixVersion,
      packagePath: ready.path,
      packageSizeBytes: target.sizeBytes,
      packageSha256: target.sha256,
      identityName: installed.identityName,
      familyName: installed.familyName,
      publisher: installed.publisher,
      architecture: appArchitecture,
      mainPid: mainProcess.pid,
      mainStartedAtUtc: mainProcess.startedAtUtc,
      // 主程序没有独立托盘进程；同一 PID 交给助手即可（它只关心"这些进程都退出了"）。
      trayPid: mainProcess.pid,
      trayStartedAtUtc: mainProcess.startedAtUtc,
      token: token,
      createdAtUtc: now,
      expiresAtUtc: now.add(requestValidity),
      rollbackPackagePath: baseline?.packagePath,
      rollbackVersion: baseline?.version,
      snapshotPath: snapshot.directoryPath,
      dataDirectory: dataDirectory,
    );

    final launch = await helper.launch(request);
    if (!launch.isLaunched) {
      final failure = launch.failure ??
          UpdateFailure(
            UpdateFailureCode.fromCode(launch.failureCode) ??
                UpdateFailureCode.helperLaunchFailed,
          );
      return InstallPreparationOutcome.failed(failure);
    }
    return InstallPreparationOutcome.launched(
      transactionId: transactionId,
      snapshotPath: snapshot.directoryPath,
    );
  }

  @override
  Future<void> requestExit() => onRequestExit();

  static String _newTransactionId() {
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch
        .toRadixString(16);
    return '$timestamp-${_randomHex(8)}';
  }

  static String _randomHex(int bytes) {
    final random = Random.secure();
    return List<String>.generate(
      bytes,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

/// 需要进入快照的固定集合（规格 §13.1）。
List<SnapshotSource> defaultSnapshotSources({
  required String databasePath,
  required UpdateStorageLayout layout,
}) => [
  SnapshotSource(file: File(databasePath), relativePath: 'app.sqlite'),
  SnapshotSource(
    file: layout.stateFile,
    relativePath: 'update-state.json',
  ),
];

/// 当前数据目录（快照恢复的落点）。
String? dataDirectoryFor(String databasePath) {
  final separator = databasePath.lastIndexOf(Platform.pathSeparator);
  if (separator <= 0) return null;
  return databasePath.substring(0, separator);
}

/// 把 `MsixVersion` 转成字符串时的空安全辅助（避免调用处重复判空）。
String? versionLabel(MsixVersion? version) => version?.value;



