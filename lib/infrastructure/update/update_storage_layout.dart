// 更新目录布局（规格 §8.1）。
//
// **路径只能由本地版本构造**，不能把远端字符串直接拼进目录名：清单里的 `fileName` 是远端
// 可控输入，如果它参与路径，`../` 就能把文件写到更新目录之外。这里所有路径都由
// `MsixVersion` 或固定文件名生成，远端文件名只作为"期望值"参与校验。
import 'dart:io';

import 'package:personal_planner/domain/update/manifest_request_key.dart';
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
    final base =
        localAppData ??
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

  // ── 清单缓存（按请求身份分区）──────────────────────────────────────────────
  //
  // 1.11.0 及更早版本只有一份 `update-manifest.cache.json`，latest 与 tag 共用它——
  // 这正是"已是最新版"误报的根因。1.11.1 起每个请求身份一个文件。

  Directory get manifestsDirectory =>
      Directory('${root.path}${_separator}manifests');

  Directory get manifestTagsDirectory =>
      Directory('${manifestsDirectory.path}${_separator}tags');

  /// 某个请求身份的缓存文件。路径**只由枚举与已验证 tag 生成**。
  File manifestCacheFile(ManifestRequestKey key) => File(
    '${root.path}$_separator'
    '${key.relativePath.replaceAll('/', _separator)}',
  );

  /// 旧版全局缓存：1.11.1 首次启动时隔离，绝不把它当成 latest。
  File get legacyManifestCacheFile =>
      File('${root.path}${_separator}update-manifest.cache.json');

  /// 旧缓存的隔离位置（最多保留一份，留证用）。
  File get legacyManifestCacheQuarantineFile =>
      File('${legacyManifestCacheFile.path}.legacy-quarantine');

  /// 受控版本目录（目录名能严格解析成 MSIX 版本）。
  ///
  /// 启动复核只枚举这些目录里的 `.ready`：其他名字一律不参与"收养"，避免把用户数据目录
  /// 或临时目录当成更新包。
  List<Directory> versionDirectories() {
    final result = <Directory>[];
    if (!root.existsSync()) return result;
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(RegExp(r'[\\/]')).last;
      if (MsixVersion.tryParse(name) == null) continue;
      result.add(entity);
    }
    return result;
  }

  /// 无法证明身份的包改名为 `.quarantine`：不执行、不静默删除。
  File quarantined(File file) => File('${file.path}.quarantine');

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

  File requestFile(MsixVersion version) =>
      File('${versionDirectory(version).path}${_separator}update-request.json');

  File helperStatusFile(MsixVersion version) =>
      File('${versionDirectory(version).path}${_separator}helper-status.json');

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
