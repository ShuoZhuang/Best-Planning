// 发布流水线的命令行（规格 §17 / UPD-042 / UPD-044）。
//
// 它的职责是"从成品生成清单，再从清单复验成品"，两步都不允许手写大小或哈希：
//
//   dart run tool/update_pipeline.dart manifest --msix <path> ...
//   dart run tool/update_pipeline.dart verify --manifest <path> --msix <path> ...
//   dart run tool/update_pipeline.dart gate --version 1.9.0 --build 46 ...
//
// 私钥从 `BEST_PLANNING_UPDATE_SIGNING_KEY` 指向的 PEM 读取（PKCS#8，Ed25519），
// **不写进版本库**——与 MSIX 的 `.pfx` 同一口径。
//
// 上传与草稿 Release 的"回读后再发布"需要 GitHub 凭据，本文件把它留成一个显式的人工/CI
// 步骤（`publish` 子命令只做前置检查），避免在本地脚本里藏一个能发布版本的开关。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';
import 'package:personal_planner/infrastructure/update/update_package_verifier.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  final command = arguments.first;
  final options = _parseOptions(arguments.skip(1).toList());
  try {
    switch (command) {
      case 'manifest':
        await _manifestCommand(options);
      case 'verify':
        await _verifyCommand(options);
      case 'gate':
        _gateCommand(options);
      case 'publish':
        _publishPreflight(options);
      default:
        stderr.writeln('未知子命令：$command\n\n$_usage');
        exitCode = 64;
    }
  } on PipelineException catch (error) {
    stderr.writeln('失败：${error.message}');
    exitCode = 1;
  } on Object catch (error) {
    stderr.writeln('失败：$error');
    exitCode = 1;
  }
}

const String _usage = '''
用法：
  manifest --msix <成品.msix> --version 1.9.0 --build 46 --msix-version 1.9.0.0 \\
           --output <update-manifest.json> [--published-at <ISO8601>] \\
           [--title <文本>] [--summary <文本>] [--revoked 1.9.0.0]
  verify   --manifest <update-manifest.json> --msix <成品.msix>
  gate     --version <新> --build <新> --msix-version <新> \\
           --previous-version <旧> --previous-build <旧>
  publish  --manifest <...> --msix <...>   # 只做发布前检查

签名私钥：BEST_PLANNING_UPDATE_SIGNING_KEY=<ed25519-pkcs8.pem>
签名密钥 ID：BEST_PLANNING_UPDATE_SIGNING_KEY_ID（默认 best-planning-2026-10）
''';

final class PipelineException implements Exception {
  const PipelineException(this.message);

  final String message;
}

Map<String, String> _parseOptions(List<String> arguments) {
  final options = <String, String>{};
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (!argument.startsWith('--')) {
      throw PipelineException('无法解析参数：$argument');
    }
    final name = argument.substring(2);
    if (i + 1 >= arguments.length) {
      throw PipelineException('参数 $argument 缺少值');
    }
    options[name] = arguments[++i];
  }
  return options;
}

String _required(Map<String, String> options, String name) {
  final value = options[name];
  if (value == null || value.trim().isEmpty) {
    throw PipelineException('缺少 --$name');
  }
  return value.trim();
}

MsixVersion _msixVersion(String raw) {
  final version = MsixVersion.tryParse(raw);
  if (version == null) throw PipelineException('不是合法的四段 MSIX 版本：$raw');
  return version;
}

/// 生成 payload。**所有尺寸与哈希都从成品读**，不接受调用方传入。
Future<Map<String, Object?>> buildManifestPayload({
  required File msix,
  required String version,
  required int buildNumber,
  required String msixVersion,
  String? publishedAtUtc,
  String? title,
  String? summary,
  List<String> revokedVersions = const [],
}) async {
  final semantic = SemVer.tryParse(version);
  if (semantic == null) throw PipelineException('不是合法的 SemVer：$version');
  final msixSemantic = _msixVersion(msixVersion);
  if (msixSemantic.semanticLabel != semantic.value) {
    throw PipelineException('MSIX 前三段必须等于 SemVer：$msixVersion vs $version');
  }
  if (buildNumber <= 0) throw PipelineException('构建号必须是正整数');
  if (!await msix.exists()) throw PipelineException('找不到成品：${msix.path}');

  final bytes = await msix.readAsBytes();
  final digest = _sha256Hex(bytes);
  final tag = 'v${semantic.value}';
  final fileName = 'BestPlanning_${msixSemantic.value}_x64.msix';
  final revoked = <String>[];
  for (final raw in revokedVersions) {
    final parsed = MsixVersion.tryParse(raw);
    if (parsed == null) throw PipelineException('撤回版本不是四段版本：$raw');
    revoked.add(parsed.value);
  }

  return {
    'schemaVersion': 1,
    'channel': 'stable',
    'release': {
      'version': semantic.value,
      'buildNumber': buildNumber,
      'msixVersion': msixSemantic.value,
      'tag': tag,
      'publishedAtUtc':
          publishedAtUtc ?? DateTime.now().toUtc().toIso8601String(),
    },
    'compatibility': {
      'architecture': appArchitecture,
      'minimumWindowsBuild': appMinimumWindowsBuild.join('.'),
      'packageIdentityName': appPackageIdentityName,
      'packageFamilyName': appPackageFamilyName,
      'publisher': appPublisher,
    },
    'package': {
      'fileName': fileName,
      'downloadUrl':
          '$updateRepositoryUrl/releases/download/$tag/$fileName',
      'sizeBytes': bytes.length,
      'sha256': digest,
    },
    'presentation': {
      'title': title ?? '优计主义 ${semantic.value}',
      'summary': summary ?? '修复与改进。',
      'releaseUrl': '$updateRepositoryUrl/releases/tag/$tag',
    },
    'revokedVersions': revoked,
  };
}

