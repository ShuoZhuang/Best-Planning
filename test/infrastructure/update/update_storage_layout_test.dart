// 更新目录布局（实施计划 §9.4）。
//
// 重点只有一条：解析出来的根**已经**包含一次 `BestPlanning\Updates`，布局不能再次追加。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

void main() {
  final separator = Platform.pathSeparator;
  String join(List<String> parts) => parts.join(separator);

  test('已解析的根不再追加第二层 BestPlanning\\Updates', () {
    final resolved = join([
      'C:',
      'Users',
      'tester',
      'AppData',
      'Local',
      'Packages',
      'Pkg',
      'LocalCache',
      'BestPlanning',
      'Updates',
    ]);

    final layout = UpdateStorageLayout.fromResolvedRoot(resolved);

    expect(layout.root.path, resolved);
    expect(
      layout.stateFile.path,
      join([resolved, 'state.json']),
      reason: 'state.json 必须直接位于解析出的根下',
    );
    expect('BestPlanning'.allMatches(layout.stateFile.path), hasLength(1));
  });

  test('未打包回退路径只追加一次', () {
    final base = join(['C:', 'Users', 'tester', 'AppData', 'Local']);
    final layout = UpdateStorageLayout.localAppData(localAppData: base);

    expect(layout.root.path, join([base, 'BestPlanning', 'Updates']));
    expect('Updates'.allMatches(layout.root.path), hasLength(1));
  });

  test('路径包含关系按目录边界判断', () {
    final root = join(['C:', 'Temp', 'Updates']);
    final layout = UpdateStorageLayout.fromResolvedRoot(root);

    expect(
      layout.containsPath(join([root, '1.10.0.0', 'package.msix.ready'])),
      isTrue,
    );
    expect(layout.containsPath(join([root, '..', 'evil.msix'])), isFalse);
    expect(layout.containsPath(join(['C:', 'Temp', 'Updates2', 'x'])), isFalse);
  });

  test('版本目录与包文件名由本地版本生成', () {
    final root = join(['C:', 'Temp', 'Updates']);
    final layout = UpdateStorageLayout.fromResolvedRoot(root);
    const version = MsixVersion(1, 10, 0, 0);
    final target = UpdateTarget(
      version: const SemVer(1, 10, 0),
      buildNumber: 47,
      tag: 'v1.10.0',
      msixVersion: version,
      fileName: 'BestPlanning_1.10.0.0_x64.msix',
      downloadUrl: 'https://example.com/BestPlanning_1.10.0.0_x64.msix',
      sizeBytes: 1,
      sha256: 'a' * 64,
      manifestDigest: 'b' * 64,
      keyId: 'test-key',
    );

    expect(
      layout.readyPackage(target).path,
      endsWith(join(['1.10.0.0', 'package.msix.ready'])),
    );
    expect(
      layout.partialPackage(target).path,
      endsWith(join(['1.10.0.0', 'package.msix.partial'])),
    );
  });
}
