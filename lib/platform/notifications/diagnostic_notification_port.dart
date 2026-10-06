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
      _breadcrumb('查询待发通知', inner.pendingNotifications);

  @override
  Future<void> scheduleOneShot(NotificationRequest request) =>
      _breadcrumb('安排通知 ${request.id}', () => inner.scheduleOneShot(request));

  @override
  Future<void> cancel(String id) =>
      _breadcrumb('取消通知 $id', () => inner.cancel(id));

  /// **崩溃定位用的面包屑**（2026-10-04）：在每次原生调用**前后**各落一行盘。
  ///
  /// **为什么这么做**：`0xc0000409`（BEX64，故障模块 `ucrtbase.dll`）至今未定位——按事件日志
  /// 逐条核对后已确认**16 次崩溃全部来自未打包运行方式**（`Faulting 包全名` 为空），安装版
  /// 从未被观察到崩溃；但**触发点未知，且没有栈**（WER 没有转储，开 LocalDumps 要管理员权限）。
  ///
  /// 拿不到栈时，**"最后一条落盘的面包屑"就是栈的替代品**：这些调用是 Dart 与原生之间唯一的
  /// 边界，进程若在这里死掉，"进入"那行会留在盘上、"返回"那行不会——于是能判定**是哪一次调用**，
  /// 而不必去猜。
  ///
  /// 三条刻意的取舍：
  /// - **只包通知端口的四个原生调用**：它们是本应用仅有的 FFI 面（`flutter_local_notifications`
  ///   的 win32 实现）。**不碰** `windows_notification_adapter.dart` 本身——那个文件此刻正被
  ///   另一位写者修改，往里面加代码会把他的改动一起卷进我的提交；
  /// - **每条都写盘**：`FileDiagnosticLog.write` 逐次追加，不做缓冲——缓冲过的日志在崩溃时会**丢掉
  ///   最后那几行**，而最后几行正是这里唯一要拿的东西；
  /// - **失败也记，然后照常抛**：记 `调用失败：…` 再让异常继续往上走。这一层不改行为，
  ///   只让它可观测——把异常吞掉会掩盖真正的故障。
  Future<T> _breadcrumb<T>(String what, Future<T> Function() call) async {
    log.write('原生调用进入：$what');
    try {
      final result = await call();
      log.write('原生调用返回：$what');
      return result;
    } catch (error) {
      log.write('原生调用失败：$what → $error');
      rethrow;
    }
  }

  @override
  void onTapped(void Function(NotificationPayload payload) handler) {
    inner.onTapped((payload) {
      log.write(
        '通知被点击（应用在运行）：route=${payload.route} '
        'kind=${payload.kind.name} id=${payload.notificationId}',
      );
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
      log.write(
        '冷启动由通知拉起：route=${payload.route} '
        'kind=${payload.kind.name} id=${payload.notificationId}',
      );
    }
    return payload;
  }
}
