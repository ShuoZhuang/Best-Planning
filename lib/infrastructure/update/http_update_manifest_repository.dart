// 固定清单仓库（规格 §6.1 / §6.4 / §7.4 / §7.5；1.11.1 事故修复 §4.2）。
//
// 它是整个更新链路**唯一**读取远端清单的地方，也是"假最新版"问题的修复点：
//   · 只请求固定的两个 GitHub 地址，不调用 Releases API，因此不会因为匿名额度被限流；
//   · **条件缓存按请求身份分区**：`304` 只允许读取同一个请求身份的缓存项，ETag 与实体
//     从同一份缓存项一起读出，调用方不再持有 ETag；
//   · `304` 只有在同 key 缓存有效时才等于"没有变化"，否则去掉条件头完整重试一次；
//   · 空响应、非法 JSON、签名失败都返回**失败**，绝不返回"无更新"；
//   · 重定向逐跳校验，最多 5 次，只允许 HTTPS、本仓库路径与 GitHub 官方资产域。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:personal_planner/domain/update/manifest_cache_entry.dart';
import 'package:personal_planner/domain/update/manifest_request_key.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';
import 'package:personal_planner/infrastructure/update/update_network_policy.dart';

/// 更新请求的 `User-Agent`。GitHub 对没有它的请求直接回 403。
const String updateManifestRequestUserAgent =
    'PersonalPlanner-NativeUpdater (+https://github.com/ShuoZhuang/Best-Planning)';

/// 清单响应体上限。一份清单只有几 KB；超过这个量说明拿到的不是清单。
const int updateManifestMaxBodyBytes = 1024 * 1024;

/// 基于 HTTP 的清单仓库。
final class HttpUpdateManifestRepository implements UpdateManifestSource {
  HttpUpdateManifestRepository({
    required this.cache,
    required this.verifier,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.maxBodyBytes = updateManifestMaxBodyBytes,
    this.log,
    DateTime Function()? nowUtc,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final UpdateManifestCache cache;
  final Ed25519ManifestVerifier verifier;

  /// 诊断日志（可选）。只写 key 与状态，不写 URL 查询串或缓存内容。
  final UpdateLogSink? log;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _nowUtc;
  final Duration timeout;
  final int maxBodyBytes;

  /// 同一请求身份的并发 fetch 合并成一个 in-flight Future（INV-05 的可执行形式）。
  final Map<String, Future<ManifestFetchResult>> _inFlight = {};
  bool _legacyMigrationAttempted = false;

  @override
  Future<ManifestFetchResult> fetchLatest({bool forceRefresh = false}) =>
      _singleFlight(const ManifestRequestKey.latestStable(), forceRefresh);

  @override
  Future<ManifestFetchResult> fetchForTag(
    String tag, {
    bool forceRefresh = false,
  }) {
    final key = ManifestRequestKey.tryReleaseTag(tag);
    if (key == null) {
      return Future.value(
        ManifestFetchResult.failed(
          _failure(
            UpdateFailureCode.manifestSourceNotAllowed,
            detail: 'tag=$tag',
          ),
        ),
      );
    }
    return _singleFlight(key, forceRefresh);
  }

  /// 只读 latest 的本地缓存：启动复核用它把磁盘上的包与一份已签名清单对上。
  @override
  Future<VerifiedManifest?> cachedLatest() async {
    const key = ManifestRequestKey.latestStable();
    try {
      final entry = await cache.load(key);
      if (entry == null) return null;
      return await _verifiedFromEntry(key, entry, etag: entry.etag);
    } on Object {
      return null;
    }
  }

  Future<ManifestFetchResult> _singleFlight(
    ManifestRequestKey key,
    bool forceRefresh,
  ) async {
    final pending = _inFlight[key.storageKey];
    if (pending != null) return pending;
    final future = _fetch(key, forceRefresh);
    _inFlight[key.storageKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[key.storageKey], future)) {
        _inFlight.remove(key.storageKey);
      }
    }
  }

