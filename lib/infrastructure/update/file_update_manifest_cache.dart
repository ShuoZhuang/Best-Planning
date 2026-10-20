// 已验证清单的**分区**本地缓存（1.11.1 事故修复 §4.2 / §4.3）。
//
// 1.11.0 的实现只有一份 `update-manifest.cache.json`：`fetchLatest()` 与
// `fetchForTag(v1.10.2)` 共用它，于是"建立回退基线"会把 latest 的缓存实体覆盖成旧版本；
// 下一次 latest 收到 304 时读到的就是那份旧清单——界面因此显示"已是最新版"。
//
// 1.11.1 的规则：
//   · 每个请求身份一个文件（`manifests/latest-stable.json`、`manifests/tags/<tag>.json`）；
//   · 文件内同时保存请求身份、ETag、规范化摘要与信封，读取时**四者互相核对**；
//   · 读取时重新验签并重算摘要：缓存被改动只表现为"没有缓存"，而不是"有效的 304 依据"；
//   · 旧全局缓存没有请求身份，只能隔离，**绝不猜它属于 latest**。
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/domain/update/manifest_cache_entry.dart';
import 'package:personal_planner/domain/update/manifest_request_key.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/infrastructure/update/atomic_file.dart';
import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';
import 'package:personal_planner/infrastructure/update/json_canonicalizer.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

/// 缓存文件结构版本。v2 起**每个文件只属于一个请求身份**。
const int updateManifestCacheSchemaVersion = 2;

/// 文件缓存实现。
final class FileUpdateManifestCache implements UpdateManifestCache {
  FileUpdateManifestCache({
    required this.layout,
    required this.verifier,
    Future<void> Function(File file, Object? json)? writer,
  }) : _writer = writer ?? writeJsonAtomically;

  final UpdateStorageLayout layout;
  final Ed25519ManifestVerifier verifier;

  /// 落盘实现。默认是"临时文件 + 原子替换"；测试用它注入失败以验证旧缓存不受损。
  final Future<void> Function(File file, Object? json) _writer;

  /// 每个请求身份一条写入链：并发保存同一个 key 时按顺序落盘。
  final Map<String, Future<void>> _pendingWrites = {};

  /// 某个请求身份的缓存文件。
  File fileFor(ManifestRequestKey key) => layout.manifestCacheFile(key);

  /// 1.11.0 的全局缓存文件（只用于隔离与诊断）。
  File get legacyFile => layout.legacyManifestCacheFile;

  @override
  Future<ManifestCacheEntry?> load(ManifestRequestKey key) async {
    final file = fileFor(key);
    final json = await readJsonOrNull(file);
    if (json is! Map) return null;
    if (json['schemaVersion'] != updateManifestCacheSchemaVersion) return null;

    // 身份双重核对：文件内记录的身份必须与调用方请求一致。
    final storedKey = ManifestRequestKey.fromJson(json['requestKey']);
    if (storedKey == null || storedKey != key) return null;
    final canonicalUrl = json['canonicalRequestUrl'];
    if (canonicalUrl is! String || canonicalUrl != key.canonicalRequestUrl) {
      return null;
    }

    final envelopeJson = json['envelope'];
    final parsed = UpdateManifestEnvelope.tryParse(envelopeJson);
    if (parsed is! UpdateManifestEnvelope) return null;

    final etag = json['etag'] is String ? json['etag'] as String : null;
    final resolvedOrigin = json['sanitizedResolvedOrigin'] is String
        ? json['sanitizedResolvedOrigin'] as String
        : null;
    final confirmation = await verifier.verify(
      parsed,
      etag: etag,
      requestKey: key,
      resolvedOrigin: resolvedOrigin,
    );
    final verified = confirmation.verified;
    if (verified == null) return null;

    // 摘要重新计算并核对：字段与实体必须描述同一份 payload。
    final digest = sha256
        .convert(canonicalizeJsonToUtf8(parsed.payloadJson))
        .toString();
    final storedDigest = json['canonicalDigest'];
    if (storedDigest is! String || storedDigest != digest) return null;
    if (verified.canonicalDigest != digest) return null;

    final fetchedAt = json['confirmedAtUtc'];
    final confirmedAt = fetchedAt is String
        ? DateTime.tryParse(fetchedAt)?.toUtc()
        : null;
    if (confirmedAt == null) return null;

    return ManifestCacheEntry(
      requestKey: key,
      canonicalRequestUrl: canonicalUrl,
      confirmedAtUtc: confirmedAt,
      canonicalDigest: digest,
      envelope: parsed,
      etag: etag,
      sanitizedResolvedOrigin: resolvedOrigin,
    );
  }

  @override
  Future<void> save(ManifestRequestKey key, VerifiedManifest manifest) {
    final bound = manifest.requestKey;
    if (bound != null && bound != key) {
      // 把 A 的清单写进 B 的槽位就是本次事故本身；宁可失败也不写。
      // 用失败的 Future 而不是同步抛出：调用方按 await/catch 处理缓存写入失败。
      return Future<void>.error(
        ArgumentError.value(
          bound,
          'manifest.requestKey',
          '清单的请求身份与缓存键不一致（${key.storageKey}）',
        ),
      );
    }
    // 同一个 key 的写入串行化：Windows 上并发 `MoveFileEx` 会互相拒绝访问。
    final name = key.storageKey;
    final previous = _pendingWrites[name] ?? Future<void>.value();
    final next = previous.then<void>(
      (_) => _write(key, manifest),
      onError: (Object _) => _write(key, manifest),
    );
    final settled = next.catchError((Object _) {});
    _pendingWrites[name] = settled;
    return next.whenComplete(() {
      if (identical(_pendingWrites[name], settled)) _pendingWrites.remove(name);
    });
  }

  Future<void> _write(ManifestRequestKey key, VerifiedManifest manifest) async {
    final signature = manifest.manifest.signature;
    await _writer(fileFor(key), {
      'schemaVersion': updateManifestCacheSchemaVersion,
      'requestKey': key.toJson(),
      'canonicalRequestUrl': key.canonicalRequestUrl,
      'confirmedAtUtc': manifest.confirmedAtUtc.toUtc().toIso8601String(),
      'etag': manifest.etag,
      'canonicalDigest': manifest.canonicalDigest,
      'sanitizedResolvedOrigin': manifest.resolvedOrigin,
      'envelope': {
        'payload': manifest.payloadJson,
        'signature': {
          'algorithm': signature.algorithm,
          'keyId': signature.keyId,
          'value': signature.value,
        },
      },
    });
  }

  @override
  Future<void> clear(ManifestRequestKey key) async {
    try {
      final file = fileFor(key);
      if (await file.exists()) await file.delete();
    } on Object {
      // 删除失败不影响正确性：读取时仍会重新验签。
    }
  }

  /// 隔离旧版全局缓存。幂等：连续执行两次结果相同，且最多保留一份留证文件。
  ///
  /// **绝不把旧内容复制进 `latest-stable.json`**：旧文件没有请求身份，猜错就等于让事故复发。
  @override
  Future<void> migrateLegacyIfNeeded() async {
    final legacy = legacyFile;
    try {
      if (!await legacy.exists()) return;
      final quarantine = layout.legacyManifestCacheQuarantineFile;
      if (await quarantine.exists()) {
        // 已经留过一份证据，这一份直接丢弃。
        await legacy.delete();
        return;
      }
      await legacy.rename(quarantine.path);
    } on Object {
      // 迁移失败不影响应用启动：latest 下次会无条件重新拉取。
    }
  }
}
