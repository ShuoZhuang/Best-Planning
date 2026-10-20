// 草稿 Release 的发布门禁（规格 §17 第 9～13 步 / UPD-043）。
//
// 顺序不可颠倒：
//   1. 本地先验证清单与成品；
//   2. **发布资产不可变门禁**：目标 tag 或其名下资产已存在 → 立即中止，要求新版本号；
//   3. 创建草稿并上传；
//   4. **从 GitHub 重新下载**资产，复算大小与 SHA-256，重新验签与验身份；
//   5. 只有第 4 步全部通过，才把草稿改成正式 Release；
//   6. 确认 `latest` 指向新 tag。
//
// 第 2 步是 1.11.1 加的（UPD-INC-030）：已发布的 tag/资产不可重写，否则客户端的回退基线
// 与发布记录再也追溯不到同一份字节。上传因此**不再使用 `--clobber`**——覆盖在这里不是
// 一个选项，发现冲突只能换版本号。
//
// 这里不直接调用 GitHub API，而是调用 `gh` CLI：凭据由发布机负责，脚本不保存令牌。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';

import 'update_pipeline.dart';

final class GhResult {
  const GhResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

typedef GhRunner = Future<GhResult> Function(List<String> arguments);

/// 查询目标 tag 在远端的现状（发布资产不可变门禁的探测步骤）。
///
/// 默认实现走注入的 [GhRunner]，因此测试只要给 runner 一段假响应，**不需要真实网络**；
/// 需要更细粒度控制时可以整体注入一个探测函数。
typedef RemoteTagProbe = Future<RemoteTagState> Function(String tag);

final class PublishResult {
  const PublishResult({
    required this.tag,
    required this.packageSha256,
    required this.manifestSha256,
    required this.latestTag,
  });

  final String tag;
  final String packageSha256;
  final String manifestSha256;
  final String latestTag;
}

final class PublishException implements Exception {
  const PublishException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 清单资产在 Release 上的固定文件名：应用内更新只认这个名字，因此不可变检查必须点名它。
const String updateManifestAssetName = 'update-manifest.json';

final class UpdatePublisher {
  UpdatePublisher({
    required this.repository,
    required this.workspace,
    required this.runner,
    this.remoteTagProbe,
    Map<String, String>? publicKeys,
  }) : publicKeys = publicKeys ?? manifestPublicKeys;

  final String repository;
  final Directory workspace;
  final GhRunner runner;
  final Map<String, String> publicKeys;

  /// 可注入的远端 tag 探测；为空时使用 [runner]（`gh api`）。
  final RemoteTagProbe? remoteTagProbe;

