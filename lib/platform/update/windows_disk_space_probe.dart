// 磁盘余量探测（规格 §8.5）。
//
// Dart 没有查询卷剩余空间的 API，这里直接调用 Windows 的 `GetDiskFreeSpaceExW`。
// 只读取余量，不修改任何文件；非 Windows 或调用失败时返回 `null`——调用方据此**跳过**
// 预估检查，而不是把"未知"当成"空间不足"或"空间充足"。
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:personal_planner/domain/update/update_ports.dart';

typedef _GetDiskFreeSpaceExWNative = Int32 Function(
  Pointer<Utf16> directoryName,
  Pointer<Uint64> freeBytesAvailable,
  Pointer<Uint64> totalBytes,
  Pointer<Uint64> totalFreeBytes,
);

typedef _GetDiskFreeSpaceExWDart = int Function(
  Pointer<Utf16> directoryName,
  Pointer<Uint64> freeBytesAvailable,
  Pointer<Uint64> totalBytes,
  Pointer<Uint64> totalFreeBytes,
);

final class WindowsDiskSpaceProbe implements DiskSpaceProbe {
  static _GetDiskFreeSpaceExWDart? _cached;

  @override
  Future<int?> availableBytes(String path) async {
    if (!Platform.isWindows) return null;
    try {
      final call = _cached ??= _load();
      final root = _volumeRootFor(path);
      final directory = root.toNativeUtf16();
      final freeForCaller = calloc<Uint64>();
      final total = calloc<Uint64>();
      final totalFree = calloc<Uint64>();
      try {
        final result = call(directory, freeForCaller, total, totalFree);
        if (result == 0) return null;
        // `GetDiskFreeSpaceExW` 的可用空间是 64 位，直接转成 Dart int。
        return freeForCaller.value;
      } finally {
        calloc
          ..free(directory)
          ..free(freeForCaller)
          ..free(total)
          ..free(totalFree);
      }
    } on Object {
      return null;
    }
  }

  static _GetDiskFreeSpaceExWDart _load() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    return kernel32.lookupFunction<_GetDiskFreeSpaceExWNative,
        _GetDiskFreeSpaceExWDart>('GetDiskFreeSpaceExW');
  }

  /// 取盘符根（`C:\`）。没有盘符时返回原路径，交给系统解析。
  static String _volumeRootFor(String path) {
    final match = RegExp(r'^[A-Za-z]:').firstMatch(path);
    if (match == null) return path;
    return '${match.group(0)}${Platform.pathSeparator}';
  }
}
