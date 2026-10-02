import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:timezone/timezone.dart' as tz;

final class WindowsNotificationAdapter implements NotificationPort {
  WindowsNotificationAdapter({
    FlutterLocalNotificationsPlugin? plugin,
    this.hasPackageIdentity = false,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

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
  final bool hasPackageIdentity;
  Future<void>? _initializing;

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
    final pending = await _plugin.pendingNotificationRequests();
    return pending
        .map((item) {
          final payload = item.payload ?? '';
          return PendingNotification(
            id: _notificationIdFrom(payload) ?? 'native.${item.id}',
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
    await _plugin.zonedSchedule(
      id: _nativeId(request.id),
      title: request.title,
      body: request.body,
      scheduledDate: tz.TZDateTime.from(request.scheduledAtUtc, tz.UTC),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: request.payload,
    );
  }

  @override
  Future<void> cancel(String id) async {
    await _ensureInitialized();
    await _plugin.cancel(id: _nativeId(id));
  }

  Future<void> _ensureInitialized() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(windows: _initialization),
    );
  }

  static String? _notificationIdFrom(String payload) {
    try {
      final value = jsonDecode(payload);
      if (value case {'notificationId': final String id}) return id;
    } on FormatException {
      return null;
    }
    return null;
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
