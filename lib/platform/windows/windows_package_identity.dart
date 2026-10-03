import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const errorSuccess = 0;
const errorInsufficientBuffer = 122;
const appModelErrorNoPackage = 15700;

typedef PackageFullNameProbe = int Function(
  Pointer<Uint32> packageFullNameLength,
  Pointer<Utf16> packageFullName,
);

typedef _NativePackageFullNameProbe = Int32 Function(
  Pointer<Uint32>,
  Pointer<Utf16>,
);

/// Reports whether the current Windows process has an MSIX package identity.
///
/// `GetCurrentPackageFullName` returns `APPMODEL_ERROR_NO_PACKAGE` for the
/// portable EXE. A packaged process uses the documented two-call buffer flow.
/// Any unexpected platform error degrades to `false` so notification startup
/// remains non-fatal and never claims reliable cancellation without evidence.
///
/// [onProbeFailure] 把"探针**不可用**"与"确实**没有**包身份"区分开。两者的返回值都是
/// `false`，但含义完全不同：前者是需要排查的环境问题（DLL 打不开、符号名写错、调用约定不对），
/// 后者是这个未打包进程的正常状态。**只返回 `false` 会让这两种情况长得一模一样**——本文件的
/// 用例一度因此失去判别力：把符号名改成 `GetCurrentPackageFullNameX`，"真实调用"那条用例
/// **照过不误**，因为异常被 `catch` 吞掉之后返回值没有任何变化。加上这个回调，那条用例才真的
/// 能发现绑定断掉，组合根也才有东西可记进诊断。
bool hasWindowsPackageIdentity({
  PackageFullNameProbe? probe,
  bool? isWindows,
  void Function(Object error)? onProbeFailure,
}) {
  if (!(isWindows ?? Platform.isWindows)) return false;

  try {
    final nativeProbe =
        probe ??
        DynamicLibrary.open('kernel32.dll')
            .lookupFunction<_NativePackageFullNameProbe, PackageFullNameProbe>(
              'GetCurrentPackageFullName',
            );
    final length = calloc<Uint32>();
    try {
      final firstResult = nativeProbe(length, nullptr);
      if (firstResult == appModelErrorNoPackage) return false;
      if (firstResult != errorInsufficientBuffer || length.value == 0) {
        return false;
      }

      final name = calloc<Uint16>(length.value).cast<Utf16>();
      try {
        return nativeProbe(length, name) == errorSuccess;
      } finally {
        calloc.free(name);
      }
    } finally {
      calloc.free(length);
    }
  } on Object catch (error) {
    onProbeFailure?.call(error);
    return false;
  }
}
