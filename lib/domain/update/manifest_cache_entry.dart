// 缓存项：请求身份、ETag 与清单实体的**原子绑定**（1.11.1 事故修复 §4.2）。
//
// 事故里 ETag 存在 `state.json`、实体存在 `update-manifest.cache.json`，两个文件之间没有
// 任何绑定关系；只要其中一个被另一种请求覆盖，`304` 就会拿错实体。这里的规则是：
// **一次读取同时返回 envelope、ETag 与身份**，调用方没有机会把它们拆开。
import 'package:personal_planner/domain/update/manifest_request_key.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';

/// 一份已验证清单的缓存项。
final class ManifestCacheEntry {
  const ManifestCacheEntry({
    required this.requestKey,
    required this.canonicalRequestUrl,
    required this.confirmedAtUtc,
    required this.canonicalDigest,
    required this.envelope,
    this.etag,
    this.sanitizedResolvedOrigin,
  });

  /// 本项属于哪一个请求。读取时必须与调用方请求的身份一致，否则视为没有缓存。
  final ManifestRequestKey requestKey;

  /// 固定请求地址（不是最终重定向地址）。
  final String canonicalRequestUrl;

  final DateTime confirmedAtUtc;

  /// 规范化 payload 的 SHA-256；读取时重新计算并核对。
  final String canonicalDigest;

  /// 原始信封（payload + signature）。验签针对的就是这份内容。
  final UpdateManifestEnvelope envelope;

  final String? etag;

  /// 最终解析到的来源：只保留 `scheme + host + path`，**不含 query 与 fragment**。
  final String? sanitizedResolvedOrigin;
}
