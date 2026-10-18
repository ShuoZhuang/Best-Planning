// 固定清单仓库：304/缓存/重定向/失败分类（UPD-001～UPD-005、UPD-008）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';
import 'package:personal_planner/infrastructure/update/file_update_manifest_cache.dart';
import 'package:personal_planner/infrastructure/update/http_update_manifest_repository.dart';

import '../../support/update_fixtures.dart';

void main() {
  late Directory directory;
  late Ed25519ManifestVerifier verifier;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('update_repo_test_');
    verifier = await createTestVerifier();
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  FileUpdateManifestCache createCache() =>
      FileUpdateManifestCache(directory: directory, verifier: verifier);

  test('200 + 合法签名：返回已验证清单并写入缓存', () async {
    final json = await signedManifestJson(validManifestPayload());
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient(
        (request) async => _manifestResponse(json, etag: '"v1"'),
      ),
    );

    final result = await repository.fetchLatest();

    expect(result.isVerified, isTrue, reason: '${result.failure?.code}');
    expect(result.verified!.manifest.semanticVersion.value, '1.9.0');
    expect(result.verified!.fromCache, isFalse);
    expect(result.verified!.etag, '"v1"');
    expect(await createCache().load(), isNotNull, reason: '合法清单应被缓存');
  });

  test('只请求固定清单地址，不带任何查询参数或本地数据', () async {
    final json = await signedManifestJson(validManifestPayload());
    Uri? requested;
    http.Request? seen;
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient((request) async {
        requested = request.url;
        seen = request;
        return _manifestResponse(json);
      }),
    );

    await repository.fetchLatest();

    expect(requested.toString(), updateManifestLatestUrl);
    expect(requested!.query, isEmpty);
    expect(seen!.headers.keys.map((key) => key.toLowerCase()), isNot(contains('cookie')));
    expect(seen!.headers.keys.map((key) => key.toLowerCase()), isNot(contains('authorization')));
    expect(seen!.headers['User-Agent'], contains('Best-Planning'));
  });

  test('签名无效的 200 是失败，不是“已是最新”', () async {
    final unknownSigner = await createTestSigner(keyId: 'unknown-key');
    final json = await signedManifestJson(
      validManifestPayload(),
      signer: unknownSigner,
    );
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient((request) async => _manifestResponse(json)),
    );

    final result = await repository.fetchLatest();

    expect(result.isVerified, isFalse);
    expect(
      result.failure!.code,
      UpdateFailureCode.manifestSignatureInvalid,
    );
    expect(
      classificationFor(result.failure!.code),
      UpdateCheckClassification.sourceInvalid,
    );
    expect(await createCache().load(), isNull, reason: '未通过验签的清单不得缓存');
  });

  test('空响应是“暂时无法确认”', () async {
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient((request) async => _manifestResponse('')),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.manifestEmpty);
    expect(
      classificationFor(result.failure!.code),
      UpdateCheckClassification.temporarilyUnconfirmed,
    );
  });

  test('304 且缓存有效：用缓存清单继续版本比较', () async {
    final json = await signedManifestJson(validManifestPayload());
    var calls = 0;
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient((request) async {
        calls++;
        if (calls == 1) return _manifestResponse(json, etag: '"v1"');
        expect(request.headers['If-None-Match'], '"v1"');
        return http.Response('', 304, headers: {'etag': '"v1"'});
      }),
    );

    final first = await repository.fetchLatest();
    expect(first.isVerified, isTrue);
    final second = await repository.fetchLatest(etag: first.verified!.etag);

    expect(second.isVerified, isTrue, reason: '${second.failure?.code}');
    expect(second.verified!.fromCache, isTrue);
    expect(second.verified!.manifest.msixVersion.value, '1.9.0.0');
    expect(calls, 2, reason: '304 之后不应再发第二次完整请求');
  });

  test('304 但缓存缺失：去掉条件头完整重试一次', () async {
    final json = await signedManifestJson(validManifestPayload());
    var calls = 0;
    var sawConditional = false;
    var retriedWithoutCondition = false;
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient((request) async {
        calls++;
        if (request.headers.containsKey('If-None-Match')) {
          sawConditional = true;
          return http.Response('', 304);
        }
        retriedWithoutCondition = true;
        return _manifestResponse(json, etag: '"v2"');
      }),
    );

    final result = await repository.fetchLatest(etag: '"stale"');

    expect(result.isVerified, isTrue, reason: '${result.failure?.code}');
    expect(sawConditional, isTrue);
    expect(retriedWithoutCondition, isTrue, reason: '缓存缺失时必须重新完整请求');
    expect(calls, 2);
  });

  test('304 且没有缓存、完整重试仍 304：暂时无法确认', () async {
    var calls = 0;
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient((request) async {
        calls++;
        return http.Response('', 304);
      }),
    );

    final result = await repository.fetchLatest(etag: '"stale"');

    expect(result.isVerified, isFalse);
    expect(
      result.failure!.code,
      UpdateFailureCode.manifestNotModifiedWithoutCache,
    );
    expect(calls, 2, reason: '只允许一次完整重试');
  });

  test('允许的重定向会跟随，且只跟随 5 次以内', () async {
    final json = await signedManifestJson(validManifestPayload());
    var calls = 0;
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response('', 302, headers: {
            'location':
                'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/update-manifest.json',
          });
        }
        return _manifestResponse(json);
      }),
    );

    final result = await repository.fetchLatest();
    expect(result.isVerified, isTrue, reason: '${result.failure?.code}');
    expect(calls, 2);
  });

  test('重定向到白名单外主机被拒绝', () async {
    var calls = 0;
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient((request) async {
        calls++;
        return http.Response('', 302, headers: {
          'location': 'https://evil.example/update-manifest.json',
        });
      }),
    );

    final result = await repository.fetchLatest();
    expect(
      result.failure!.code,
      UpdateFailureCode.manifestSourceNotAllowed,
    );
    expect(calls, 1, reason: '不允许的目标不应再发请求');
  });

  test('超过 5 次重定向被拒绝', () async {
    var calls = 0;
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient((request) async {
        calls++;
        return http.Response('', 302, headers: {
          'location':
              'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.$calls/update-manifest.json',
        });
      }),
    );

    final result = await repository.fetchLatest();
    expect(
      result.failure!.code,
      UpdateFailureCode.manifestSourceNotAllowed,
    );
    expect(result.failure!.detail, contains('redirects=6'));
  });

  test('403/429 是暂时的网络失败，不是“已是最新”', () async {
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient(
        (request) async => http.Response('rate limited', 429),
      ),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.networkHttpFailed);
    expect(
      classificationFor(result.failure!.code),
      UpdateCheckClassification.temporarilyUnconfirmed,
    );
  });

  test('连接失败映射成离线', () async {
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient(
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
        return _manifestResponse('{}');
      }),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.networkTimeout);
  });

  test('非法 JSON 被拒绝，且不当作无更新', () async {
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: MockClient(
        (request) async => _manifestResponse('{"payload":'),
      ),
    );

    final result = await repository.fetchLatest();
    expect(result.failure!.code, UpdateFailureCode.manifestInvalidJson);
  });
}

http.Response _manifestResponse(String body, {String? etag}) => http.Response(
  body,
  200,
  headers: {
    'content-type': 'application/json; charset=utf-8',
    'etag': ?etag,
  },
);

