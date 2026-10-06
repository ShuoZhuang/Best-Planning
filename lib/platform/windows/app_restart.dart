import 'dart:io';

/// 重启应用：启动一个自身的新进程，然后退出当前进程。
///
/// **为什么必须真的重启**：备份恢复与数据清除都只在**下次启动**、没有活动数据库连接的时候
/// 生效。如果只是关掉界面或刷新页面，用户点完"现在重启"仍会看到旧数据，进而以为操作没成功。
///
/// 用 `Platform.resolvedExecutable`：便携版与打包版下它都是当前正在运行的 exe 路径，
/// 因此不需要知道安装形态。`detached` 让新进程独立于当前进程存活——当前进程紧接着就退出，
/// 不 detached 的子进程会随父进程一起被回收。
Future<void> restartApp() async {
  final executable = Platform.resolvedExecutable;
  await Process.start(
    executable,
    const <String>[],
    workingDirectory: File(executable).parent.path,
    mode: ProcessStartMode.detached,
  );
  exit(0);
}
