// A①②：通知点击的激活靠两处配置，而两处都可能悄悄漂移。
//
// 背景（实测证据见 `docs/testing/flow-verification.md` 第九节）：点通知"窗口到了前台但不跳转"，
// 根因是**传给插件的 AUMID 与打包身份不符**——插件的激活器写在传入的 AUMID 下，而打包应用发
// 出的 toast 带的是包身份 AUMID，Windows 因此找不到激活器，退化成"按 AUMID 直接启动应用"。
//
// 本文件守两类不变量：
//   ① **代码里的激活器 GUID 必须与 `pubspec.yaml` 清单里声明的一致**（跨文件一致性，最容易漂移）；
//   ② **AUMID 的取值策略**：给了真实值就必须用它；没给才回退，且回退只对免安装 EXE 成立。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/platform/notifications/windows_notification_adapter.dart';

void main() {
  test('清单里声明的激活器 CLSID 与代码里的 GUID 一致', () {
    final pubspec = File('pubspec.yaml');
    expect(
      pubspec.existsSync(),
      isTrue,
      reason: '读不到 pubspec.yaml——测试的工作目录应当就是包根目录',
    );
    final lines = pubspec.readAsLinesSync();

    // 只取 `msix_config.toast_activator.clsid`。用"先找到 toast_activator、再在其缩进更深的
    // 子行里找 clsid"的解析方式，而不是全局搜 `clsid:`——将来别处也可能出现同名键。
    String? clsid;
    var insideActivator = false;
    for (final line in lines) {
      if (RegExp(r'^\s{2}toast_activator:\s*$').hasMatch(line)) {
        insideActivator = true;
        continue;
      }
      if (!insideActivator) continue;
      // 缩进回到 2 空格即离开该段。
      if (RegExp(r'^\s{2}\S').hasMatch(line)) break;
      final match = RegExp(r'^\s{4}clsid:\s*(\S+)').firstMatch(line);
      if (match != null) {
        clsid = match.group(1);
        break;
      }
    }

    // **防空跑**：解析逻辑写错时 `clsid` 会是 null，下面的断言会"以另一种方式"失败，
    // 所以这里先明确它在。
    expect(
      clsid,
      isNotNull,
      reason: '没有从 pubspec.yaml 的 msix_config.toast_activator 里解析出 clsid',
    );
    expect(
      clsid,
      FlutterWindowsNotificationBackend.activatorGuid,
      reason: '清单里的 ToastActivatorCLSID 与插件注册的 GUID 必须完全一致，'
          '否则 Windows 找到的激活器与实际注册的不是同一个，点击依旧不生效',
    );
  });

  group('AUMID 取值策略（A①）', () {
    test('给了真实 AUMID 就用它，绝不用回退常量', () {
      const real = 'ShuoZhuang.PersonalPlanner_v9555qkaxdyym!personalplanner';
      final backend = FlutterWindowsNotificationBackend(appUserModelId: real);

      expect(backend.effectiveAppUserModelId, real);
      expect(
        backend.effectiveAppUserModelId,
        isNot(FlutterWindowsNotificationBackend.fallbackAppUserModelId),
        reason: '打包进程用回退常量会让激活器写在错误的 AUMID 下',
      );
    });

    test('没有真实 AUMID 时才回退（只对免安装 EXE 成立）', () {
      final backend = FlutterWindowsNotificationBackend();

      expect(
        backend.effectiveAppUserModelId,
        FlutterWindowsNotificationBackend.fallbackAppUserModelId,
      );
      // 反向确认两者的**形态**就不同：打包身份 AUMID 一定含 `!`（`<包族名>!<应用Id>`），
      // 而回退常量不含。因此"打包了却回退"必然不匹配——这正是组合根要记诊断的那种状态。
      expect(
        FlutterWindowsNotificationBackend.fallbackAppUserModelId.contains('!'),
        isFalse,
      );
    });
  });
}