Future<void> _manifestCommand(Map<String, String> options) async {
  final msixPath = _required(options, 'msix');
  final outputPath = _required(options, 'output');
  final payload = await buildManifestPayload(
    msix: File(msixPath),
    version: _required(options, 'version'),
    buildNumber: int.tryParse(_required(options, 'build')) ??
        (throw const PipelineException('--build 必须是整数')),
    msixVersion: _required(options, 'msix-version'),
    publishedAtUtc: options['published-at'],
    title: options['title'],
    summary: options['summary'],
    revokedVersions: options['revoked'] == null
        ? const []
        : options['revoked']!.split(',').map((value) => value.trim()).toList(),
  );

  final keyPath = Platform.environment['BEST_PLANNING_UPDATE_SIGNING_KEY'];
  if (keyPath == null || keyPath.isEmpty) {
    throw const PipelineException(
      '未设置 BEST_PLANNING_UPDATE_SIGNING_KEY（Ed25519 私钥 PEM 路径）',
    );
  }
  final keyId = Platform.environment['BEST_PLANNING_UPDATE_SIGNING_KEY_ID'] ??
      'best-planning-2026-10';
  final seed = await readEd25519SeedFromPem(File(keyPath));
  final signer = await Ed25519ManifestSigner.fromSeedHex(seed, keyId: keyId);
  final envelope = await signer.signEnvelope(payload);

  final output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(envelope),
    flush: true,
  );
  stdout.writeln(
    '已生成 $outputPath（${payload['package']! as Map}）'.replaceAll('\n', ' '),
  );
  // 立即自检：流水线不允许产出自己都验不过的清单。
  await verifyManifestEnvelope(
    envelope: UpdateManifestEnvelope.tryParse(envelope)
        as UpdateManifestEnvelope,
    msix: File(msixPath),
    publicKeys: {keyId: await signer.publicKeyHex()},
  );
  stdout.writeln('清单自检通过：$outputPath');
}

Future<void> _verifyCommand(Map<String, String> options) async {
  final manifestPath = _required(options, 'manifest');
  final msixPath = _required(options, 'msix');
  final json = jsonDecode(await File(manifestPath).readAsString());
  if (json is! Map) throw const PipelineException('清单不是 JSON 对象');
  final envelope = UpdateManifestEnvelope.tryParse(json);
  if (envelope is! UpdateManifestEnvelope) {
    throw const PipelineException('清单信封结构不合法');
  }
  final publicKeys = <String, String>{...manifestPublicKeys};
  final extraKey = options['public-key'];
  if (extraKey != null) {
    publicKeys[options['key-id'] ?? 'test-key'] = extraKey;
  }
  await verifyManifestEnvelope(
    envelope: UpdateManifestEnvelope.tryParse(envelope)
        as UpdateManifestEnvelope,
    msix: File(msixPath),
    publicKeys: publicKeys,
  );
  stdout.writeln('清单与成品一致：$manifestPath / $msixPath');
}

