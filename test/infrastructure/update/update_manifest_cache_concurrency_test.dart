// 缓存并发与崩溃点（1.11.1 修复 §4.3 / Task 10）。
//
// 事故的复现条件是"两个请求交错写同一个文件"。分区之后仍然需要证明：
// 交错写不会互相覆盖，读到的一半内容不会被当成有效缓存，崩溃点不会留下"错误的 latest"。
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

  const latest = ManifestRequestKey.latestStable();
  final tags = [
    ManifestRequestKey.releaseTag('v1.10.2'),
    ManifestRequestKey.releaseTag('v1.11.0'),
    ManifestRequestKey.releaseTag('v1.11.1'),
  ];

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('manifest_cache_conc_');
    layout = UpdateStorageLayout(root: directory);
    verifier = await createTestVerifier();
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  FileUpdateManifestCache createCache() =>
      FileUpdateManifestCache(layout: layout, verifier: verifier);

  Future<VerifiedManifest> manifestFor(
    ManifestRequestKey key,
    String version,
    int buildNumber,
  ) async {
    final envelope = UpdateManifestEnvelope.tryParse(
      await signedManifestEnvelope(
        validManifestPayload(version: version, buildNumber: buildNumber),
      ),
    ) as UpdateManifestEnvelope;
    return (await verifier.verify(envelope, requestKey: key)).verified!;
  }

  test('交错保存 latest 与多个 tag：latest 的缓存恒为 latest 的实体', () async {
    final cache = createCache();
    final latestManifest = await manifestFor(latest, '1.11.0', 52);
    final tagManifests = <ManifestRequestKey, VerifiedManifest>{
      tags[0]: await manifestFor(tags[0], '1.10.2', 51),
      tags[1]: await manifestFor(tags[1], '1.11.0', 52),
      tags[2]: await manifestFor(tags[2], '1.11.1', 53),
    };

    for (var round = 0; round < 5; round++) {
      await Future.wait([
        cache.save(latest, latestManifest),
        for (final entry in tagManifests.entries)
          cache.save(entry.key, entry.value),
      ]);
    }

    final entry = await cache.load(latest);
    expect(entry, isNotNull);
    expect(
      entry!.envelope.payloadJson['release'],
      containsPair('msixVersion', '1.11.0.0'),
      reason: 'latest 的槽位只能保存 latest 的实体',
    );
    expect(entry.requestKey, latest);
    for (final key in tags) {
      final tagEntry = await cache.load(key);
      expect(tagEntry, isNotNull, reason: key.storageKey);
      expect(tagEntry!.requestKey, key);
    }
  });

  test('一边写一边读：每次读到的要么是完整实体，要么是 null', () async {
    final cache = createCache();
    final manifests = <VerifiedManifest>[
      await manifestFor(latest, '1.11.0', 52),
      await manifestFor(latest, '1.12.0', 54),
      await manifestFor(latest, '1.13.0', 55),
    ];

    final writes = Future.wait([
      for (final manifest in manifests) cache.save(latest, manifest),
    ]);
    final reads = <Object?>[];
    for (var i = 0; i < 12; i++) {
      final entry = await cache.load(latest);
      reads.add(
        entry?.envelope.payloadJson['release'] is Map
            ? (entry!.envelope.payloadJson['release']! as Map)['msixVersion']
            : null,
      );
    }
    await writes;

    for (final read in reads) {
      expect(
        read,
        anyOf(isNull, '1.11.0.0', '1.12.0.0', '1.13.0.0'),
        reason: '不得读到半份或被拼接的 JSON',
      );
    }
  });

  test('写 cache 前崩溃：没有缓存，读取返回 null', () async {
    final cache = createCache();
    expect(await cache.load(latest), isNull);
    expect(await layout.manifestCacheFile(latest).exists(), isFalse);
  });

  test('写 cache 后、写 state 前崩溃：缓存仍然可用且属于正确的 key', () async {
    final cache = createCache();
    await cache.save(latest, await manifestFor(latest, '1.11.0', 52));

    // 模拟"state 没来得及写"：重新构造一个缓存实例（等价于重启）。
    final reopened = createCache();
    final entry = await reopened.load(latest);
    expect(entry, isNotNull);
    expect(
      entry!.envelope.payloadJson['release'],
      containsPair('msixVersion', '1.11.0.0'),
    );
    expect(await reopened.load(tags[0]), isNull);
  });

  test('缓存文件被截断：读取返回 null，下一次完整请求可以重建', () async {
    final cache = createCache();
    final manifest = await manifestFor(latest, '1.11.0', 52);
    await cache.save(latest, manifest);

    final file = layout.manifestCacheFile(latest);
    final raw = await file.readAsString();
    await file.writeAsString(raw.substring(0, raw.length ~/ 2));
    expect(await cache.load(latest), isNull);

    await cache.save(latest, manifest);
    expect(await cache.load(latest), isNotNull);
  });
}
