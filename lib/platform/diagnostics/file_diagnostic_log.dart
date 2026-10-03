import 'dart:io';

/// 把诊断写到文件的最小实现。
///
/// **存在的理由是一件具体的事**：Release 构建里此前**没有任何可查的线索**。`debugPrint` 在打包后
/// 的 Windows 应用里抓不到（实测：把包内进程的 stdout 重定向到文件，只拿到引擎那行 Impeller
/// 输出，Dart 侧一行都没有）。后果是"提醒同步失败"这类被 `catch` 吞掉的错误完全不为人知——
/// 用户看到的只是"通知不弹"，而排查的人连一行日志都拿不到。
///
/// 三条刻意的取舍：
/// - **绝不抛异常**。诊断写失败（磁盘满、权限、路径被占）不该让主流程崩——那样"为了可观测"
///   反而制造了一个新的失败点。写失败只置一个标志，`failed` 可供上层查。
/// - **有上限**。日志追加到固定大小后从头截断，避免长期运行把磁盘写满；诊断不需要无限历史。
/// - **只追加**。不做轮转、不做多文件，够用即可。
final class FileDiagnosticLog {
  FileDiagnosticLog(
    this.path, {
    DateTime Function()? now,
    this.maxBytes = 64 * 1024,
  }) : _now = now ?? DateTime.now;

  final String path;
  final int maxBytes;
  final DateTime Function() _now;

  /// 曾经写失败过。**供上层决定要不要提示用户**，而不是让写失败静默消失。
  bool failed = false;

  void write(String message) {
    try {
      final file = File(path);
      final stamp = _now().toIso8601String();
      final line = '[$stamp] $message\n';

      if (file.existsSync() && file.lengthSync() > maxBytes) {
        // 截断到最近的尾部：保留后半段，够看清"刚才发生了什么"。
        final existing = file.readAsStringSync();
        final half = existing.length ~/ 2;
        file.writeAsStringSync(
          '--- 日志超过 $maxBytes 字节，已截断较早内容 ---\n'
          '${existing.substring(half)}',
        );
      }
      file.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } on Object {
      // 见类文档：诊断失败不得影响主流程。
      failed = true;
    }
  }
}
