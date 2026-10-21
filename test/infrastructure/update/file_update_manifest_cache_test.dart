// 分区清单缓存（1.11.1 修复 §4.2 / §4.3）。
//
// 事故的核心是"latest 与 tag 共用一个缓存文件"，因此这里的断言全部围绕**身份**：
// 路径不同、写入互不覆盖、读取核对身份、旧格式只隔离、篡改即失效。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/manifest_request_key.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';
import 'package:personal_planner/infrastructure/update/file_update_manifest_cache.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_fixtures.dart';

void main() {
  late Directory directory;
  late UpdateStorageLayout layout;
  late Ed25519ManifestVerifier verifier;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('manifest_cache_test_');
    layout = UpdateStorageLayout(root: directory);
    verifier = await createTestVerifier();
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  FileUpdateManifestCache createCache({
    Future<void> Function(File file, Object? json)? writer,
  }) => FileUpdateManifestCache(
    layout: layout,
    verifier: verifier,
    writer: writer,
  );

  Future<VerifiedManifest> manifestFor(
    ManifestRequestKey key, {
    String version = '1.9.0',
    int buildNumber = 46,
    String? etag,
  }) async {
    final envelope = UpdateManifestEnvelope.tryParse(
      await signedManifestEnvelope(
        validManifestPayload(version: version, buildNumber: buildNumber),
      ),
    ) as UpdateManifestEnvelope;
    final result = await verifier.verify(envelope, etag: etag, requestKey: key);
    return result.verified!;
  }

  const latest = ManifestRequestKey.latestStable();
  final tag1102 = ManifestRequestKey.releaseTag('v1.10.2');
  final tag1110 = ManifestRequestKey.releaseTag('v1.11.0');

  test('保存后可以读回请求身份、ETag 与摘要', () async {
    final cache = createCache();
    final verified = await manifestFor(
      latest,
      version: '1.11.0',
      buildNumber: 52,
      etag: '"abc"',
    );

    await cache.save(latest, verified);
    final loaded = await cache.load(latest);

    expect(loaded, isNotNull);
    expect(loaded!.requestKey, latest);
    expect(loaded.etag, '"abc"');
    expect(loaded.canonicalDigest, verified.canonicalDigest);
    expect(
      loaded.envelope.payloadJson['release'],
      containsPair('msixVersion', '1.11.0.0'),
    );
    expect(loaded.canonicalRequestUrl, latest.canonicalRequestUrl);
  });

  test('latest 与 tag 的缓存文件路径不同', () {
    expect(
      layout.manifestCacheFile(latest).path,
      isNot(layout.manifestCacheFile(tag1102).path),
    );
    expect(
      layout.manifestCacheFile(latest).path.replaceAll('\\', '/'),
      endsWith('manifests/latest-stable.json'),
    );
    expect(
      layout.manifestCacheFile(tag1102).path.replaceAll('\\', '/'),
      endsWith('manifests/tags/v1.10.2.json'),
    );
  });

  test('两个 tag 的缓存文件路径不同', () {
    expect(
      layout.manifestCacheFile(tag1102).path,
      isNot(layout.manifestCacheFile(tag1110).path),
    );
  });

  test('latest 写入后 tag 写入不改变 latest', () async {
    final cache = createCache();
    await cache.save(
      latest,
      await manifestFor(latest, version: '1.11.0', buildNumber: 52),
    );
    await cache.save(
      tag1102,
      await manifestFor(tag1102, version: '1.10.2', buildNumber: 51),
    );

    final latestEntry = await cache.load(latest);
    final tagEntry = await cache.load(tag1102);
    expect(latestEntry, isNotNull);
    expect(tagEntry, isNotNull);
    expect(
      latestEntry!.envelope.payloadJson['release'],
      containsPair('msixVersion', '1.11.0.0'),
    );
    expect(
      tagEntry!.envelope.payloadJson['release'],
      containsPair('msixVersion', '1.10.2.0'),
    );
  });

  test('并发保存不同 key，二者都能读回', () async {
    final cache = createCache();
    await Future.wait([
      cache.save(
        latest,
        await manifestFor(latest, version: '1.11.0', buildNumber: 52),
      ),
      cache.save(
        tag1102,
        await manifestFor(tag1102, version: '1.10.2', buildNumber: 51),
      ),
      cache.save(
        tag1110,
        await manifestFor(tag1110, version: '1.11.0', buildNumber: 52),
      ),
    ]);

    expect(await cache.load(latest), isNotNull);
    expect(await cache.load(tag1102), isNotNull);
    expect(await cache.load(tag1110), isNotNull);
  });

  test('把某个请求的清单写进另一个 key 的槽位被拒绝', () async {
    final cache = createCache();
    final tagManifest = await manifestFor(
      tag1102,
      version: '1.10.2',
      buildNumber: 51,
    );
    final mismatched = VerifiedManifest(
      manifest: tagManifest.manifest,
      payloadJson: tagManifest.payloadJson,
      canonicalDigest: tagManifest.canonicalDigest,
      confirmedAtUtc: tagManifest.confirmedAtUtc,
      requestKey: tag1102,
      etag: '"tag"',
    );

    await expectLater(
      cache.save(latest, mismatched),
      throwsA(isA<ArgumentError>()),
      reason: '把 A 的清单写进 B 的槽位必须被拒绝',
    );
    expect(await cache.load(latest), isNull);
  });

  test('文件内 requestKey 被改成另一个 key 时返回 null', () async {
    final cache = createCache();
    await cache.save(
      latest,
      await manifestFor(latest, version: '1.11.0', buildNumber: 52),
    );
    final file = layout.manifestCacheFile(latest);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    (raw['requestKey']! as Map)['kind'] = 'releaseTag';
    (raw['requestKey']! as Map)['tag'] = 'v1.10.2';
    await file.writeAsString(jsonEncode(raw));

    expect(await cache.load(latest), isNull);
  });

  test('schema v1 的全局缓存被隔离，且绝不被当成 latest', () async {
    final legacy = layout.legacyManifestCacheFile;
    await legacy.writeAsString(
      '{"schemaVersion":1,"etag":"\\"v1\\"","envelope":{}}',
    );
    final cache = createCache();

    await cache.migrateLegacyIfNeeded();

    expect(await legacy.exists(), isFalse);
    expect(await layout.legacyManifestCacheQuarantineFile.exists(), isTrue);
    expect(await cache.load(latest), isNull, reason: '旧缓存没有请求身份，不能是 latest');
    // 幂等：再执行一次不改变结果。
    await cache.migrateLegacyIfNeeded();
    expect(await layout.legacyManifestCacheQuarantineFile.exists(), isTrue);
    expect(await cache.load(latest), isNull);
  });

  test('非法 tag 不产生文件，也无法逃出 manifests/tags', () {
    expect(ManifestRequestKey.tryReleaseTag('../evil'), isNull);
    expect(ManifestRequestKey.tryReleaseTag('v1.10'), isNull);
    expect(ManifestRequestKey.tryReleaseTag('v01.10.2'), isNull);
    expect(
      () => ManifestRequestKey.releaseTag('../../etc/passwd'),
      throwsA(isA<ArgumentError>()),
    );
    final key = ManifestRequestKey.releaseTag('v1.10.2');
    final normalized = UpdateStorageLayout.normalize(
      layout.manifestCacheFile(key).path,
    );
    final tagsRoot = UpdateStorageLayout.normalize(
      layout.manifestTagsDirectory.path,
    );
    expect(normalized.startsWith('$tagsRoot${Platform.pathSeparator}'), isTrue);
  });

  test('缓存被篡改（payload 变化）后返回 null', () async {
    final cache = createCache();
    await cache.save(
      latest,
      await manifestFor(latest, version: '1.11.0', buildNumber: 52),
    );
    final file = layout.manifestCacheFile(latest);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final envelopeNode = (raw['envelope']! as Map).cast<String, Object?>();
    final payload = (envelopeNode['payload']! as Map).cast<String, Object?>();
    (payload['package']! as Map)['sizeBytes'] = 4096;
    await file.writeAsString(jsonEncode(raw));

    expect(await cache.load(latest), isNull);
  });

  test('缓存摘要被篡改后返回 null', () async {
    final cache = createCache();
    await cache.save(
      latest,
      await manifestFor(latest, version: '1.11.0', buildNumber: 52),
    );
    final file = layout.manifestCacheFile(latest);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    raw['canonicalDigest'] = 'a' * 64;
    await file.writeAsString(jsonEncode(raw));

    expect(await cache.load(latest), isNull);
  });

  test('写坏的 JSON 返回 null', () async {
    final cache = createCache();
    final file = layout.manifestCacheFile(latest);
    await file.parent.create(recursive: true);
    await file.writeAsString('{not json');

    expect(await cache.load(latest), isNull);
  });

  test('原子写失败保留上一份完整缓存', () async {
    var failing = false;
    final cache = createCache(
      writer: (file, json) async {
        if (failing) throw const FileSystemException('write failed');
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(json));
      },
    );
    await cache.save(
      latest,
      await manifestFor(latest, version: '1.11.0', buildNumber: 52),
    );
    expect(await cache.load(latest), isNotNull);

    failing = true;
    await expectLater(
      cache.save(
        latest,
        await manifestFor(latest, version: '1.12.0', buildNumber: 54),
      ),
      throwsA(isA<FileSystemException>()),
    );

    final after = await cache.load(latest);
    expect(after, isNotNull, reason: '写失败不能破坏上一份完整缓存');
    expect(
      after!.envelope.payloadJson['release'],
      containsPair('msixVersion', '1.11.0.0'),
    );
  });

  test('clear 只删除指定 key 的缓存文件', () async {
    final cache = createCache();
    await cache.save(
      latest,
      await manifestFor(latest, version: '1.11.0', buildNumber: 52),
    );
    await cache.save(
      tag1102,
      await manifestFor(tag1102, version: '1.10.2', buildNumber: 51),
    );
    expect(await layout.manifestCacheFile(latest).exists(), isTrue);

    await cache.clear(latest);

    expect(await cache.load(latest), isNull);
    expect(await cache.load(tag1102), isNotNull, reason: '清一个 key 不能影响另一个');
  });
}
