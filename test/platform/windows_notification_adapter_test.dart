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

  test('免安装进程使用安全降级端口且绝不初始化原生通知插件', () async {
    final backend = _CountingWindowsNotificationBackend();
    final port = buildWindowsNotificationPort(
      hasPackageIdentity: false,
      backend: backend,
    );

    final capability = await port.capability();
    expect(capability.canSchedule, isFalse);
    expect(capability.canCancelReliably, isFalse);
    expect(capability.diagnostic, contains('MSIX'));
    expect(await port.pendingNotifications(), isEmpty);
    expect(await port.launchPayload(), isNull);
    expect(backend.initializeCalls, 0);
  });

  test('有包身份时继续使用完整 Windows 通知后端', () async {
    final backend = _CountingWindowsNotificationBackend();
    final port = buildWindowsNotificationPort(
      hasPackageIdentity: true,
      appUserModelId: 'Package_family!App',
      backend: backend,
    );

    expect((await port.capability()).canSchedule, isTrue);
    await port.pendingNotifications();
    expect(backend.initializeCalls, 1);
  });
}

final class _CountingWindowsNotificationBackend
    implements WindowsNotificationBackend {
  int initializeCalls = 0;

  @override
  Future<void> initialize({
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
  }) async {
    initializeCalls += 1;
  }

  @override
  Future<NotificationAppLaunchDetails?> launchDetails() async =>
      const NotificationAppLaunchDetails(false);

  @override
  Future<List<PendingNotificationRequest>> pendingRequests() async => const [];

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
