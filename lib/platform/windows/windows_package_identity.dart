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
bool hasWindowsPackageIdentity({PackageFullNameProbe? probe, bool? isWindows}) {
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
  } on Object {
    return false;
  }
}
