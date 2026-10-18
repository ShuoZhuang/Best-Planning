// 草稿 Release 的发布门禁（规格 §17 第 9～13 步 / UPD-043）。
//
// 顺序不可颠倒：
//   1. 本地先验证清单与成品；
//   2. 创建草稿并上传；
//   3. **从 GitHub 重新下载**资产，复算大小与 SHA-256，重新验签与验身份；
//   4. 只有第 3 步全部通过，才把草稿改成正式 Release；
//   5. 确认 `latest` 指向新 tag。
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

final class UpdatePublisher {
  UpdatePublisher({
    required this.repository,
    required this.workspace,
    required this.runner,
    Map<String, String>? publicKeys,
  }) : publicKeys = publicKeys ?? manifestPublicKeys;

  final String repository;
  final Directory workspace;
  final GhRunner runner;
  final Map<String, String> publicKeys;

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
    final manifestJson =
        jsonDecode(await manifestFile.readAsString());
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
    final manifestSha = sha256.convert(await manifestFile.readAsBytes()).toString();
    final packageSha = sha256.convert(await msixFile.readAsBytes()).toString();

    // 2. 草稿 Release + 上传。
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
      '--clobber',
    ], '上传资产');

    // 3. 从 GitHub 重新下载并复核。
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
      final downloadedJson = jsonDecode(await downloadedManifest.readAsString());
      final downloadedEnvelope = UpdateManifestEnvelope.tryParse(downloadedJson);
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

    // 4. 复核通过才发布。
    await _run([
      'release',
      'edit',
      tag,
      '--draft=false',
      '--repo',
      repository,
    ], '把草稿改为正式 Release');

    // 5. latest 必须指向新 tag。
    final latest = await _run([
      'api',
      'repos/$repository/releases/latest',
    ], '读取 latest Release');
    final latestJson = jsonDecode(latest.stdout);
    final latestTag = latestJson is Map ? latestJson['tag_name'] as String? : null;
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

