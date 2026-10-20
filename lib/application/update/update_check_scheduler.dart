// 自动检查的触发策略（规格 §7.1）。
//
// 五种触发在这里合并成一次检查：
//   · 启动约 10 秒后一次；
//   · 运行期间距上次成功检查超过 24 小时；
//   · 网络从不可用变为可用（防抖）；
//   · 下载失败到达下次重试时间；
//   · 用户在设置页点"立即重新检查"（直接调用控制器，不经过这里）。
//
// **合并由编排器保证**：同一时刻的重复触发返回同一个 Future，不会产生第二个请求。
import 'dart:async';

import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';

final class UpdateCheckScheduler {
  UpdateCheckScheduler({
    required this.controller,
    this.clock = const SystemClock(),
    this.networkMonitor,
    this.startupDelay = const Duration(seconds: 10),
    this.tickInterval = const Duration(minutes: 1),
    this.minimumCheckInterval = const Duration(hours: 24),
    this.networkDebounce = const Duration(seconds: 5),
  });

  final UpdateController controller;
  final Clock clock;
  final NetworkStatusMonitor? networkMonitor;
  final Duration startupDelay;
  final Duration tickInterval;
  final Duration minimumCheckInterval;
  final Duration networkDebounce;

  Timer? _startupTimer;
  Timer? _tickTimer;
  Timer? _debounceTimer;
  StreamSubscription<bool>? _networkSubscription;
  bool _networkWasAvailable = true;
  bool _started = false;
  bool _disposed = false;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _startupTimer = Timer(startupDelay, () {
      _startupTimer = null;
      unawaited(_checkIfEnabled());
    });
    _tickTimer = Timer.periodic(tickInterval, (_) => _onTick());

    final monitor = networkMonitor;
    if (monitor != null) {
      _networkWasAvailable = monitor.isAvailable;
      _networkSubscription = monitor.changes.listen((available) {
        final recovered = !_networkWasAvailable && available;
        _networkWasAvailable = available;
        if (!recovered) return;
        _debounceTimer?.cancel();
        _debounceTimer = Timer(networkDebounce, () {
          _debounceTimer = null;
          // 断网可能同时打断目标下载与基线下载：恢复后两者各自按退避重试。
          unawaited(controller.ensureBaseline());
          unawaited(_checkIfEnabled());
        });
      });
    }
  }

  void _onTick() {
    if (_disposed) return;
    final state = controller.state;
    if (state.isBusy) return;

    // 退避到点的下载失败优先恢复（规格 §8.4）。
    if (state.nextAttemptUtc != null && controller.orchestrator.canAutoRetry) {
      unawaited(controller.retry());
      return;
    }
    // 基线退避到点也必须自动恢复：否则"回退基线未就绪"会永久残留（INV-08）。
    if (controller.state.target != null &&
        controller.orchestrator.canAutoRetryBaseline) {
      unawaited(controller.ensureBaseline());
    }
    if (!controller.autoUpdateEnabled) return;
    final last =
        controller.orchestrator.state.lastConfirmedUtc ?? state.lastCheckedUtc;
    if (last == null) {
      unawaited(_checkIfEnabled());
      return;
    }
    final elapsed = clock.nowUtc().difference(last);
    if (elapsed.isNegative || elapsed >= minimumCheckInterval) {
      unawaited(_checkIfEnabled());
    }
  }

  Future<void> _checkIfEnabled() async {
    if (_disposed || !controller.autoUpdateEnabled) return;
    final state = controller.state;
    if (state.isBusy) return;
    if (state.phase == UpdatePhase.preparingInstall ||
        state.phase == UpdatePhase.waitingForExit ||
        state.phase == UpdatePhase.installing ||
        state.phase == UpdatePhase.launchingNewVersion ||
        state.phase == UpdatePhase.waitingForHealth) {
      return;
    }
    await controller.checkNow();
  }

  Future<void> dispose() async {
    _disposed = true;
    _startupTimer?.cancel();
    _tickTimer?.cancel();
    _debounceTimer?.cancel();
    _startupTimer = null;
    _tickTimer = null;
    _debounceTimer = null;
    await _networkSubscription?.cancel();
    _networkSubscription = null;
  }
}
