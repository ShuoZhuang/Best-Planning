// 已验证清单的本地缓存（规格 §7.4 / §7.5）。
//
// 缓存**只保存通过结构、来源与签名验证的清单**。读取时再验一次签：这样"缓存被改动"与
// "缓存被写坏"都表现为"没有有效缓存"，而不是把一份未经验签的清单当成 304 的依据。
//
// 缓存里同时保存 ETag：`304` 只有在缓存有效时才有意义；没有缓存的 304 必须重新完整请求。
import 'dart:io';

import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/infrastructure/update/atomic_file.dart';
import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';

/// 缓存文件结构版本。
const int updateManifestCacheSchemaVersion = 1;

/// 文件缓存实现。
final class FileUpdateManifestCache implements UpdateManifestCache {
  FileUpdateManifestCache({
    required Directory directory,
    required this.verifier,
    this.fileName = 'update-manifest.cache.json',
  }) : _file = File('${directory.path}${Platform.pathSeparator}$fileName');

  final File _file;
  final Ed25519ManifestVerifier verifier;
  final String fileName;

  File get file => _file;

  @override
  Future<VerifiedManifest?> load() async {
    final json = await readJsonOrNull(_file);
    if (json is! Map) return null;
    if (json['schemaVersion'] != updateManifestCacheSchemaVersion) return null;
    final envelopeJson = json['envelope'];
    final parsed = UpdateManifestEnvelope.tryParse(envelopeJson);
    if (parsed is! UpdateManifestEnvelope) return null;
    final confirmation = await verifier.verify(
      parsed,
      etag: json['etag'] is String ? json['etag'] as String : null,
      manifestUrl: json['manifestUrl'] is String
          ? json['manifestUrl'] as String
          : null,
    );
    final verified = confirmation.verified;
    if (verified == null) return null;
    final fetchedAt = json['confirmedAtUtc'];
    final confirmedAt = fetchedAt is String
        ? DateTime.tryParse(fetchedAt)?.toUtc()
        : null;
    return verified.copyWith(
      confirmedAtUtc: confirmedAt ?? verified.confirmedAtUtc,
      etag: json['etag'] is String ? json['etag'] as String : null,
      fromCache: true,
      manifestUrl: verified.manifestUrl,
    );
  }

  @override
  Future<void> save(VerifiedManifest manifest) async {
    await writeJsonAtomically(_file, {
      'schemaVersion': updateManifestCacheSchemaVersion,
      'confirmedAtUtc': manifest.confirmedAtUtc.toUtc().toIso8601String(),
      'etag': manifest.etag,
      'manifestUrl': manifest.manifestUrl,
      'canonicalDigest': manifest.canonicalDigest,
      'envelope': {
        'payload': manifest.payloadJson,
        'signature': {
          'algorithm': manifest.manifest.signature.algorithm,
          'keyId': manifest.manifest.signature.keyId,
          'value': manifest.manifest.signature.value,
        },
      },
    });
  }

  @override
  Future<void> clear() async {
    try {
      if (await _file.exists()) await _file.delete();
    } on Object {
      // 删除失败不影响正确性：读取时仍会重新验签。
    }
  }
}
