// 原子写文件（规格 §9.4：临时文件、刷新磁盘、原子替换）。
//
// 状态文件与清单缓存都是"读的时候必须完整"的文件：如果就地覆盖，写入过程中掉电会留下
// 半份 JSON，而半份 JSON 既不是有效状态也不是有效缓存。这里统一成：
//   · 同目录临时文件（必须同卷，重命名才是原子的）；
//   · 写入、flush、关闭；
//   · `File.rename` 覆盖目标（Windows 上走 `MoveFileEx(MOVEFILE_REPLACE_EXISTING)`）。
//
// **失败不再压扁成一句话**：底层 `FileSystemException` 被包进 [AtomicFileException]，
// 保留操作名、脱敏后的文件名与 `osError.errorCode`，供编排器写进诊断日志；界面仍然只显示
// 稳定文案（规格 §9.2.6、§14.4）。
import 'dart:convert';
import 'dart:io';
import 'dart:math';

final Random _random = Random();

/// 一次落盘失败的可诊断描述。
///
/// [file] 与 [target] 只用于生成**不含完整用户目录**的短标签（例如
/// `Updates/state.json`）：日志要能定位是哪个文件，界面不暴露个人目录。
final class AtomicFileException implements Exception {
  AtomicFileException({
    required this.operation,
    required this.file,
    required this.cause,
    this.target,
  });

  /// `create-directory` / `write` / `flush` / `replace` / `promote`。
  final String operation;
  final File file;
  final File? target;
  final FileSystemException cause;

  int? get osErrorCode => cause.osError?.errorCode;

  /// 单行诊断详情：`op=replace src=Updates/tmp dst=Updates/state.json os=5 msg=...`。
  String get diagnosticDetail {
    final buffer = StringBuffer('op=$operation src=${labelFor(file)}');
    if (target != null) buffer.write(' dst=${labelFor(target!)}');
    final os = cause.osError;
    if (os != null) {
      buffer.write(' os=${os.errorCode}');
      if (os.message.isNotEmpty) {
        buffer.write(' msg=${os.message.replaceAll(RegExp(r'[\r\n\t]'), ' ')}');
      }
    }
    return buffer.toString();
  }

  /// 只保留"父目录名/文件名"两个片段，丢掉盘符与用户目录。
  static String labelFor(File file) {
    final normalized = file.path.replaceAll('\\', '/');
    final segments = normalized
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) return '<empty>';
    if (segments.length == 1) return segments.single;
    return '${segments[segments.length - 2]}/${segments.last}';
  }

  @override
  String toString() => 'AtomicFileException($diagnosticDetail)';
}

/// 原子写入 UTF-8 文本。
Future<void> writeTextAtomically(File file, String contents) async {
  await _writeAtomically(file, (handle) => handle.writeString(contents));
}

/// 原子写入字节（安装包 `.ready` 的最终替换也走这里）。
Future<void> writeBytesAtomically(File file, List<int> bytes) async {
  await _writeAtomically(file, (handle) => handle.writeFrom(bytes));
}

/// 原子写入 JSON。
Future<void> writeJsonAtomically(File file, Object? json) =>
    writeTextAtomically(file, jsonEncode(json));

/// 把已经验证过的 `.partial` 提升为 `.ready`（同目录、原地改名）。
///
/// 失败时源文件**保持原样**：调用方据此保留可恢复的下载结果，下一次启动重新验证后再试，
/// 而不是重新下载（规格 §9.2.5）。
Future<void> promoteVerifiedFile(File source, File target) async {
  try {
    await target.parent.create(recursive: true);
    await source.rename(target.path);
  } on FileSystemException catch (error) {
    throw AtomicFileException(
      operation: 'promote',
      file: source,
      target: target,
      cause: error,
    );
  }
}

Future<void> _writeAtomically(
  File file,
  Future<void> Function(RandomAccessFile handle) write,
) async {
  final directory = file.parent;
  try {
    await directory.create(recursive: true);
  } on FileSystemException catch (error) {
    throw AtomicFileException(
      operation: 'create-directory',
      file: file,
      cause: error,
    );
  }
  final temporary = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.${_random.nextInt(1 << 32)}.tmp',
  );
  RandomAccessFile? handle;
  try {
    try {
      handle = await temporary.open(mode: FileMode.write);
      await write(handle);
      // flush 把进程内缓冲交给操作系统；之后的 rename 在同一卷上是原子的替换。
      await handle.flush();
      await handle.close();
      handle = null;
    } on FileSystemException catch (error) {
      throw AtomicFileException(
        operation: 'write',
        file: temporary,
        cause: error,
      );
    }
    try {
      await temporary.rename(file.path);
    } on FileSystemException catch (error) {
      throw AtomicFileException(
        operation: 'replace',
        file: temporary,
        target: file,
        cause: error,
      );
    }
  } on Object {
    // 只清理**本次**临时文件；目标文件与最后一份有效内容保持原样（规格 §9.2.4）。
    if (handle != null) {
      try {
        await handle.close();
      } on Object {
        // 关闭失败不改变"这次写入失败"的结论。
      }
    }
    try {
      if (await temporary.exists()) await temporary.delete();
    } on Object {
      // 临时文件删不掉时留给下一次覆盖；不影响失败结论。
    }
    rethrow;
  }
}

/// 读 JSON；文件不存在、读失败或不是合法 JSON 时返回 `null`。
///
/// **不抛异常**：状态与缓存都是"坏了就重建"的线索，而不是必须让应用起不来的东西。
Future<Object?> readJsonOrNull(File file) async {
  try {
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString());
  } on Object {
    return null;
  }
}
