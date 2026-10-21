// 更新日志（规格 §14.4）。
//
// 约束三条：
//   · 单个文件不超过 2 MB，最多 5 个轮转文件；
//   · **不记录业务内容或敏感信息**——调用方只传结构化错误或显式的安全行；
//   · 清除日志不得删除安装包、回退包或快照（所以日志单独一个目录）。
import 'dart:io';

import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';

final class FileUpdateLogStore implements UpdateLogSink {
  FileUpdateLogStore({
    required this.directory,
    this.maxBytesPerFile = 2 * 1024 * 1024,
    this.maxFiles = 5,
    DateTime Function()? nowUtc,
  }) : _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final Directory directory;
  final int maxBytesPerFile;
  final int maxFiles;
  final DateTime Function() _nowUtc;

  File get logFile =>
      File('${directory.path}${Platform.pathSeparator}update.log');

  @override
  void write(UpdateFailure failure) {
    writeLine(failure.diagnosticLine);
  }

  @override
  void writeLine(String line) {
    final cleaned = _sanitize(line);
    if (cleaned.isEmpty) return;
    final stamped =
        '${_nowUtc().toIso8601String()} $cleaned${Platform.lineTerminator}';
    try {
      directory.createSync(recursive: true);
      final file = logFile;
      final existing = file.existsSync() ? file.lengthSync() : 0;
      if (existing > 0 && existing + stamped.length > maxBytesPerFile) {
        _rotate();
      }
      file.writeAsStringSync(stamped, mode: FileMode.append, flush: true);
    } on Object {
      // 日志失败绝不能影响更新本身。
    }
  }

  void _rotate() {
    // `update.log` → `.1` → `.2` …；超过 [maxFiles] 的最旧文件被删除。
    for (var index = maxFiles - 1; index >= 1; index--) {
      final source = _rotatedFile(index);
      final target = _rotatedFile(index + 1);
      if (!source.existsSync()) continue;
      if (target.existsSync()) target.deleteSync();
      source.renameSync(target.path);
    }
    final current = logFile;
    if (current.existsSync()) {
      final first = _rotatedFile(1);
      if (first.existsSync()) first.deleteSync();
      current.renameSync(first.path);
    }
  }

  File _rotatedFile(int index) =>
      File('${directory.path}${Platform.pathSeparator}update.log.$index');

  @override
  Future<List<String>> readRecent({int maxLines = 200}) async {
    final lines = <String>[];
    // 从最旧的轮转文件读到最新的，保证时间顺序。
    for (var index = maxFiles; index >= 1; index--) {
      final file = _rotatedFile(index);
      if (await file.exists()) {
        lines.addAll(_tail(await file.readAsLines(), maxLines));
      }
    }
    if (await logFile.exists()) {
      lines.addAll(_tail(await logFile.readAsLines(), maxLines));
    }
    if (lines.length > maxLines) {
      return lines.sublist(lines.length - maxLines);
    }
    return lines;
  }

  static List<String> _tail(List<String> lines, int maxLines) =>
      lines.length <= maxLines ? lines : lines.sublist(lines.length - maxLines);

  @override
  Future<void> clear() async {
    for (var index = 1; index <= maxFiles; index++) {
      final file = _rotatedFile(index);
      if (await file.exists()) await file.delete();
    }
    if (await logFile.exists()) await logFile.delete();
  }

  /// 去掉换行与常见敏感字段。
  ///
  /// **这是第二道防线**：调用方本就不该传入业务内容；但日志函数被到处调用时，一行
  /// `token=...` 迟早会出现，因此这里把它们替换成占位符。
  static String _sanitize(String line) {
    var cleaned = line.replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
    cleaned = cleaned.replaceAllMapped(
      RegExp(
        // 从关键字一路抹到行尾：`Authorization: Bearer <token>` 里的令牌并不与关键字相邻，
        // 只替换"关键字后的一个词"会把它留在日志里。
        r'\b(token|authorization|cookie|password)\s*[=:]\s*.*$',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}=<redacted>',
    );
    return cleaned;
  }
}