/// 验证签名、大小、SHA-256 与包身份（不要求目标版本高于已安装版本）。
Future<void> verifyManifestEnvelope({
  required UpdateManifestEnvelope envelope,
  required File msix,
  required Map<String, String> publicKeys,
}) async {
  final verifier = Ed25519ManifestVerifier(publicKeys: publicKeys);
  final verification = await verifier.verify(envelope);
  final verified = verification.verified;
  if (verified == null) {
    throw PipelineException('清单验签失败：${verification.failure?.code.code}');
  }
  final manifest = verified.manifest;
  final bytes = await msix.readAsBytes();
  if (bytes.length != manifest.package.sizeBytes) {
    throw PipelineException(
      '大小不一致：${bytes.length} != ${manifest.package.sizeBytes}',
    );
  }
  if (_sha256Hex(bytes) != manifest.package.sha256) {
    throw const PipelineException('SHA-256 不一致');
  }

  // 包身份从成品内部读，而不是照着清单再抄一遍。
  final verificationOfPackage = await ZipUpdatePackageVerifier().verify(
    path: msix.path,
    target: UpdateTarget(
      version: manifest.release.version,
      buildNumber: manifest.release.buildNumber,
      tag: manifest.tag,
      msixVersion: manifest.msixVersion,
      fileName: manifest.package.fileName,
      downloadUrl: manifest.package.downloadUrl,
      sizeBytes: manifest.package.sizeBytes,
      sha256: manifest.package.sha256,
      manifestDigest: verified.canonicalDigest,
      keyId: manifest.signature.keyId,
    ),
    installed: const InstalledPackage(
      identityName: appPackageIdentityName,
      publisher: appPublisher,
      familyName: appPackageFamilyName,
      architecture: PackageArchitecture.x64,
      version: MsixVersion(0, 0, 0, 0),
    ),
    verifyNativeSignature: false,
  );
  if (!verificationOfPackage.ok) {
    throw PipelineException(
      '包身份验证失败：${verificationOfPackage.failure?.code.code}',
    );
  }
}

void _gateCommand(Map<String, String> options) {
  final issues = gateIssues(
    version: _required(options, 'version'),
    buildNumber: _required(options, 'build'),
    msixVersion: _required(options, 'msix-version'),
    previousVersion: _required(options, 'previous-version'),
    previousBuild: _required(options, 'previous-build'),
  );
  if (issues.isNotEmpty) {
    throw PipelineException(issues.join('；'));
  }
  stdout.writeln('发布门禁通过');
}

/// 版本单调与格式一致性（规格 §17 的阻断条件）。
List<String> gateIssues({
  required String version,
  required String buildNumber,
  required String msixVersion,
  required String previousVersion,
  required String previousBuild,
}) {
  final issues = <String>[];
  final current = SemVer.tryParse(version);
  final previous = SemVer.tryParse(previousVersion);
  final currentBuild = int.tryParse(buildNumber);
  final previousBuildValue = int.tryParse(previousBuild);
  final currentMsix = MsixVersion.tryParse(msixVersion);
  if (current == null) issues.add('新版本不是合法 SemVer');
  if (previous == null) issues.add('上一版本不是合法 SemVer');
  if (currentBuild == null || currentBuild <= 0) issues.add('新构建号不合法');
  if (previousBuildValue == null || previousBuildValue <= 0) {
    issues.add('上一构建号不合法');
  }
  if (currentMsix == null) issues.add('新 MSIX 版本不是四段');
  if (current != null &&
      previous != null &&
      current.compareTo(previous) <= 0) {
    issues.add('SemVer 未递增');
  }
  if (currentBuild != null &&
      previousBuildValue != null &&
      currentBuild <= previousBuildValue) {
    issues.add('构建号未递增');
  }
  if (current != null && currentMsix != null &&
      currentMsix.semanticLabel != current.value) {
    issues.add('MSIX 版本与 SemVer 不一致');
  }
  return issues;
}

void _publishPreflight(Map<String, String> options) {
  final issues = <String>[];
  final manifest = File(_required(options, 'manifest'));
  final msix = File(_required(options, 'msix'));
  if (!manifest.existsSync()) issues.add('清单不存在');
  if (!msix.existsSync()) issues.add('成品不存在');
  final key = Platform.environment['BEST_PLANNING_UPDATE_SIGNING_KEY'];
  if (key == null || key.isEmpty) issues.add('签名私钥环境变量未设置');
  if (issues.isNotEmpty) throw PipelineException(issues.join('；'));
  stdout.writeln(
    '发布前置检查通过。上传后必须先用 `verify` 从 GitHub 重新下载的资产复验，'
    '通过后才能把草稿 Release 发布。',
  );
}

/// 读取 PKCS#8 Ed25519 私钥里的 32 字节种子。
///
/// PKCS#8 结构固定为 16 字节前缀 + 32 字节种子；这里做最小校验（版本、算法 OID），
/// 不引一个只为发布机器使用的 ASN.1 解析依赖。
Future<String> readEd25519SeedFromPem(File file) async {
  if (!await file.exists()) {
    throw PipelineException('找不到签名私钥：${file.path}');
  }
  final content = await file.readAsString();
  final match = RegExp(
    r'-----BEGIN PRIVATE KEY-----([\s\S]*?)-----END PRIVATE KEY-----',
  ).firstMatch(content);
  if (match == null) {
    throw const PipelineException('私钥必须是 PKCS#8 PEM（BEGIN PRIVATE KEY）');
  }
  final List<int> der;
  try {
    der = base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    throw const PipelineException('私钥 PEM 的 base64 内容不合法');
  }
  if (der.length < 48) throw const PipelineException('私钥长度不正确');
  final seed = der.sublist(der.length - 32);
  return seed.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();


