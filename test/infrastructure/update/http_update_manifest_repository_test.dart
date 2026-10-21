// 固定清单仓库：请求身份、304 绑定、重定向、失败分类（UPD-001～UPD-005、UPD-008）。
//
// 1.11.1 的重点是**条件缓存与请求身份绑定**：这里的每个 304 用例都同时断言"读的是哪一个
// key 的缓存"，否则测试会在缺陷存在时仍然变绿（这正是事故没被发现的原因）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_planner/domain/update/manifest_cache_entry.dart';
import 'package:personal_planner/domain/update/manifest_request_key.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';
import 'package:personal_planner/infrastructure/update/file_update_manifest_cache.dart';
import 'package:personal_planner/infrastructure/update/http_update_manifest_repository.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_fixtures.dart';

void main() {
  late Directory directory;
  late UpdateStorageLayout layout;
  late Ed25519ManifestVerifier verifier;
  late String json090;
  late String json1110;
  late String json1102;

  const latestKey = ManifestRequestKey.latestStable();
  final tag1102Key = ManifestRequestKey.releaseTag('v1.10.2');

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('update_repo_test_');
    layout = UpdateStorageLayout(root: directory);
    verifier = await createTestVerifier();
    json090 = await signedManifestJson(validManifestPayload());
    json1110 = await signedManifestJson(
      validManifestPayload(version: '1.11.0', buildNumber: 52),
    );
    json1102 = await signedManifestJson(
      validManifestPayload(version: '1.10.2', buildNumber: 51),
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  FileUpdateManifestCache createCache() =>
      FileUpdateManifestCache(layout: layout, verifier: verifier);

  HttpUpdateManifestRepository createRepository(
    http.Client client, {
    UpdateManifestCache? cache,
  }) => HttpUpdateManifestRepository(
    cache: cache ?? createCache(),
    verifier: verifier,
    client: client,
  );

  bool isLatest(http.BaseRequest request) =>
      request.url.toString() == updateManifestLatestUrl;
  bool isTag(http.BaseRequest request, String tag) =>
      request.url.toString() == updateManifestUrlForTag(tag).toString();

  test('200 + 合法签名：返回已验证清单并按 latest 身份写入缓存', () async {
    final repository = createRepository(
      MockClient((request) async => _json(json090, etag: '"v1"')),
    );

    final result = await repository.fetchLatest();

    expect(result.isVerified, isTrue, reason: '${result.failure?.code}');
    expect(result.verified!.manifest.semanticVersion.value, '1.9.0');
    expect(result.verified!.fromCache, isFalse);
    expect(result.verified!.etag, '"v1"');
    expect(result.verified!.requestKey, latestKey);
    expect(await createCache().load(latestKey), isNotNull);
    expect(await createCache().load(tag1102Key), isNull);
  });

  test('只请求固定清单地址，不带任何查询参数或本地数据', () async {
    Uri? requested;
    http.Request? seen;
    final repository = createRepository(
      MockClient((request) async {
        requested = request.url;
        seen = request;
        return _json(json090);
      }),
    );

    await repository.fetchLatest();

    expect(requested.toString(), updateManifestLatestUrl);
    expect(requested!.query, isEmpty);
    expect(
      seen!.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('cookie')),
    );
    expect(
      seen!.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('authorization')),
    );
    expect(seen!.headers['User-Agent'], contains('Best-Planning'));
  });

  test('签名无效的 200 是失败，不是"已是最新"', () async {
    final unknownSigner = await createTestSigner(keyId: 'unknown-key');
    final json = await signedManifestJson(
      validManifestPayload(),
      signer: unknownSigner,
    );
    final repository = createRepository(
      MockClient((request) async => _json(json)),
    );

    final result = await repository.fetchLatest();

    expect(result.isVerified, isFalse);
    expect(result.failure!.code, UpdateFailureCode.manifestSignatureInvalid);
    expect(
      classificationFor(result.failure!.code),
      UpdateCheckClassification.sourceInvalid,
    );
    expect(await createCache().load(latestKey), isNull, reason: '未通过验签的清单不得缓存');
  });

  test('空响应是"暂时无法确认"', () async {
    final repository = createRepository(
      MockClient((request) async => _json('')),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.manifestEmpty);
    expect(
      classificationFor(result.failure!.code),
      UpdateCheckClassification.temporarilyUnconfirmed,
    );
  });

  test('304 且同 key 缓存有效：用缓存清单继续版本比较', () async {
    var calls = 0;
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        if (calls == 1) return _json(json090, etag: '"v1"');
        expect(request.headers['If-None-Match'], '"v1"');
        return http.Response('', 304, headers: {'etag': '"v1"'});
      }),
    );

    final first = await repository.fetchLatest();
    expect(first.isVerified, isTrue);
    final second = await repository.fetchLatest();

    expect(second.isVerified, isTrue, reason: '${second.failure?.code}');
    expect(second.verified!.fromCache, isTrue);
    expect(second.verified!.manifest.msixVersion.value, '1.9.0.0');
    expect(calls, 2, reason: '304 之后不应再发第二次完整请求');
  });

  test('latest 200→tag 200→latest 304 返回 latest 缓存（事故序列）', () async {
    var calls = 0;
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        if (isLatest(request)) {
          if (request.headers['If-None-Match'] == '"latest-1"') {
            return http.Response('', 304, headers: {'etag': '"latest-1"'});
          }
          return _json(json1110, etag: '"latest-1"');
        }
        if (isTag(request, 'v1.10.2')) {
          return _json(json1102, etag: '"tag-1102"');
        }
        return http.Response('unexpected', 404);
      }),
    );

    final first = await repository.fetchLatest();
    expect(first.verified!.manifest.msixVersion.value, '1.11.0.0');
    final tag = await repository.fetchForTag('v1.10.2');
    expect(tag.verified!.manifest.msixVersion.value, '1.10.2.0');

    final confirm = await repository.fetchLatest();
    expect(confirm.isVerified, isTrue);
    expect(confirm.verified!.manifest.msixVersion.value, '1.11.0.0');
    expect(confirm.verified!.requestKey, latestKey);
    expect(calls, 3);
  });

  test('tag 200→latest 200→tag 304 返回对应 tag 缓存', () async {
    var calls = 0;
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        if (isLatest(request)) {
          return _json(json1110, etag: '"latest-1"');
        }
        if (isTag(request, 'v1.10.2')) {
          if (request.headers['If-None-Match'] == '"tag-1102"') {
            return http.Response('', 304, headers: {'etag': '"tag-1102"'});
          }
          return _json(json1102, etag: '"tag-1102"');
        }
        return http.Response('unexpected', 404);
      }),
    );

    final tag = await repository.fetchForTag('v1.10.2');
    expect(tag.verified!.manifest.msixVersion.value, '1.10.2.0');
    await repository.fetchLatest();

    final tagConfirm = await repository.fetchForTag('v1.10.2');
    expect(tagConfirm.isVerified, isTrue);
    expect(tagConfirm.verified!.manifest.msixVersion.value, '1.10.2.0');
    expect(tagConfirm.verified!.requestKey, tag1102Key);
    expect(calls, 3);
  });

  test('latest 304 找不到 latest 缓存时无条件重试', () async {
    var calls = 0;
    final cache = _FlakyCache(createCache());
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        if (request.headers.containsKey('If-None-Match')) {
          return http.Response('', 304);
        }
        return _json(json090, etag: '"v2"');
      }),
      cache: cache,
    );
    // 先放一份有效 latest 缓存，让下一次请求带上条件头。
    await repository.fetchLatest();
    cache.dropAfterFirstLoad = true;
    cache.loads = 0;
    calls = 0;

    final result = await repository.fetchLatest();

    expect(result.isVerified, isTrue, reason: '${result.failure?.code}');
    expect(calls, 2, reason: '缓存缺失时必须去掉条件头完整重试一次');
    expect(result.verified!.manifest.msixVersion.value, '1.9.0.0');
  });

  test('tag 304 不能读取 latest 缓存', () async {
    var calls = 0;
    // 一个把任意 key 都指向 latest 实体的缓存：等价于 1.11.0 的共享缓存。
    final cache = _AliasingCache(createCache());
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        if (isLatest(request)) {
          return _json(json1110, etag: '"latest-1"');
        }
        if (isTag(request, 'v1.10.2')) {
          if (request.headers.containsKey('If-None-Match')) {
            return http.Response('', 304, headers: {'etag': '"latest-1"'});
          }
          return _json(json1102, etag: '"tag-1102"');
        }
        return http.Response('unexpected', 404);
      }),
      cache: cache,
    );

    await repository.fetchLatest();
    final tag = await repository.fetchForTag('v1.10.2');

    expect(tag.isVerified, isTrue);
    expect(
      tag.verified!.manifest.msixVersion.value,
      '1.10.2.0',
      reason: 'tag 的 304 只能使用 tag 自己的缓存；latest 的实体不是它的答案',
    );
    expect(tag.verified!.requestKey, tag1102Key);
    expect(calls, 3, reason: '缓存不匹配时必须无条件重新请求 tag');
  });

  test('同 key 并发只发一个网络请求', () async {
    var calls = 0;
    final gate = Completer<void>();
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        await gate.future;
        return _json(json090, etag: '"v1"');
      }),
    );

    final first = repository.fetchLatest();
    final second = repository.fetchLatest();
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    final results = await Future.wait([first, second]);

    expect(calls, 1, reason: '同 key 的并发请求必须合并');
    expect(results.every((result) => result.isVerified), isTrue);
  });

  test('不同 key 并发且反序完成仍各自正确', () async {
    final latestGate = Completer<void>();
    final tagGate = Completer<void>();
    final repository = createRepository(
      MockClient((request) async {
        if (isLatest(request)) {
          await latestGate.future;
          return _json(json1110, etag: '"latest-1"');
        }
        if (isTag(request, 'v1.10.2')) {
          await tagGate.future;
          return _json(json1102, etag: '"tag-1102"');
        }
        return http.Response('unexpected', 404);
      }),
    );

    final latestFuture = repository.fetchLatest();
    final tagFuture = repository.fetchForTag('v1.10.2');
    tagGate.complete();
    await Future<void>.delayed(Duration.zero);
    latestGate.complete();

    final tag = await tagFuture;
    final latest = await latestFuture;
    expect(tag.verified!.manifest.msixVersion.value, '1.10.2.0');
    expect(latest.verified!.manifest.msixVersion.value, '1.11.0.0');
    expect(await createCache().load(latestKey), isNotNull);
    expect(await createCache().load(tag1102Key), isNotNull);
  });

  test('诊断来源不含 query 与 fragment', () async {
    final repository = createRepository(
      MockClient((request) async {
        if (request.url.host == 'github.com') {
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  'https://objects.githubusercontent.com/assets/update-manifest.json'
                  '?token=secret-token&expires=1#fragment',
            },
          );
        }
        return _json(json090);
      }),
    );

    final result = await repository.fetchLatest();

    expect(result.isVerified, isTrue, reason: '${result.failure?.code}');
    final origin = result.verified!.resolvedOrigin;
    expect(origin, isNotNull);
    expect(origin, isNot(contains('token')));
    expect(origin, isNot(contains('?')));
    expect(origin, isNot(contains('#')));
    expect(
      origin,
      'https://objects.githubusercontent.com/assets/update-manifest.json',
    );
  });

  test('forceRefresh 不发送 If-None-Match', () async {
    final headers = <String?>[];
    final repository = createRepository(
      MockClient((request) async {
        headers.add(request.headers['If-None-Match']);
        return _json(json090, etag: '"v1"');
      }),
    );

    await repository.fetchLatest();
    await repository.fetchLatest(forceRefresh: true);

    expect(headers.length, 2);
    expect(headers[0], isNull);
    expect(headers[1], isNull, reason: '强制刷新不得发送条件头');
  });

  test('304 且没有缓存、完整重试仍 304：暂时无法确认', () async {
    var calls = 0;
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        return http.Response('', 304);
      }),
    );

    final result = await repository.fetchLatest();

    expect(result.isVerified, isFalse);
    expect(
      result.failure!.code,
      UpdateFailureCode.manifestNotModifiedWithoutCache,
    );
    expect(calls, 1, reason: '没有条件头却收到 304 时不能重试成"无更新"');
  });

  test('允许的重定向会跟随，且只跟随 5 次以内', () async {
    var calls = 0;
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '',
            302,
            headers: {
              'location': 'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/update-manifest.json',
            },
          );
        }
        return _json(json090);
      }),
    );

    final result = await repository.fetchLatest();
    expect(result.isVerified, isTrue, reason: '${result.failure?.code}');
    expect(calls, 2);
  });

  test('重定向到白名单外主机被拒绝', () async {
    var calls = 0;
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        return http.Response(
          '',
          302,
          headers: {'location': 'https://evil.example/update-manifest.json'},
        );
      }),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.manifestSourceNotAllowed);
    expect(calls, 1, reason: '不允许的目标不应再发请求');
  });

  test('超过 5 次重定向被拒绝', () async {
    var calls = 0;
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        return http.Response(
          '',
          302,
          headers: {
            'location':
                'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.$calls/update-manifest.json',
          },
        );
      }),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.manifestSourceNotAllowed);
    expect(result.failure!.detail, contains('redirects=6'));
  });

  test('403/429 是暂时的网络失败，不是"已是最新"', () async {
    final repository = createRepository(
      MockClient((request) async => http.Response('rate limited', 429)),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.networkHttpFailed);
    expect(
      classificationFor(result.failure!.code),
      UpdateCheckClassification.temporarilyUnconfirmed,
    );
  });

  test('连接失败映射成离线', () async {
    final repository = createRepository(
      MockClient(
        (request) async => throw http.ClientException('connection closed'),
      ),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.networkOffline);
  });

  test('请求超时映射成超时', () async {
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      timeout: const Duration(milliseconds: 30),
      client: MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return _json('{}');
      }),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.networkTimeout);
  });

  test('非法 JSON 被拒绝，且不当作无更新', () async {
    final repository = createRepository(
      MockClient((request) async => _json('{"payload":')),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.manifestInvalidJson);
  });

  test('cachedLatest 只读本地缓存，不产生网络请求', () async {
    var calls = 0;
    final cache = createCache();
    final repository = createRepository(
      MockClient((request) async {
        calls++;
        return _json(json1110, etag: '"latest-1"');
      }),
      cache: cache,
    );

    expect(await repository.cachedLatest(), isNull);
    await repository.fetchLatest();
    calls = 0;

    final cached = await repository.cachedLatest();
    expect(cached, isNotNull);
    expect(cached!.manifest.msixVersion.value, '1.11.0.0');
    expect(calls, 0, reason: '启动复核不允许发网络请求');
  });
}