  /// 执行完整的"草稿 → 回读复核 → 发布"。
  Future<PublishResult> publish({
    required String tag,
    required File manifestFile,
    required File msixFile,
    required String title,
    File? notesFile,
  }) async {
    if (!manifestFile.existsSync()) {
      throw const PublishException('找不到清单文件');
    }
    if (!msixFile.existsSync()) {
      throw const PublishException('找不到成品 MSIX');
    }
    final manifestJson = jsonDecode(await manifestFile.readAsString());
    if (manifestJson is! Map) {
      throw const PublishException('清单不是 JSON 对象');
    }
    final envelope = UpdateManifestEnvelope.tryParse(manifestJson);
    if (envelope is! UpdateManifestEnvelope) {
      throw const PublishException('清单信封结构不合法');
    }

    // 1. 本地验证：签名、大小、哈希与包身份。
    await verifyManifestEnvelope(
      envelope: envelope,
      msix: msixFile,
      publicKeys: publicKeys,
    );
    final manifestSha = sha256
        .convert(await manifestFile.readAsBytes())
        .toString();
    final packageSha = sha256.convert(await msixFile.readAsBytes()).toString();

    // 2. 发布资产不可变门禁（UPD-INC-030）：**在创建草稿之前**确认 tag 与资产都还不存在。
    //    探测失败（网络/凭据/无法解析）同样中止——"查不到"不等于"不存在"，不能失败即放行。
    final packageFileName =
        _packageFileNameIn(envelope) ?? msixFile.uri.pathSegments.last;
    await _ensureReleaseTargetIsUnused(
      tag: tag,
      packageFileName: packageFileName,
      manifestFileName: updateManifestAssetName,
    );

    // 3. 草稿 Release + 上传。**不加 `--clobber`**：第 2 步已经保证资产不存在，
    //    万一远端状态在这之间变化，上传应当失败而不是静默覆盖。
    final createArgs = [
      'release',
      'create',
      tag,
      '--draft',
      '--title',
      title,
      '--repo',
      repository,
      '--notes-file',
      notesFile?.path ?? await _defaultNotesFile(),
    ];
    await _run(createArgs, '创建草稿 Release');
    await _run([
      'release',
      'upload',
      tag,
      msixFile.path,
      manifestFile.path,
      '--repo',
      repository,
    ], '上传资产');

    // 4. 从 GitHub 重新下载并复核。
    final downloadDirectory = Directory(
      '${workspace.path}${Platform.pathSeparator}'
      'release-verify-${DateTime.now().microsecondsSinceEpoch}',
    );
    await downloadDirectory.create(recursive: true);
    try {
      await _run([
        'release',
        'download',
        tag,
        '--repo',
        repository,
        '--dir',
        downloadDirectory.path,
        '--pattern',
        'update-manifest.json',
        '--pattern',
        '*.msix',
      ], '下载已上传的资产');
      final downloadedManifest = File(
        '${downloadDirectory.path}${Platform.pathSeparator}update-manifest.json',
      );
      final downloadedMsix = _firstMsixIn(downloadDirectory);
      if (!downloadedManifest.existsSync() || downloadedMsix == null) {
        throw const PublishException('回读资产不完整');
      }
      if (sha256.convert(await downloadedManifest.readAsBytes()).toString() !=
          manifestSha) {
        throw const PublishException('回读的清单与上传的清单哈希不一致');
      }
      if (sha256.convert(await downloadedMsix.readAsBytes()).toString() !=
          packageSha) {
        throw const PublishException('回读的 MSIX 与上传的 MSIX 哈希不一致');
      }
      final downloadedJson = jsonDecode(
        await downloadedManifest.readAsString(),
      );
      final downloadedEnvelope = UpdateManifestEnvelope.tryParse(
        downloadedJson,
      );
      if (downloadedEnvelope is! UpdateManifestEnvelope) {
        throw const PublishException('回读的清单结构不合法');
      }
      await verifyManifestEnvelope(
        envelope: downloadedEnvelope,
        msix: downloadedMsix,
        publicKeys: publicKeys,
      );
    } finally {
      if (await downloadDirectory.exists()) {
        await downloadDirectory.delete(recursive: true);
      }
    }

    // 5. 复核通过才发布。
    await _run([
      'release',
      'edit',
      tag,
      '--draft=false',
      '--repo',
      repository,
    ], '把草稿改为正式 Release');

    // 6. latest 必须指向新 tag。
    final latest = await _run([
      'api',
      'repos/$repository/releases/latest',
    ], '读取 latest Release');
    final latestJson = jsonDecode(latest.stdout);
    final latestTag = latestJson is Map
        ? latestJson['tag_name'] as String?
        : null;
    if (latestTag != tag) {
      throw PublishException('latest 指向 $latestTag，而不是 $tag');
    }

    return PublishResult(
      tag: tag,
      packageSha256: packageSha,
      manifestSha256: manifestSha,
      latestTag: latestTag!,
    );
  }

