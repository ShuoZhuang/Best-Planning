// 启动时的自动检查调度（路线图 §3.6 / §11 Task 11）。
//
// 这一段代码的全部价值在于"**什么时候不发请求**"：
//   · 启动**约 10 秒后**才检查，不抢启动路径（§3.6）。启动时立刻发一次请求会与数据库打开、
//     提醒同步、默认领域补齐挤在同一段，而更新检查的结果对首屏没有任何影响。
//   · 这一次检查**仍然走 `check(manual: false)`**，因此 24 小时窗口与开关对它同样有效。
//     不绕过去是刻意的：把"启动就检查一次"写成特权路径，就会出现"关掉自动检查后每次启动
//     还是联网一次"——那正是用户在设置里关掉它时最不想要的。
//   · **`dispose()` 必须取消定时器**（§3.6："程序关闭后不运行定时器，不创建 Windows 后台
//     服务"）。这里刻意不引入 `Timer.periodic` 或任何后台机制：一次性的延迟定时器是"应用在
//     运行时每 24 小时最多请求一次"这句话的**全部**实现——下一次检查发生在**下一次启动**，
//     而不是靠一个常驻循环。
import 'dart:async';

import 'package:personal_planner/application/update_service.dart';
import 'package:personal_planner/core/clock.dart';

final class UpdateCheckScheduler {
  UpdateCheckScheduler({required this.service, required this.clock});

  /// 启动延迟（§3.6："启动约 10 秒后检查一次"）。做成公开常量，测试才不必抄一个字面量。
  static const Duration startupDelay = Duration(seconds: 10);

  final UpdateService service;
  final Clock clock;

  Timer? _timer;
  bool _disposed = false;

  /// 排下启动后的那一次检查。**重复调用是安全的**：第二次不会排出第二个定时器
  /// （否则"启动一次"会变成"启动两次"，而 24 小时窗口是按设置里的时间算的，两次都会通过）。
  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer(startupDelay, _runOnce);
  }

  /// 取消待执行的检查。应用退出时调用。
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _runOnce() async {
    _timer = null;
    if (_disposed) return;
    try {
      // 走自动路径：窗口与开关由服务判定，调度器不自作主张。
      await service.check(manual: false);
    } on Object {
      // **绝不往上抛**：这一层在启动路径上，一次检查失败（离线、限流）不该影响任何别的东西。
      // 失败因此是静默的——用户看不到打扰，而手动检查会给出具体原因（§3.6）。
    }
  }
}
