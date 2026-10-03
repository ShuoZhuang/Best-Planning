import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/platform/notifications/windows_notification_adapter.dart';

void main() {
  test('启动通知入口在初始化期间重入时只初始化一次', () async {
    final backend = _ReentrantWindowsNotificationBackend();

    late final WindowsNotificationAdapter adapter;
    late Future<Object?> reentrantLaunch;
    backend.duringFirstInitialization = () async {
      reentrantLaunch = adapter.launchPayload();
    };
    adapter = WindowsNotificationAdapter(backend: backend);

    await adapter.pendingNotifications();
    await reentrantLaunch;

    expect(backend.initializeCalls, 1);
  });
}

final class _ReentrantWindowsNotificationBackend
    implements WindowsNotificationBackend {
  late Future<void> Function() duringFirstInitialization;
  int initializeCalls = 0;

  @override
  Future<void> initialize({
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
  }) async {
    initializeCalls += 1;
    if (initializeCalls == 1) {
      await duringFirstInitialization();
    }
  }

  @override
  Future<NotificationAppLaunchDetails?> launchDetails() async {
    return const NotificationAppLaunchDetails(false);
  }

  @override
  Future<List<PendingNotificationRequest>> pendingRequests() async {
    return const [];
  }

  @override
  Future<void> cancel({required int id}) async {}

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAtUtc,
    required String payload,
  }) async {}
}