  Future<ManifestFetchResult> _fetch(
    ManifestRequestKey key,
    bool forceRefresh,
  ) async {
    await _migrateLegacyOnce();

    final initial = key.canonicalUri;
    if (!UpdateNetworkPolicy.isAllowedManifestUri(initial)) {
      return ManifestFetchResult.failed(
        _failure(
          UpdateFailureCode.manifestSourceNotAllowed,
          detail: key.storageKey,
        ),
      );
    }

    // **唯一**读取条件值的地方：与实体同一次 load 返回（INV-02）。
    ManifestCacheEntry? cached;
    try {
      cached = await cache.load(key);
    } on Object {
      cached = null;
    }
    var conditional = forceRefresh ? null : cached?.etag;

    var current = initial;
    var redirects = 0;
    var retriedWithoutCondition = false;

    while (true) {
      final http.StreamedResponse response;
      try {
        final request = http.Request('GET', current)
          // 自己处理重定向：默认跟随会让"跳到别的仓库"这件事变得不可见。
          ..followRedirects = false
          ..headers['Accept'] = 'application/json'
          ..headers['User-Agent'] = updateManifestRequestUserAgent;
        if (conditional != null && conditional.isNotEmpty) {
          request.headers['If-None-Match'] = conditional;
        }
        response = await _client.send(request).timeout(timeout);
      } on TimeoutException {
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.networkTimeout),
        );
      } on HandshakeException {
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.networkTlsFailed),
        );
      } on SocketException {
        // 断网、DNS 失败。`SocketException` 的字符串带主机名，因此只取原因码。
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.networkOffline),
        );
      } on http.ClientException {
        // 连接被中途关闭与一开始就连不上，对用户是同一件事。
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.networkOffline),
        );
      } on Object {
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.networkHttpFailed),
        );
      }

      final status = response.statusCode;
      final responseEtag = response.headers['etag'];

      if (_isRedirect(status)) {
        final location = response.headers['location'];
        final next = UpdateNetworkPolicy.resolveLocation(current, location);
        if (next == null || !UpdateNetworkPolicy.isAllowedRedirect(next)) {
          await _drain(response);
          return ManifestFetchResult.failed(
            _failure(
              UpdateFailureCode.manifestSourceNotAllowed,
              detail: 'redirect=${_redirectLabel(next ?? current)}',
            ),
          );
        }
        redirects++;
        if (redirects > updateMaxRedirects) {
          await _drain(response);
          return ManifestFetchResult.failed(
            _failure(
              UpdateFailureCode.manifestSourceNotAllowed,
              detail: 'redirects=$redirects',
            ),
          );
        }
        await _drain(response);
        current = next;
        continue;
      }

      if (status == 304) {
        await _drain(response);
        if (conditional == null || conditional.isEmpty) {
          // 没发条件头却收到 304：只可能来自中间层，不能当作"没有变化"。
          return ManifestFetchResult.failed(
            _failure(UpdateFailureCode.manifestNotModifiedWithoutCache),
          );
        }
        // **只读同一个 key**：不同 key 的缓存即使签名有效也不能替代（INV-01）。
        final entry = await _loadQuietly(key);
        final verified = entry == null
            ? null
            : await _verifiedFromEntry(
                key,
                entry,
                etag: responseEtag ?? entry.etag,
              );
        if (verified != null) {
          log?.writeLine('manifest_cache_hit key=${key.storageKey} status=304');
          return ManifestFetchResult.verified(
            verified.copyWith(confirmedAtUtc: _nowUtc(), fromCache: true),
          );
        }
        if (!retriedWithoutCondition) {
          // 缓存缺失或损坏：去掉条件头完整请求一次（规格 §7.4）。
          log?.writeLine(
            'manifest_cache_miss key=${key.storageKey} '
            'action=unconditional_retry',
          );
          retriedWithoutCondition = true;
          conditional = null;
          continue;
        }
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.manifestNotModifiedWithoutCache),
        );
      }

      if (status == 403 || status == 429) {
        await _drain(response);
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.networkHttpFailed, detail: 'HTTP $status'),
        );
      }
      if (status != 200) {
        await _drain(response);
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.networkHttpFailed, detail: 'HTTP $status'),
        );
      }

      final List<int> bodyBytes;
      try {
        bodyBytes = await _readLimited(response);
      } on TimeoutException {
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.networkTimeout),
        );
      } on SocketException {
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.networkOffline),
        );
      } on _BodyTooLarge {
        return ManifestFetchResult.failed(
          _failure(
            UpdateFailureCode.manifestInvalidJson,
            detail: 'body>=$maxBodyBytes',
          ),
        );
      } on Object {
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.networkOffline),
        );
      }

      if (bodyBytes.isEmpty) {
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.manifestEmpty),
        );
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bodyBytes));
      } on Object {
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.manifestInvalidJson),
        );
      }

      final parsed = UpdateManifestEnvelope.tryParse(decoded);
      if (parsed is ManifestParseFailure) {
        return ManifestFetchResult.failed(
          _failure(parsed.code, detail: key.storageKey),
        );
      }
      if (parsed is! UpdateManifestEnvelope) {
        return ManifestFetchResult.failed(
          _failure(UpdateFailureCode.manifestInvalidJson),
        );
      }

      final verification = await verifier.verify(
        parsed,
        etag: responseEtag,
        requestKey: key,
        // 只保留 scheme + host + path，不保存临时重定向的查询串（UPD-INC-028）。
        resolvedOrigin: sanitizeResolvedOrigin(current),
      );
      final verified = verification.verified;
      if (verified == null) {
        return ManifestFetchResult.failed(
          verification.failure ??
              _failure(UpdateFailureCode.manifestSignatureInvalid),
        );
      }

      // **只缓存已验证清单，且只写自己那个 key**：写失败不影响本次结果。
      try {
        await cache.save(key, verified);
      } on Object {
        // 忽略：下次仍可完整请求。
      }
      return ManifestFetchResult.verified(verified);
    }
  }

  Future<ManifestCacheEntry?> _loadQuietly(ManifestRequestKey key) async {
    try {
      return await cache.load(key);
    } on Object {
      return null;
    }
  }

  /// 把缓存项重新验签成 [VerifiedManifest]；任何不一致都返回 `null`（等价于没有缓存）。
  Future<VerifiedManifest?> _verifiedFromEntry(
    ManifestRequestKey key,
    ManifestCacheEntry entry, {
    String? etag,
  }) async {
    if (entry.requestKey != key) return null;
    final confirmation = await verifier.verify(
      entry.envelope,
      etag: etag ?? entry.etag,
      requestKey: key,
      resolvedOrigin: entry.sanitizedResolvedOrigin,
    );
    final verified = confirmation.verified;
    if (verified == null) return null;
    if (verified.canonicalDigest != entry.canonicalDigest) return null;
    return verified;
  }

  Future<void> _migrateLegacyOnce() async {
    if (_legacyMigrationAttempted) return;
    _legacyMigrationAttempted = true;
    try {
      await cache.migrateLegacyIfNeeded();
    } on Object {
      // 迁移失败只影响"能否复用旧缓存"，而旧缓存本来就不允许被复用。
    }
  }

  Future<List<int>> _readLimited(http.StreamedResponse response) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response.stream.timeout(timeout)) {
      total += chunk.length;
      if (total > maxBodyBytes) throw const _BodyTooLarge();
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _drain(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>().timeout(timeout);
    } on Object {
      // 丢弃失败不需要上报：连接本来就要关闭。
    }
  }

  UpdateFailure _failure(UpdateFailureCode code, {String? detail}) =>
      UpdateFailure(code, detail: detail, occurredAtUtc: _nowUtc());

  /// 重定向诊断只保留"允许/不允许"级别的信息，不写完整临时 URL。
  static String _redirectLabel(Uri uri) =>
      sanitizeResolvedOrigin(uri) ?? 'invalid';

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  /// 释放内部创建的 HTTP 客户端。注入的客户端由调用方负责。
  void close() {
    if (_ownsClient) _client.close();
  }
}

final class _BodyTooLarge implements Exception {
  const _BodyTooLarge();
}
