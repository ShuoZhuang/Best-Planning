// 固定清单仓库（规格 §6.1 / §6.4 / §7.4 / §7.5）。
//
// 它是整个更新链路**唯一**读取远端清单的地方，也是"假最新版"问题的修复点：
//   · 只请求固定的两个 GitHub 地址，不调用 Releases API，因此不会因为匿名额度被限流；
//   · `304` 只有在本地缓存有效时才等于"没有变化"，否则去掉条件头完整重试；
//   · 空响应、非法 JSON、签名失败都返回**失败**，绝不返回"无更新"；
//   · 重定向逐跳校验，最多 5 次，只允许 HTTPS、本仓库路径与 GitHub 官方资产域。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
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
    DateTime Function()? nowUtc,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final UpdateManifestCache cache;
  final Ed25519ManifestVerifier verifier;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _nowUtc;
  final Duration timeout;
  final int maxBodyBytes;

  @override
  Future<ManifestFetchResult> fetchLatest({String? etag}) =>
      _fetch(updateManifestLatestUrl, etag: etag);

  @override
  Future<ManifestFetchResult> fetchForTag(String tag, {String? etag}) {
    if (!RegExp(r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')
        .hasMatch(tag)) {
      return Future.value(
        ManifestFetchResult.failed(
          _failure(
            UpdateFailureCode.manifestSourceNotAllowed,
            detail: 'tag=$tag',
          ),
        ),
      );
    }
    return _fetch(updateManifestUrlForTag(tag).toString(), etag: etag);
  }

  Future<ManifestFetchResult> _fetch(String url, {String? etag}) async {
    final initial = Uri.tryParse(url);
    if (initial == null || !UpdateNetworkPolicy.isAllowedManifestUri(initial)) {
      return ManifestFetchResult.failed(
        _failure(UpdateFailureCode.manifestSourceNotAllowed, detail: url),
      );
    }

    var current = initial;
    var conditional = etag;
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
              detail: 'redirect=${next ?? location ?? 'missing'}',
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
        final cached = await cache.load();
        if (cached != null) {
          return ManifestFetchResult.verified(
            cached.copyWith(
              confirmedAtUtc: _nowUtc(),
              fromCache: true,
              etag: responseEtag ?? cached.etag,
            ),
          );
        }
        if (!retriedWithoutCondition) {
          // 缓存缺失或损坏：去掉条件头完整请求一次（规格 §7.4）。
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
          _failure(parsed.code, detail: current.toString()),
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
        manifestUrl: current.toString(),
      );
      final verified = verification.verified;
      if (verified == null) {
        return ManifestFetchResult.failed(
          verification.failure ??
              _failure(UpdateFailureCode.manifestSignatureInvalid),
        );
      }

      // **只缓存已验证清单**：写失败不影响本次结果（缓存只是加速与 304 的依据）。
      try {
        await cache.save(verified);
      } on Object {
        // 忽略：下次仍可完整请求。
      }
      return ManifestFetchResult.verified(verified);
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