http.Response _json(String body, {String? etag}) => http.Response(
  body,
  200,
  headers: {'content-type': 'application/json; charset=utf-8', 'etag': ?etag},
);

/// 模拟"保存后读不到"的缓存：用于证明 304 时会去掉条件头完整重试。
final class _FlakyCache implements UpdateManifestCache {
  _FlakyCache(this.inner);

  final UpdateManifestCache inner;
  bool dropAfterFirstLoad = false;
  int loads = 0;

  @override
  Future<ManifestCacheEntry?> load(ManifestRequestKey key) async {
    loads++;
    if (dropAfterFirstLoad && loads > 1) return null;
    return inner.load(key);
  }

  @override
  Future<void> save(ManifestRequestKey key, VerifiedManifest manifest) =>
      inner.save(key, manifest);

  @override
  Future<void> clear(ManifestRequestKey key) => inner.clear(key);

  @override
  Future<void> migrateLegacyIfNeeded() => inner.migrateLegacyIfNeeded();
}

/// 一个"任何 key 都返回 latest 实体"的缓存：等价于 1.11.0 的共享缓存缺陷。
final class _AliasingCache implements UpdateManifestCache {
  _AliasingCache(this.inner);

  final UpdateManifestCache inner;

  @override
  Future<ManifestCacheEntry?> load(ManifestRequestKey key) async =>
      inner.load(const ManifestRequestKey.latestStable());

  @override
  Future<void> save(ManifestRequestKey key, VerifiedManifest manifest) =>
      inner.save(key, manifest);

  @override
  Future<void> clear(ManifestRequestKey key) => inner.clear(key);

  @override
  Future<void> migrateLegacyIfNeeded() => inner.migrateLegacyIfNeeded();
}
