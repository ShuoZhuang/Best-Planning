// 进程身份探测（规格 §12.2 / §15.1）。
//
// 助手判断"主程序是否已经退出"时必须同时核对 **PID 与进程启动时间**：Windows 会复用 PID，
// 只看 PID 会把"另一个进程"当成用户的主程序，从而过早部署。
//
// Dart 没有暴露进程启动时间，这里直接调用 Win32 的 `GetProcessTimes`。
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:personal_planner/domain/update/update_ports.dart';

typedef _OpenProcessNative = IntPtr Function(
  Uint32 desiredAccess,
  Int32 inheritHandle,
  Uint32 processId,
);
typedef _OpenProcessDart = int Function(
  int desiredAccess,
  int inheritHandle,
  int processId,
);

typedef _GetProcessTimesNative = Int32 Function(
  IntPtr process,
  Pointer<_FileTimeStruct> creation,
  Pointer<_FileTimeStruct> exit,
  Pointer<_FileTimeStruct> kernel,
  Pointer<_FileTimeStruct> user,
);
typedef _GetProcessTimesDart = int Function(
  int process,
  Pointer<_FileTimeStruct> creation,
  Pointer<_FileTimeStruct> exit,
  Pointer<_FileTimeStruct> kernel,
  Pointer<_FileTimeStruct> user,
);

typedef _CloseHandleNative = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

final class _FileTimeStruct extends Struct {
  @Uint32()
  external int low;

  @Uint32()
  external int high;
}

const int _processQueryLimitedInformation = 0x1000;

final class WindowsProcessIdentityProbe implements ProcessIdentityProbe {
  static DynamicLibrary? _kernel32;
  static _OpenProcessDart? _openProcess;
  static _GetProcessTimesDart? _getProcessTimes;
  static _CloseHandleDart? _closeHandle;

  static void _ensureLoaded() {
    _kernel32 ??= DynamicLibrary.open('kernel32.dll');
    _openProcess ??= _kernel32!
        .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
    _getProcessTimes ??= _kernel32!
        .lookupFunction<_GetProcessTimesNative, _GetProcessTimesDart>(
          'GetProcessTimes',
        );
    _closeHandle ??= _kernel32!
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
  }

  @override
  Future<ProcessIdentity> current() async {
    final identity = await forPid(pid);
    if (identity == null) {
      throw StateError('无法读取当前进程的启动时间');
    }
    return identity;
  }

  @override
  Future<ProcessIdentity?> forPid(int processId) async {
    if (!Platform.isWindows) return null;
    _ensureLoaded();
    final handle = _openProcess!(_processQueryLimitedInformation, 0, processId);
    if (handle == 0) return null;
    try {
      final creation = calloc<_FileTimeStruct>();
      final exit = calloc<_FileTimeStruct>();
      final kernel = calloc<_FileTimeStruct>();
      final user = calloc<_FileTimeStruct>();
      try {
        final ok = _getProcessTimes!(handle, creation, exit, kernel, user);
        if (ok == 0) return null;
        final ticks = (creation.ref.high & 0xFFFFFFFF) << 32 | creation.ref.low;
        // FILETIME 是自 1601-01-01 起的 100 纳秒数。Dart 的 DateTime 支持该年份范围。
        final started = DateTime.utc(1601)
            .add(Duration(microseconds: ticks ~/ 10));
        return ProcessIdentity(pid: processId, startedAtUtc: started);
      } finally {
        calloc
          ..free(creation)
          ..free(exit)
          ..free(kernel)
          ..free(user);
      }
    } finally {
      _closeHandle!(handle);
    }
  }
}