  /// 发布资产不可变门禁：已有 tag、已有 Release 或已有同名资产时中止。
  ///
  /// 探测本身可注入（[RemoteTagProbe]），默认实现走 [runner]（发布机上就是 `gh`）。
  Future<void> _ensureReleaseTargetIsUnused({
    required String tag,
    required String packageFileName,
    required String manifestFileName,
  }) async {
    final remote = await (remoteTagProbe ?? _probeRemoteTag)(tag);
    final issues = releaseImmutabilityIssues(
      tag: tag,
      remote: remote,
      packageFileName: packageFileName,
      manifestFileName: manifestFileName,
    );
    if (issues.isNotEmpty) {
      throw PublishException('发布资产不可变门禁拦截（UPD-INC-030）：${issues.join('；')}');
    }
  }

  /// 用 `gh api` 读取目标 tag 的远端现状。
  ///
  /// **无法确认就中止**：网络、凭据或 JSON 解析失败都不等于"不存在"。把探测失败当成
  /// 放行，就等于在断网时取消这条门禁——这正是不可变资产最需要它的时刻。
  Future<RemoteTagState> _probeRemoteTag(String tag) async {
    final release = await runner([
      'api',
      'repos/$repository/releases/tags/$tag',
    ]);
    if (release.ok) {
      final decoded = _decodeJsonObject(release.stdout);
      if (decoded == null) {
        throw PublishException('无法解析 tag $tag 的 Release 信息，已中止发布（不可变门禁不能跳过）');
      }
      return RemoteTagState(
        tagExists: true,
        releaseExists: true,
        assetNames: _assetNamesIn(decoded),
      );
    }
    if (!_isNotFound(release)) {
      throw PublishException(
        '无法确认 tag $tag 是否已存在（exit ${release.exitCode}）：'
        '${release.stderr.trim()}；已中止发布',
      );
    }

    // Release 不存在，但 tag 可能只是一个裸 tag——同样不可复用。
    final reference = await runner([
      'api',
      'repos/$repository/git/ref/tags/$tag',
    ]);
    if (reference.ok) {
      return const RemoteTagState(tagExists: true, releaseExists: false);
    }
    if (!_isNotFound(reference)) {
      throw PublishException(
        '无法确认 tag $tag 是否已存在（exit ${reference.exitCode}）：'
        '${reference.stderr.trim()}；已中止发布',
      );
    }
    return const RemoteTagState.absent();
  }

  static bool _isNotFound(GhResult result) {
    if (result.ok) return false;
    final text = '${result.stdout}\n${result.stderr}'.toLowerCase();
    return text.contains('404') || text.contains('not found');
  }

  static Map<String, Object?>? _decodeJsonObject(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  static List<String> _assetNamesIn(Map<String, Object?> release) {
    final assets = release['assets'];
    if (assets is! List) return const <String>[];
    return <String>[
      for (final asset in assets)
        if (asset is Map && asset['name'] is String) asset['name'] as String,
    ];
  }

  static String? _packageFileNameIn(UpdateManifestEnvelope envelope) {
    final package = envelope.payloadJson['package'];
    if (package is Map && package['fileName'] is String) {
      return package['fileName'] as String;
    }
    return null;
  }

  Future<GhResult> _run(List<String> arguments, String what) async {
    final result = await runner(arguments);
    if (!result.ok) {
      throw PublishException(
        '$what 失败（exit ${result.exitCode}）：${result.stderr.trim()}',
      );
    }
    return result;
  }

  Future<String> _defaultNotesFile() async {
    final file = File(
      '${workspace.path}${Platform.pathSeparator}release-notes.md',
    );
    if (!file.existsSync()) {
      await file.writeAsString('发布说明见 Release 页面。');
    }
    return file.path;
  }

  static File? _firstMsixIn(Directory directory) {
    for (final entity in directory.listSync()) {
      if (entity is File && entity.path.endsWith('.msix')) return entity;
    }
    return null;
  }
}

/// 真实 `gh` 执行器（仅发布机使用）。
Future<GhResult> runGh(List<String> arguments) async {
  final result = await Process.run('gh', arguments);
  return GhResult(
    result.exitCode,
    result.stdout is String ? result.stdout as String : '',
    result.stderr is String ? result.stderr as String : '',
  );
}
