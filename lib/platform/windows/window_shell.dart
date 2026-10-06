import 'package:flutter/services.dart';
import 'package:personal_planner/domain/models/window_behavior.dart';

/// 宿主窗口对托盘图标的回答。
///
/// `detail` 是原样带回来的原因（`ok` / `icon_load_failed` / `shell_add_failed:<errno>` /
/// `not_created`）：托盘建不出来时用户看到的现象只是"关闭窗口把程序关了"，没有原因就无从排查。
final class TrayStatus {
  const TrayStatus({required this.available, required this.detail});

  /// 设置未能到达宿主窗口时（非 Windows 宿主、通道缺失）的取值。
  static const unavailable = TrayStatus(
    available: false,
    detail: 'channel_unavailable',
  );

  final bool available;
  final String detail;
}

/// 把窗口行为交给宿主窗口（Windows runner）。
///
/// 是一个端口而不是直接调通道：调用点在应用层，那里不该认识 `MethodChannel`，测试也就不必
/// 假装自己是 Flutter 引擎。
abstract interface class WindowShell {
  /// 应用"关闭窗口时做什么"，并回答托盘图标是否真的可用。
  ///
  /// 不可用时"收进后台"不会生效（收起来就再也找不回来），因此界面必须如实告知，而不是让
  /// 用户以为设置成功了。
  Future<TrayStatus> setCloseBehavior(WindowCloseBehavior behavior);
}

/// 走 `personal_planner/window` 通道的真实实现。
final class MethodChannelWindowShell implements WindowShell {
  const MethodChannelWindowShell({
    this.channel = const MethodChannel('personal_planner/window'),
  });

  final MethodChannel channel;

  @override
  Future<TrayStatus> setCloseBehavior(WindowCloseBehavior behavior) async {
    try {
      final reply = await channel.invokeMethod<Object?>('setCloseBehavior', {
        'minimizeToTray': behavior == WindowCloseBehavior.minimizeToTray,
      });
      if (reply is Map) {
        return TrayStatus(
          available: reply['available'] == true,
          detail: reply['status']?.toString() ?? 'unknown',
        );
      }
      return TrayStatus.unavailable;
    } on MissingPluginException {
      // 非 Windows 宿主（或测试里没有原生端）：如实回答"托盘不可用"，而不是抛给调用方。
      return TrayStatus.unavailable;
    } on PlatformException catch (error) {
      return TrayStatus(
        available: false,
        detail: 'platform_error:${error.code}',
      );
    }
  }
}
