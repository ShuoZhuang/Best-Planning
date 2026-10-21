// 网络可用性监视（规格 §7.1 的"网络从不可用变为可用"触发）。
//
// 只用本地网络接口列表判断"是否有网络接口"，不做任何联网探测：更新检查本身会给出真实的
// 连接结果，而这个监视器只负责"网络可能恢复了，值得再试一次"这一种触发。
import 'dart:async';
import 'dart:io';

import 'package:personal_planner/domain/update/update_ports.dart';

final class NetworkInterfaceStatusMonitor implements NetworkStatusMonitor {
  NetworkInterfaceStatusMonitor({
    this.pollInterval = const Duration(seconds: 15),
    bool? initialAvailability,
  }) : _available = initialAvailability ?? true {
    _timer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
  }

  final Duration pollInterval;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  Timer? _timer;
  bool _available;
  bool _disposed = false;

  @override
  bool get isAvailable => _available;

  @override
  Stream<bool> get changes => _controller.stream;

  Future<void> _poll() async {
    if (_disposed) return;
    final available = await _detect();
    if (_disposed || available == _available) return;
    _available = available;
    _controller.add(available);
  }

  Future<bool> _detect() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      return interfaces.any((interface) => interface.addresses.isNotEmpty);
    } on Object {
      // 查询失败时保持上一次结论，避免把"查不到"当成"断网"。
      return _available;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _controller.close();
  }
}
