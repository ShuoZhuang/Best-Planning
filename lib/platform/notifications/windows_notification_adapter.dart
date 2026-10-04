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

/// 按当前 Windows 运行方式选择通知端口。
///
/// `flutter_local_notifications` 的 Windows 原生后端在本项目的免安装进程中会以
/// `0xc0000409` 越过 Dart 异常边界并直接终止进程；同一构建装进 MSIX 后则稳定，且
/// 包身份也是可靠取消和点击激活的前提。因此免安装 EXE 明确降级为不可安排通知，
/// 不让一个附加能力拖垮整个日程应用。
NotificationPort buildWindowsNotificationPort({
  required bool hasPackageIdentity,
  String? appUserModelId,
  WindowsNotificationBackend? backend,
}) {
  if (!hasPackageIdentity) return const UnpackagedWindowsNotificationPort();
  return WindowsNotificationAdapter(
    backend: backend,
    hasPackageIdentity: true,
    appUserModelId: appUserModelId,
  );
}

final class UnpackagedWindowsNotificationPort implements NotificationPort {
  const UnpackagedWindowsNotificationPort();

  static const _diagnostic =
      '当前为免安装 EXE。为避免 Windows 原生通知组件导致程序退出，系统提醒已停用；'
      '安装 MSIX 版本后可启用完整提醒。';

  @override
  Future<NotificationCapability> capability() async =>
      const NotificationCapability(
        canSchedule: false,
        canCancelReliably: false,
        diagnostic: _diagnostic,
      );

  @override
  Future<List<PendingNotification>> pendingNotifications() async => const [];

  @override
  Future<void> scheduleOneShot(NotificationRequest request) async {}

  @override
  Future<void> cancel(String id) async {}

  @override
  void onTapped(void Function(NotificationPayload payload) handler) {}

  @override
  Future<NotificationPayload?> launchPayload() async => null;
}

final class FlutterWindowsNotificationBackend
    implements WindowsNotificationBackend {
  FlutterWindowsNotificationBackend({
    FlutterLocalNotificationsPlugin? plugin,
    this.appUserModelId,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// 通知点击的**激活器 CLSID**。
  ///
  /// 这个东西有两处必须**完全一致**，否则点击不会回到本应用：
  /// ① 这里传给插件的 `guid`（插件据此把 `CustomActivator` 写进注册表、并用
  /// `CoRegisterClassObject` 把 COM 类对象注册进本进程）；
  /// ② 打包时清单里声明的 toast 激活器（`msix_config` 的 `toast_activator_clsid`）——
  /// **打包应用走的是清单声明**，不是上面那套注册表约定。
  static const activatorGuid = '7D40D6B0-AC23-4E16-9F0F-21C8AEF635B4';

  /// 未打包（免安装 EXE）时回退用的 AUMID。
  ///
  /// 这条回退**只对免安装 EXE 有意义**：那种进程没有包身份，插件的注册表激活器约定才适用。
  /// 打包进程**必须**用真实的 `<包族名>!<应用Id>`——否则 Windows 按包身份 AUMID 去找激活器
  /// 会找不到，点击退化成"重新启动一个进程"，表现就是"窗口到了前台但没跳转"（实测，见
  /// `docs/testing/flow-verification.md` 第九节）。组合根会在"有包身份却取不到 AUMID"时记诊断。
  static const fallbackAppUserModelId = 'PersonalPlanner.Desktop.App';

  static const _details = NotificationDetails(
    windows: WindowsNotificationDetails(
      duration: WindowsNotificationDuration.short,
    ),
  );

  final FlutterLocalNotificationsPlugin _plugin;

  /// 真实 AUMID；为空时用 [fallbackAppUserModelId]（仅对免安装 EXE 成立）。
  final String? appUserModelId;

  /// 实际会传给插件的 AUMID（回退也在这里体现）。
  ///
  /// **公开是刻意的**：这样测试能直接断言「打包时必须用真实值、回退只对免安装 EXE 成立」，
  /// 而不必去读私有的初始化设置对象。
  String get effectiveAppUserModelId =>
      appUserModelId ?? fallbackAppUserModelId;

  WindowsInitializationSettings get _initialization =>
      WindowsInitializationSettings(
        appName: '智能日程',
        appUserModelId: effectiveAppUserModelId,
        guid: activatorGuid,
      );

  @override
  Future<void> initialize({
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
  }) async {
    await _plugin.initialize(
      // 不再是 `const`：AUMID 现在是运行时决定的（见 `effectiveAppUserModelId`）。
      settings: InitializationSettings(windows: _initialization),
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

    /// 真实 AUMID（`<包族名>!<应用Id>`，由 `currentApplicationUserModelId()` 取得）。
    ///
    /// 为空时后端回退到 [FlutterWindowsNotificationBackend.fallbackAppUserModelId]——那条回退
    /// **只对免安装 EXE 成立**；打包进程若走了回退，点击通知就无法正确激活（见后端里 `effectiveAppUserModelId`
    /// 的说明）。因此组合根在"有包身份却取不到 AUMID"时会记一条诊断。
    String? appUserModelId,
  }) : assert(plugin == null || backend == null),
       _backend =
           backend ??
           FlutterWindowsNotificationBackend(
             plugin: plugin,
             appUserModelId: appUserModelId,
           );

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
