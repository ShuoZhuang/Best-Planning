// 更新助手的启动前复制（2026-10-18 应用内更新 0x80073D02 的回归测试）。
//
// 真实故障：助手从 `WindowsApps` 包目录启动，自己占住包文件，Windows 以
// ERROR_PACKAGES_IN_USE 拒绝原位升级。这里守住“启动前复制到包外”的行为。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';
import 'package:personal_planner/platform/update/windows_update_helper.dart';

void main() {
  late Directory temp;
  late Directory packageDir;
  late File helperInPackage;
  late WindowsUpdateHelper helper;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('planner-helper-test-');
    packageDir = Directory('${temp.path}${Platform.pathSeparator}WindowsApps')
      ..createSync(recursive: true);
    helperInPackage = File(
      '${packageDir.path}${Platform.pathSeparator}update_helper.exe',
    )..writeAsBytesSync(List<int>.generate(2048, (index) => index % 251));
    helper = WindowsUpdateHelper(
      layout: UpdateStorageLayout.fromResolvedRoot(
        '${temp.path}${Platform.pathSeparator}updates',
      ),
      helperPath: helperInPackage.path,
    );
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  test('启动前把助手复制到包目录之外，且字节数一致', () async {
    final staged = await helper.stageHelperForLaunch();

    expect(staged, isNot(helperInPackage.path));
    expect(
      staged.startsWith(packageDir.path),
      isFalse,
      reason: '复制目标不能在包目录内，否则部署仍会被判为“包正在使用”',
    );
    final copy = File(staged);
    expect(copy.existsSync(), isTrue);
    expect(copy.lengthSync(), helperInPackage.lengthSync());

    final parent = Directory(staged).parent;
    if (parent.existsSync()) await parent.delete(recursive: true);
  });

  test('同一实例重复准备返回同一份副本', () async {
    final first = await helper.stageHelperForLaunch();
    final second = await helper.stageHelperForLaunch();

    expect(second, first);
    final parent = Directory(first).parent;
    if (parent.existsSync()) await parent.delete(recursive: true);
  });

  test('源助手不存在时不复制，交给启动前的 exists 检查处理', () async {
    final missing = WindowsUpdateHelper(
      layout: UpdateStorageLayout.fromResolvedRoot(
        '${temp.path}${Platform.pathSeparator}updates',
      ),
      helperPath:
          '${temp.path}${Platform.pathSeparator}WindowsApps${Platform.pathSeparator}missing.exe',
    );

    expect(
      await missing.stageHelperForLaunch(),
      missing.helperPath,
    );
  });
}
