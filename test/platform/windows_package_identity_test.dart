import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/platform/windows/windows_package_identity.dart';

void main() {
  test('没有 Windows 包身份时返回 false', () {
    final result = hasWindowsPackageIdentity(
      isWindows: true,
      probe: (length, name) => appModelErrorNoPackage,
    );

    expect(result, isFalse);
  });

  test('GetCurrentPackageFullName 两阶段调用成功时返回 true', () {
    var calls = 0;
    final result = hasWindowsPackageIdentity(
      isWindows: true,
      probe: (length, name) {
        calls++;
        if (name == nullptr) {
          length.value = 32;
          return errorInsufficientBuffer;
        }
        return errorSuccess;
      },
    );

    expect(result, isTrue);
    expect(calls, 2);
  });

  test('非 Windows 平台不调用原生探针', () {
    var called = false;
    final result = hasWindowsPackageIdentity(
      isWindows: false,
      probe: (Pointer<Uint32> length, Pointer<Utf16> name) {
        called = true;
        return errorSuccess;
      },
    );

    expect(result, isFalse);
    expect(called, isFalse);
  });
}
