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

typedef ApplicationUserModelIdProbe = int Function(
  Pointer<Uint32> applicationUserModelIdLength,
  Pointer<Utf16> applicationUserModelId,
);

typedef _NativeApplicationUserModelIdProbe = Int32 Function(
  Pointer<Uint32>,
  Pointer<Utf16>,
);

/// 当前进程的 **AUMID**（形如 `<PackageFamilyName>!<ApplicationId>`）；无包身份或探针不可用时
/// 返回 `null`。
///
/// **为什么必须取真实值而不是写死一个常量**：通知点击的激活链路完全依赖它。插件的做法是把
/// `CustomActivator={guid}` 写到 `HKCU\Software\Classes\AppUserModelId\<传入的 aumid>` 下，并把
/// COM 类对象注册进当前进程；而**打包应用的 toast 带的是包身份 AUMID**，Windows 会去查那个
/// AUMID 下的激活器。两者不符时 Windows 查不到激活器，就退化成"按 AUMID 直接启动应用"——
/// **新起一个进程、不带任何激活负载**，于是点通知只会把窗口带到前台、落在默认页面。
/// 这条是实测出来的，证据链见 `docs/testing/flow-verification.md` 第九节。
///
/// 用 `GetCurrentApplicationUserModelId` 一次拿到完整的 AUMID——**不必自己去拼**包族名
/// （含发布者哈希、会随签名证书变化）与应用 Id，也就不会拼错。
///
/// 与 [hasWindowsPackageIdentity] 同一分工：[onProbeFailure] 用来区分"确实没有包身份"与"探针
/// 不可用"——两者的返回值都是 `null`，但含义完全不同。
String? currentApplicationUserModelId({
  ApplicationUserModelIdProbe? probe,
  bool? isWindows,
  void Function(Object error)? onProbeFailure,
}) {
  if (!(isWindows ?? Platform.isWindows)) return null;

  try {
    final nativeProbe =
        probe ??
        DynamicLibrary.open('kernel32.dll')
            .lookupFunction<
              _NativeApplicationUserModelIdProbe,
              ApplicationUserModelIdProbe
            >('GetCurrentApplicationUserModelId');
    final length = calloc<Uint32>();
    try {
      final firstResult = nativeProbe(length, nullptr);
      if (firstResult == appModelErrorNoPackage) return null;
      if (firstResult != errorInsufficientBuffer || length.value == 0) {
        return null;
      }

      final name = calloc<Uint16>(length.value).cast<Utf16>();
      try {
        if (nativeProbe(length, name) != errorSuccess) return null;
        final value = name.toDartString();
        return value.isEmpty ? null : value;
      } finally {
        calloc.free(name);
      }
    } finally {
      calloc.free(length);
    }
  } on Object catch (error) {
    onProbeFailure?.call(error);
    return null;
  }
}
