import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/models/window_behavior.dart';
import 'package:personal_planner/platform/windows/window_shell.dart';

/// "关闭窗口时做什么"的读写与应用。
///
/// 设置存在 Dart 侧，宿主窗口只是执行者：这样备份、导出与设置页看到的都是同一份事实，
/// 而原生端不需要自己维护一份持久的偏好。
final class WindowBehaviorService {
  const WindowBehaviorService({required this.settings, required this.shell});

  final SettingsService settings;
  final WindowShell shell;

  Future<WindowCloseBehavior> load() => settings.loadCloseBehavior();

  /// 存下选择并立刻应用，返回宿主窗口对托盘的说明。
  Future<TrayStatus> apply(WindowCloseBehavior behavior) async {
    await settings.saveCloseBehavior(behavior);
    return shell.setCloseBehavior(behavior);
  }

  /// 启动时把**已存的选择**下发给宿主窗口，不写回存储。
  ///
  /// 必须在启动路径上调用：用户可能上次已经把行为设成"收进后台"，若等到他打开设置页才下发，
  /// 那么这次启动里点关闭就会直接退出——与他的设置不符。
  Future<TrayStatus> pushStored() async => shell.setCloseBehavior(await load());
}
