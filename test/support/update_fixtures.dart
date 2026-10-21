// 更新子系统的测试夹具：一份结构正确、可签名的清单，以及一对固定的测试密钥。
//
// **为什么用固定种子而不是随机密钥**：签名测试要证明"同一份 payload 每次得到同一份字节"，
// 随机密钥会让失败信息里的签名无法复现。这个种子只用于测试，与生产公钥允许集合无关。
import 'dart:convert';

import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';

/// 32 字节测试种子（`00 01 02 ... 1f`）。
const String testSigningSeedHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

const String testSigningKeyId = 'test-key-2026-10';

const String testPackageSha256 =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Future<Ed25519ManifestSigner> createTestSigner({
  String seedHex = testSigningSeedHex,
  String keyId = testSigningKeyId,
}) => Ed25519ManifestSigner.fromSeedHex(seedHex, keyId: keyId);

Future<Ed25519ManifestVerifier> createTestVerifier() async {
  final signer = await createTestSigner();
  return Ed25519ManifestVerifier(
    publicKeys: {testSigningKeyId: await signer.publicKeyHex()},
  );
}

/// 构造一份**结构完全正确**的清单 payload。
///
/// 任何想制造缺陷的测试都从它出发，用 [replaceAt] / [removeAt] 做最小改动——这样"被破坏的
/// 到底是哪一条规则"始终清楚，而不是重新手写一份可能同时违反三条规则的 payload。
Map<String, Object?> validManifestPayload({
  String version = '1.9.0',
  int buildNumber = 46,
  String? msixVersion,
  String? tag,
  String? fileName,
  String? downloadUrl,
  String? releaseUrl,
  int sizeBytes = 2048,
  String sha256 = testPackageSha256,
  int schemaVersion = 1,
  String channel = 'stable',
  List<String> revokedVersions = const [],
}) {
  final resolvedMsix = msixVersion ?? '$version.0';
  final resolvedTag = tag ?? 'v$version';
  final resolvedFileName = fileName ?? 'BestPlanning_${resolvedMsix}_x64.msix';
  return {
    'schemaVersion': schemaVersion,
    'channel': channel,
    'release': {
      'version': version,
      'buildNumber': buildNumber,
      'msixVersion': resolvedMsix,
      'tag': resolvedTag,
      'publishedAtUtc': '2026-10-18T00:00:00Z',
    },
    'compatibility': {
      'architecture': 'x64',
      'minimumWindowsBuild': '10.0.19041.0',
      'packageIdentityName': 'ShuoZhuang.PersonalPlanner',
      'packageFamilyName': 'ShuoZhuang.PersonalPlanner_v9555qkaxdyym',
      'publisher': 'CN=Shuo Zhuang, O=Personal User, C=CN',
    },
    'package': {
      'fileName': resolvedFileName,
      'downloadUrl':
          downloadUrl ??
          'https://github.com/ShuoZhuang/Best-Planning/releases/download/$resolvedTag/$resolvedFileName',
      'sizeBytes': sizeBytes,
      'sha256': sha256,
    },
    'presentation': {
      'title': '优计主义 1.9.0',
      'summary': '修复更新检查与调度问题。',
      'releaseUrl':
          releaseUrl ??
          'https://github.com/ShuoZhuang/Best-Planning/releases/tag/$resolvedTag',
    },
    'revokedVersions': revokedVersions,
  };
}

/// 深拷贝（只含 JSON 值）。
Map<String, Object?> deepCopy(Map<String, Object?> source) {
  Object? copy(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key as String: copy(entry.value),
      };
    }
    if (value is List) return [for (final item in value) copy(item)];
    return value;
  }

  return copy(source) as Map<String, Object?>;
}

/// 按路径替换一个值。
Map<String, Object?> replaceAt(
  Map<String, Object?> source,
  List<String> path,
  Object? value,
) {
  final copy = deepCopy(source);
  Map<String, Object?> current = copy;
  for (var i = 0; i < path.length - 1; i++) {
    current = current[path[i]] as Map<String, Object?>;
  }
  current[path.last] = value;
  return copy;
}

/// 按路径删除一个键。
Map<String, Object?> removeAt(Map<String, Object?> source, List<String> path) {
  final copy = deepCopy(source);
  Map<String, Object?> current = copy;
  for (var i = 0; i < path.length - 1; i++) {
    current = current[path[i]] as Map<String, Object?>;
  }
  current.remove(path.last);
  return copy;
}

/// 签好的清单信封（`{payload, signature}`）。
Future<Map<String, Object?>> signedManifestEnvelope(
  Map<String, Object?> payload, {
  Ed25519ManifestSigner? signer,
}) async {
  final active = signer ?? await createTestSigner();
  return {'payload': payload, 'signature': await active.signPayload(payload)};
}

/// 已签名的清单 JSON 字符串（仓库测试用）。
Future<String> signedManifestJson(
  Map<String, Object?> payload, {
  Ed25519ManifestSigner? signer,
}) async {
  final envelope = await signedManifestEnvelope(payload, signer: signer);
  return jsonEncode(envelope);
}
