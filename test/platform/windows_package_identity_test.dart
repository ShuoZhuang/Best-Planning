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

  // 以上三条**全部注入假探针**，因此真正的那次 `kernel32` 调用在本机**一个方向都没执行过**
  // （这一条在 §13.0 的 R8 ② 里被登记为"不得计入已验证"）。下面两条把它补上：它们**不注入
  // 探针**，走的是真实的 `DynamicLibrary.open('kernel32.dll')` + `lookupFunction`。
  //
  // **它们能证明什么、不能证明什么**：测试进程本身没有包身份，因此 `GetCurrentPackageFullName`
  // 必然返回 `APPMODULE_ERROR_NO_PACKAGE`——能证明的是**绑定本身可用**（DLL 能打开、符号名正确、
  // 调用约定正确、返回值可读）。**不能**证明的是"有包身份时返回 true"那一支：那需要一个**已安装
  // 的 MSIX**，而签名证书还没有（见 `docs/release/windows-release.md`）。因此这一支仍然是
  // **未验证**，不因为这两条用例而改变。
  test('真实 kernel32 调用可用：非打包进程返回 APPMODEL_ERROR_NO_PACKAGE', () {
    final probe = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Uint32>, Pointer<Utf16>),
          int Function(Pointer<Uint32>, Pointer<Utf16>)
        >('GetCurrentPackageFullName');
    final length = calloc<Uint32>();
    try {
      final result = probe(length, nullptr);
      // 符号名或调用约定写错会在这里抛（`lookupFunction` 找不到符号即抛），而不是静默返回 0，
      // 因此这条断言对"绑定是否真的接上"是有判别力的。
      expect(
        result,
        appModelErrorNoPackage,
        reason:
            '本测试进程未打包，因此必须返回"没有包身份"；'
            '若这里拿到别的值，说明进程被打包了或绑定读错了',
      );
    } finally {
      calloc.free(length);
    }
  });

  test('真实调用路径下返回 false，且探针本身没有失败（不注入探针）', () {
    // 与 `main.dart` 里的用法一致：不传 probe、不传 isWindows。
    //
    // **`onProbeFailure` 那一条断言才是这条用例的价值所在**。第一版只断言"返回 false"，
    // 而把生产代码里的符号名改成 `GetCurrentPackageFullNameX` 之后它**照样通过**——绑定断掉
    // 时异常被 `catch` 吞掉，返回值没有任何变化。也就是说那版用例无法区分"确实没有包身份"
    // 与"探针根本不可用"，属于"不会失败的测试"。现在两者必须分开断言。
    Object? failure;
    final result = hasWindowsPackageIdentity(
      onProbeFailure: (error) => failure = error,
    );

    expect(result, isFalse);
    expect(
      failure,
      isNull,
      reason: '探针失败也会返回 false——不把两者分开，这条用例对"绑定是否真的可用"没有判别力',
    );
  });

  // A①：取真实 AUMID 的那条调用。与上面同一套路——**不注入探针**，让真正的 kernel32 调用执行。
  group('currentApplicationUserModelId', () {
    test('真实调用路径下返回 null，且探针本身没有失败（不注入探针）', () {
      // 测试进程没有包身份，因此 `GetCurrentApplicationUserModelId` 返回
      // APPMODEL_ERROR_NO_PACKAGE，我们把它映射成 null。
      //
      // **判别力说明**：与上面那条同型，`onProbeFailure` 的断言才是关键——符号名或调用约定
      // 写错时异常会被吞掉，返回值同样是 null，只看返回值分不出"确实没有包身份"与"探针不可用"。
      Object? failure;
      final result = currentApplicationUserModelId(
        onProbeFailure: (error) => failure = error,
      );

      expect(result, isNull);
      expect(
        failure,
        isNull,
        reason: '探针失败也会返回 null——不把两者分开，这条用例对"绑定是否真的可用"没有判别力',
      );
    });

    test('非 Windows 平台不调用原生探针', () {
      var probed = false;
      final result = currentApplicationUserModelId(
        isWindows: false,
        probe: (_, _) {
          probed = true;
          return 0;
        },
      );

      expect(result, isNull);
      expect(probed, isFalse);
    });

    test('两段式调用失败时不返回半截结果', () {
      // 第一次给长度、第二次仍不成功：必须返回 null，而不是把未填充的缓冲当成名字。
      var calls = 0;
      final result = currentApplicationUserModelId(
        probe: (length, buffer) {
          calls++;
          if (calls == 1) {
            length.value = 8;
            return 122; // ERROR_INSUFFICIENT_BUFFER
          }
          return 5; // 任意非 0 错误
        },
      );

      expect(result, isNull);
      expect(calls, 2);
    });
  });
}
