import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/platform/diagnostics/file_diagnostic_log.dart';

/// 给通知端口套一层：**把"用户点了通知"这件事落盘**，其余原样转发。
///
/// **为什么需要它**：点击通知这条链路此前在 Release 里完全不可观测——它到底有没有被触发、
/// 拿到的 payload 解出了什么 route、冷启动时 `launchPayload()` 返回了还是没返回，全都没有痕迹。
/// 于是"点了没反应"只能靠猜（本会话已经为它猜错过一次：把"没重建注册表键"当成了
/// "`initialize()` 没跑到"，见 `docs/testing/flow-verification.md` 第十节）。
///
/// 用**装饰器**而不是在每个调用点加日志：`PlannerApp` 只认 `NotificationPort`，因此这里既不必
/// 给它多加一个参数、也不会漏掉任何一条点击路径。
///
/// 三条刻意的取舍：
/// - **只记事实，不记判断**：写"点击到达：route=…"，而不写"点击成功"——导航是否真的发生由页面
///   决定，这一层无从得知，写了就是编。
/// - **解码失败也记**：`onTapped` 拿到的 payload 是端口已经解好的，因此这里只能记 route；而
///   `launchPayload()` 返回 null 恰恰是最要命的一种情况（冷启动没拿到落点），必须与
///   "根本没被通知拉起"区分开——区分不了就如实写"未拿到 payload"。
/// - **不影响行为**：日志写失败（`FileDiagnosticLog` 本身不抛）不能让点击失效。
final class DiagnosticNotificationPort implements NotificationPort {
  DiagnosticNotificationPort({required this.inner, required this.log});

  final NotificationPort inner;
  final FileDiagnosticLog log;

  @override
  Future<NotificationCapability> capability() => inner.capability();

  @override
  Future<List<PendingNotification>> pendingNotifications() =>
      inner.pendingNotifications();

  @override
  Future<void> scheduleOneShot(NotificationRequest request) =>
      inner.scheduleOneShot(request);

  @override
  Future<void> cancel(String id) => inner.cancel(id);

  @override
  void onTapped(void Function(NotificationPayload payload) handler) {
    inner.onTapped((payload) {
      log.write('通知被点击（应用在运行）：route=${payload.route} '
          'kind=${payload.kind.name} id=${payload.notificationId}');
      handler(payload);
    });
  }

  @override
  Future<NotificationPayload?> launchPayload() async {
    final payload = await inner.launchPayload();
    if (payload == null) {
      // 这句话的两种含义必须在排查时能分开，因此把"没拿到"如实写出来；至于"是不是被通知拉起的"
      // 取决于平台，这一层看不到，不替它下结论。
      log.write('冷启动未拿到通知 payload（可能是普通启动，也可能是点击未被平台交付）');
    } else {
      log.write('冷启动由通知拉起：route=${payload.route} '
          'kind=${payload.kind.name} id=${payload.notificationId}');
    }
    return payload;
  }
}
