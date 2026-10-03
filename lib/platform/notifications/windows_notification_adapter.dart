import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:timezone/timezone.dart' as tz;

abstract interface class WindowsNotificationBackend {
  Future<void> initialize({
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
  });

  Future<NotificationAppLaunchDetails?> launchDetails();

  Future<List<PendingNotificationRequest>> pendingRequests();

  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAtUtc,
    required String payload,
  });

  Future<void> cancel({required int id});
}

final class FlutterWindowsNotificationBackend
    implements WindowsNotificationBackend {
  FlutterWindowsNotificationBackend({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const _initialization = WindowsInitializationSettings(
    appName: '智能日程',
    appUserModelId: 'PersonalPlanner.Desktop.App',
    guid: '7D40D6B0-AC23-4E16-9F0F-21C8AEF635B4',
  );
  static const _details = NotificationDetails(
    windows: WindowsNotificationDetails(
      duration: WindowsNotificationDuration.short,
    ),
  );

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> initialize({
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
  }) async {
    await _plugin.initialize(
      settings: const InitializationSettings(windows: _initialization),
      onDidReceiveNotificationResponse: onDidReceiveNotificationResponse,
    );
  }

  @override
  Future<NotificationAppLaunchDetails?> launchDetails() =>
      _plugin.getNotificationAppLaunchDetails();

  @override
  Future<List<PendingNotificationRequest>> pendingRequests() =>
      _plugin.pendingNotificationRequests();

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAtUtc,
    required String payload,
  }) => _plugin.zonedSchedule(
    id: id,
    title: title,
    body: body,
    scheduledDate: tz.TZDateTime.from(scheduledAtUtc, tz.UTC),
    notificationDetails: _details,
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    payload: payload,
  );

  @override
  Future<void> cancel({required int id}) => _plugin.cancel(id: id);
}

final class WindowsNotificationAdapter implements NotificationPort {
  WindowsNotificationAdapter({
    FlutterLocalNotificationsPlugin? plugin,
    WindowsNotificationBackend? backend,
    this.hasPackageIdentity = false,
  }) : assert(plugin == null || backend == null),
       _backend = backend ?? FlutterWindowsNotificationBackend(plugin: plugin);

  final WindowsNotificationBackend _backend;
  final bool hasPackageIdentity;
  Future<void>? _initializing;

  /// 点击处理器。平台的回调在 `_initialize` 时一次性注册，而处理器可能在那之后才
  /// 被替换，因此回调里读取的是当前值而不是把处理器捕获进去。
  void Function(NotificationPayload payload)? _onTapped;

  @override
  void onTapped(void Function(NotificationPayload payload) handler) {
    _onTapped = handler;
  }

  void _handleResponse(NotificationResponse response) {
    final payload = NotificationPayload.decode(response.payload);
    // 解析不出来的 payload 直接忽略：可能来自旧版本的待发通知，为它抛错会连带
    // 丢掉用户真实的那次点击。
    if (payload == null) return;
    _onTapped?.call(payload);
  }

  @override
  Future<NotificationPayload?> launchPayload() async {
    await _ensureInitialized();
    final details = await _backend.launchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    // 与 _handleResponse 同一份解码、同一条"解不出就忽略"的规则：旧版本留下的 payload
    // 不该让启动失败，也不该伪造一次导航。
    return NotificationPayload.decode(details.notificationResponse?.payload);
  }

  @override
  Future<NotificationCapability> capability() async => NotificationCapability(
    canSchedule: true,
    canCancelReliably: hasPackageIdentity,
    diagnostic: hasPackageIdentity
        ? null
        : '当前为免安装 EXE（无 MSIX 包身份）；Windows 可以安排提醒，'
              '但无法保证取消已经交给系统的旧通知。',
  );

  @override
  Future<List<PendingNotification>> pendingNotifications() async {
    await _ensureInitialized();
    final pending = await _backend.pendingRequests();
    return pending
        .map((item) {
          final payload = item.payload ?? '';
          return PendingNotification(
            id:
                NotificationPayload.decode(payload)?.notificationId ??
                'native.${item.id}',
            payload: payload,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<void> scheduleOneShot(NotificationRequest request) async {
    if (!request.scheduledAtUtc.isUtc) {
      throw ArgumentError.value(
        request.scheduledAtUtc,
        'request.scheduledAtUtc',
        'Must be UTC.',
      );
    }
    await _ensureInitialized();
    await _backend.schedule(
      id: _nativeId(request.id),
      title: request.title,
      body: request.body,
      scheduledAtUtc: request.scheduledAtUtc,
      payload: request.payload,
    );
  }

  @override
  Future<void> cancel(String id) async {
    await _ensureInitialized();
    await _backend.cancel(id: _nativeId(id));
  }

  Future<void> _ensureInitialized() {
    final current = _initializing;
    if (current != null) return current;

    // The Windows plugin can invoke an FFI callback before initialize()
    // returns its Future. Store our shared Future first so another startup
    // path cannot enter the native initializer a second time.
    final completer = Completer<void>();
    _initializing = completer.future;
    unawaited(_completeInitialization(completer));
    return completer.future;
  }

  Future<void> _completeInitialization(Completer<void> completer) async {
    try {
      await _initialize();
      completer.complete();
    } on Object catch (error, stackTrace) {
      _initializing = null;
      completer.completeError(error, stackTrace);
    }
  }

  Future<void> _initialize() async {
    await _backend.initialize(
      // 此前没有注册该回调，因此点击通知什么也不会发生：界面无法知道用户点了哪条
      // 提醒，FR-NOTIFY-04 要求的快捷入口整条链路都是断的。
      onDidReceiveNotificationResponse: _handleResponse,
    );
  }

  static int _nativeId(String value) {
    // Stable FNV-1a keeps the same Windows toast identifier across app runs.
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }
}
