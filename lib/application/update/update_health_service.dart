// 健康确认（规格 §13.2 / UPD-037）。
//
// 新版本启动后必须写下"我确实起来了、版本对、数据库能开、核心仓储能读、界面初始化完成、
// 更新状态可读写、没有未捕获异常"的确认。助手只认**事务号 + 版本号 + ok** 都匹配的文件。
import 'dart:io';

import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/atomic_file.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

final class UpdateHealthService {
  UpdateHealthService({required this.layout, required this.clock});

  final UpdateStorageLayout layout;
  final Clock clock;

  /// 写健康确认。返回写入的文件路径。
  Future<String> writeConfirmation({
    required String transactionId,
    required MsixVersion version,
    bool databaseOpened = true,
    bool migrationSucceeded = true,
    bool repositoriesReadable = true,
    bool uiInitialized = true,
    bool updateStateReadable = true,
    bool uncaughtStartupError = false,
  }) async {
    final file = layout.healthConfirmationFile(version);
    await writeJsonAtomically(file, {
      'schemaVersion': 1,
      'transactionId': transactionId,
      'version': version.value,
      'ok': databaseOpened &&
          migrationSucceeded &&
          repositoriesReadable &&
          uiInitialized &&
          updateStateReadable &&
          !uncaughtStartupError,
      'checks': {
        'databaseOpened': databaseOpened,
        'migrationSucceeded': migrationSucceeded,
        'repositoriesReadable': repositoriesReadable,
        'uiInitialized': uiInitialized,
        'updateStateReadable': updateStateReadable,
        'uncaughtStartupError': uncaughtStartupError,
      },
      'writtenAtUtc': clock.nowUtc().toIso8601String(),
    });
    return file.path;
  }

  /// 进度心跳。初始化未完成时每 10 秒写一次，助手据此把初始 60 秒延长（绝对上限 5 分钟）。
  Future<void> writeProgress({
    required String transactionId,
    required MsixVersion version,
  }) => writeJsonAtomically(
    File(
      '${layout.versionDirectory(version).path}'
      '${Platform.pathSeparator}health-progress.json',
    ),
    {
      'transactionId': transactionId,
      'version': version.value,
      'writtenAtUtc': clock.nowUtc().toIso8601String(),
    },
  );
}
