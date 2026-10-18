// 更新目录布局（规格 §8.1）。
//
// **路径只能由本地版本构造**，不能把远端字符串直接拼进目录名：清单里的 `fileName` 是远端
// 可控输入，如果它参与路径，`../` 就能把文件写到更新目录之外。这里所有路径都由
// `MsixVersion` 或固定文件名生成，远端文件名只作为"期望值"参与校验。
import 'dart:io';

import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';

final class UpdateStorageLayout {
  UpdateStorageLayout({required this.root});

  /// 由 `WindowsUpdateStorage` 解析出的根构造。
  ///
  /// [resolvedRoot] 已经包含一次 `BestPlanning\Updates`，这里**不再追加**，避免出现
  /// `Updates\BestPlanning\Updates` 这样的双层目录。
  factory UpdateStorageLayout.fromResolvedRoot(String resolvedRoot) =>
      UpdateStorageLayout(root: Directory(resolvedRoot));

  /// `%LOCALAPPDATA%\BestPlanning\Updates\`。
  ///
  /// **只用于未打包的便携版、纯 Dart 测试与旧目录迁移**。已安装的 MSIX 必须走
  /// `WindowsUpdateStorage.resolveRoot()`，否则写入会被文件系统重定向到受保护目录
  /// （实施计划 §9.2.1）。
  factory UpdateStorageLayout.localAppData({
    String? localAppData,
    String productDirectory = 'BestPlanning',
  }) {
    final base = localAppData ??
        Platform.environment['LOCALAPPDATA'] ??
        Directory.systemTemp.path;
    return UpdateStorageLayout(
      root: Directory(
        [base, productDirectory, 'Updates'].join(Platform.pathSeparator),
      ),
    );
  }

  final Directory root;

  Directory get logsDirectory =>
      Directory('${root.path}${Platform.pathSeparator}logs');

  File get stateFile => File('${root.path}${Platform.pathSeparator}state.json');

  String get _separator => Platform.pathSeparator;

  Directory versionDirectory(MsixVersion version) =>
      Directory('${root.path}$_separator${version.value}');

  File manifestCopy(MsixVersion version) => File(
    '${versionDirectory(version).path}${_separator}update-manifest.json',
  );

  File partialPackage(UpdateTarget target) => File(
    '${versionDirectory(target.msixVersion).path}${_separator}package.msix.partial',
  );

  File readyPackage(UpdateTarget target) => File(
    '${versionDirectory(target.msixVersion).path}${_separator}package.msix.ready',
  );

  File requestFile(MsixVersion version) => File(
    '${versionDirectory(version).path}${_separator}update-request.json',
  );

  File helperStatusFile(MsixVersion version) => File(
    '${versionDirectory(version).path}${_separator}helper-status.json',
  );

  File healthConfirmationFile(MsixVersion version) => File(
    '${versionDirectory(version).path}${_separator}health-confirmation.json',
  );

  Directory get baselineDirectory =>
      Directory('${root.path}${_separator}baseline');

  File baselinePackage(MsixVersion version) => File(
    '${baselineDirectory.path}$_separator'
    'BestPlanning_${version.value}_x64.msix',
  );

  File get snapshotFile =>
      File('${root.path}${_separator}pre-update-snapshot.zip');

  /// 规范路径（绝对、去掉 `.`/`..`、统一分隔符）。助手用它判断"包是否在更新目录内"。
  static String normalize(String path) {
    final absolute = File(path).absolute.path;
    final parts = <String>[];
    for (final segment in absolute.split(RegExp(r'[\\/]+'))) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(segment);
    }
    final joined = parts.join(Platform.pathSeparator);
    // Windows 盘符根（`C:`）需要补回尾部反斜杠，否则会变成相对路径。
    return joined.endsWith(':') ? '$joined${Platform.pathSeparator}' : joined;
  }

  /// `path` 是否位于 [root] 之下（规范化后按目录边界比较）。
  bool containsPath(String path) {
    final normalizedRoot = normalize(root.path);
    final normalizedPath = normalize(path);
    final rootWithSeparator = normalizedRoot.endsWith(Platform.pathSeparator)
        ? normalizedRoot
        : '$normalizedRoot${Platform.pathSeparator}';
    return normalizedPath != normalizedRoot &&
        normalizedPath.startsWith(rootWithSeparator);
  }
}

