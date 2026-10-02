import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

enum ErasureStatus { completed, confirmationMismatch }

final class DataErasureService {
  const DataErasureService({
    required this.database,
    required this.backupIndex,
    required this.notifications,
    required this.credentials,
  });

  static const confirmationPhrase = '永久删除我的全部本地数据';

  final DatabaseLifecyclePort database;
  final BackupIndexPort backupIndex;
  final NotificationPort notifications;
  final AppLockCredentialStore credentials;

  Future<ErasureStatus> eraseAll(String confirmation) async {
    if (confirmation != confirmationPhrase) {
      return ErasureStatus.confirmationMismatch;
    }
    final pending = await notifications.pendingNotifications();
    for (final notification in pending) {
      await notifications.cancel(notification.id);
    }
    await credentials.clear();
    await backupIndex.clear();
    await database.eraseAll();
    return ErasureStatus.completed;
  }
}
