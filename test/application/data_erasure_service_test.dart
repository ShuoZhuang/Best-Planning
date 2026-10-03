import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/application/data_erasure_service.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

void main() {
  test('只有明确确认短语才清除数据库、索引、通知和锁凭据', () async {
    final database = _Database();
    final index = _BackupIndex();
    final notifications = _Notifications();
    final credentials = InMemoryAppLockCredentialStore('hash-only');
    final service = DataErasureService(
      database: database,
      backupIndex: index,
      notifications: notifications,
      credentials: credentials,
    );

    expect(await service.eraseAll('删除'), ErasureStatus.confirmationMismatch);
    expect(database.erased, isFalse);

    expect(
      await service.eraseAll(DataErasureService.confirmationPhrase),
      ErasureStatus.completed,
    );
    expect(database.erased, isTrue);
    expect(index.cleared, isTrue);
    expect(notifications.cancelled, {'planner.one', 'planner.two'});
    expect(await credentials.read(), isNull);
    expect(index.externalExportsDeleted, isFalse);
  });
}

final class _Database implements DatabaseLifecyclePort {
  bool erased = false;
  @override
  int get supportedSchemaVersion => 1;
  @override
  Future<void> eraseAll() async => erased = true;
  @override
  Future<void> createConsistentSnapshot(String destination) =>
      throw UnimplementedError();
  @override
  Future<DatabaseInspection> inspect(String candidate) =>
      throw UnimplementedError();
  @override
  Future<void> replaceWith(String validatedDatabase) =>
      throw UnimplementedError();
}

final class _BackupIndex implements BackupIndexPort {
  bool cleared = false;
  bool externalExportsDeleted = false;
  @override
  Future<void> clear() async => cleared = true;
}

final class _Notifications implements NotificationPort {
  final cancelled = <String>{};
  @override
  void onTapped(void Function(NotificationPayload payload) handler) {}

  @override
  Future<NotificationPayload?> launchPayload() async => null;

  @override
  Future<void> cancel(String id) async => cancelled.add(id);
  @override
  Future<NotificationCapability> capability() async =>
      const NotificationCapability.available();
  @override
  Future<List<PendingNotification>> pendingNotifications() async => const [
    PendingNotification(id: 'planner.one', payload: ''),
    PendingNotification(id: 'planner.two', payload: ''),
  ];
  @override
  Future<void> scheduleOneShot(NotificationRequest request) =>
      throw UnimplementedError();
}
