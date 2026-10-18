// 当前安装包与 Windows 构建的事实来源（规格 §5.3 的"唯一事实源"）。
//
// `package_info_plus` 只知道 Flutter 版本，不知道包身份、发布者与包族名；这些只能由
// Windows 包身份给出。因此主程序通过助手的 `--probe` 读取，而不是从 `pubspec.yaml` 猜。
import 'dart:io';

import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/platform/update/windows_update_helper.dart';

final class WindowsInstalledPackageProvider implements InstalledPackageProvider {
  const WindowsInstalledPackageProvider(this.helper);

  final WindowsUpdateHelper helper;

  @override
  Future<InstalledPackage?> current() async {
    final probe = await helper.probe();
    return probe?.installedPackage;
  }
}

/// 读取当前 Windows 构建。用于与清单的 `compatibility.minimumWindowsBuild` 比较。
final class WindowsBuildProbe {
  const WindowsBuildProbe();

  Future<MsixVersion?> current() async {
    if (!Platform.isWindows) return null;
    // Dart 在 Windows 上给出的形如 `Windows 10.0.22631`；取三段并补第四段 0。
    final match = RegExp(
      r'(\d+)\.(\d+)\.(\d+)',
    ).firstMatch(Platform.operatingSystemVersion);
    if (match == null) return null;
    final parts = [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      0,
    ];
    return MsixVersion(parts[0], parts[1], parts[2], parts[3]);
  }
}
