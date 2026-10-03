import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

enum ErasureStatus { completed, confirmationMismatch }

final class DataErasureService {
  const DataErasureService({
    required this.database,
    this.backupIndex,
    required this.notifications,
    required this.credentials,
  });

  static const confirmationPhrase = '永久删除我的全部本地数据';

  final DatabaseLifecyclePort database;

  /// 应用的"备份索引"。**可选，因为生产里没有这个东西**：`BackupIndexPort` 至今没有任何生产
  /// 写入方（`FileBackupIndexAdapter` 只被测试构造），因此装配处**刻意不传**——用一个指向没人
  /// 写过的文件的适配器把接口填满，只会让"已清除"这句话显得比实际更完整。为空时跳过。
  final BackupIndexPort? backupIndex;

  final NotificationPort notifications;
  final AppLockCredentialStore credentials;

  /// 执行永久清除。
  ///
  /// **最后一步是"安排删库"，不是"当场删库"**：见 `lib/app/backup_assembly.dart` 的
  /// [DatabaseLifecyclePort.eraseAll] 实现说明——运行中的 drift 连接仍指向数据库文件，
  /// 当场删除要么留下面向用户的假象（界面还显示数据），要么在 Windows 上因共享冲突抛错，
  /// 而在这一步之前凭据与通知**已经**被清掉，失败就留下半清除状态。因此实际删除发生在下次
  /// 启动、没有连接的时候；界面据此必须如实说"重启后生效"。
  Future<ErasureStatus> eraseAll(String confirmation) async {
    if (confirmation != confirmationPhrase) {
      return ErasureStatus.confirmationMismatch;
    }
    final pending = await notifications.pendingNotifications();
    for (final notification in pending) {
      await notifications.cancel(notification.id);
    }
    await credentials.clear();
    await backupIndex?.clear();
    await database.eraseAll();
    return ErasureStatus.completed;
  }
}
