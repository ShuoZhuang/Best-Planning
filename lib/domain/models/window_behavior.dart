/// 关闭主窗口时应用该做什么。
///
/// 放在 domain 而不是平台层：它是一条**用户设置**，要被设置存储、设置界面与平台端口三处
/// 共用；放进平台层会让前两者反向依赖平台细节。
enum WindowCloseBehavior {
  /// 隐藏窗口，进程继续在后台运行（托盘图标可找回窗口，右键可退出）。
  ///
  /// 这是默认值：用户要求的常态就是"关掉窗口等于收进后台"，排程与提醒继续跑。
  minimizeToTray('最小化到后台运行'),

  /// 关闭窗口即结束进程。
  quit('直接退出程序');

  const WindowCloseBehavior(this.label);

  /// 设置界面上显示的名字。
  final String label;

  /// 解析持久化的值。**未知值一律退回默认（收进后台）而不是抛异常**：这个键是用户可手改的
  /// 存储项，读到一个不认识的值时，能开机的默认值比启动失败有用。
  static WindowCloseBehavior fromStorage(String? value) {
    for (final behavior in WindowCloseBehavior.values) {
      if (behavior.name == value) return behavior;
    }
    return WindowCloseBehavior.minimizeToTray;
  }
}
