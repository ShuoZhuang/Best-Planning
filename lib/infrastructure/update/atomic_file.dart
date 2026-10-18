// 原子写文件（规格 §9.4：临时文件、刷新磁盘、原子替换）。
//
// 状态文件与清单缓存都是"读的时候必须完整"的文件：如果就地覆盖，写入过程中掉电会留下
// 半份 JSON，而半份 JSON 既不是有效状态也不是有效缓存。这里统一成：
//   · 同目录临时文件（必须同卷，重命名才是原子的）；
//   · 写入、flush、关闭；
//   · `File.rename` 覆盖目标（Windows 上走 `MoveFileEx(MOVEFILE_REPLACE_EXISTING)`）。
import 'dart:convert';
import 'dart:io';
import 'dart:math';

final Random _random = Random();

/// 原子写入 UTF-8 文本。
Future<void> writeTextAtomically(File file, String contents) async {
  final directory = file.parent;
  await directory.create(recursive: true);
  final temporary = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.${_random.nextInt(1 << 32)}.tmp',
  );
  RandomAccessFile? handle;
  try {
    handle = await temporary.open(mode: FileMode.write);
    await handle.writeString(contents);
    // flush 把进程内缓冲交给操作系统；之后的 rename 在同一卷上是原子的替换。
    await handle.flush();
    await handle.close();
    handle = null;
    await temporary.rename(file.path);
  } on Object {
    await handle?.close();
    if (await temporary.exists()) {
      await temporary.delete();
    }
    rethrow;
  }
}

/// 原子写入字节（安装包 `.ready` 的最终替换也走这里）。
Future<void> writeBytesAtomically(File file, List<int> bytes) async {
  final directory = file.parent;
  await directory.create(recursive: true);
  final temporary = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.${_random.nextInt(1 << 32)}.tmp',
  );
  RandomAccessFile? handle;
  try {
    handle = await temporary.open(mode: FileMode.write);
    await handle.writeFrom(bytes);
    await handle.flush();
    await handle.close();
    handle = null;
    await temporary.rename(file.path);
  } on Object {
    await handle?.close();
    if (await temporary.exists()) {
      await temporary.delete();
    }
    rethrow;
  }
}

/// 原子写入 JSON。
Future<void> writeJsonAtomically(File file, Object? json) =>
    writeTextAtomically(file, jsonEncode(json));

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
