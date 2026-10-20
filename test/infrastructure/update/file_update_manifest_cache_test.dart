// 已验证清单缓存（UPD-002、UPD-019 的缓存侧）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/infrastructure/update/file_update_manifest_cache.dart';

import '../../support/update_fixtures.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_cache_test_');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('保存后可以读回，并标记为来自缓存', () async {
    final verifier = await createTestVerifier();
    final cache = FileUpdateManifestCache(
      directory: directory,
      verifier: verifier,
    );
    final envelope = UpdateManifestEnvelope.tryParse(
      await signedManifestEnvelope(validManifestPayload()),
    ) as UpdateManifestEnvelope;
    final verified = (await verifier.verify(envelope, etag: '"abc"')).verified!;

    await cache.save(verified);
    final loaded = await cache.load();

    expect(loaded, isNotNull);
    expect(loaded!.fromCache, isTrue);
    expect(loaded.etag, '"abc"');
    expect(loaded.canonicalDigest, verified.canonicalDigest);
    expect(loaded.manifest.msixVersion.value, '1.9.0.0');
  });

  test('缓存被篡改时读取返回 null，而不是把未经验签的清单交给调用方', () async {
    final verifier = await createTestVerifier();
    final cache = FileUpdateManifestCache(
      directory: directory,
      verifier: verifier,
    );
    final envelope = UpdateManifestEnvelope.tryParse(
      await signedManifestEnvelope(validManifestPayload()),
    ) as UpdateManifestEnvelope;
    await cache.save((await verifier.verify(envelope)).verified!);

    final raw =
        jsonDecode(await cache.file.readAsString()) as Map<String, Object?>;
    final envelopeNode = (raw['envelope']! as Map).cast<String, Object?>();
    final payload = (envelopeNode['payload']! as Map).cast<String, Object?>();
    (payload['package']! as Map)['sizeBytes'] = 999;
    await cache.file.writeAsString(jsonEncode(raw));

    expect(await cache.load(), isNull);
  });

  test('写坏的 JSON 返回 null', () async {
    final verifier = await createTestVerifier();
    final cache = FileUpdateManifestCache(
      directory: directory,
      verifier: verifier,
    );
    await cache.file.writeAsString('{not json');

    expect(await cache.load(), isNull);
  });

  test('clear 删除缓存文件', () async {
    final verifier = await createTestVerifier();
    final cache = FileUpdateManifestCache(
      directory: directory,
      verifier: verifier,
    );
    final envelope = UpdateManifestEnvelope.tryParse(
      await signedManifestEnvelope(validManifestPayload()),
    ) as UpdateManifestEnvelope;
    await cache.save((await verifier.verify(envelope)).verified!);
    expect(await cache.file.exists(), isTrue);

    await cache.clear();
    expect(await cache.file.exists(), isFalse);
    expect(await cache.load(), isNull);
  });
}
