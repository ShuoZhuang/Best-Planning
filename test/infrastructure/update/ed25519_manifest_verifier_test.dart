// Ed25519 清单验签（UPD-006 / §6.2）。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/infrastructure/update/json_canonicalizer.dart';

import '../../support/update_fixtures.dart';

void main() {
  test('正确签名的清单通过验证，并给出规范化摘要', () async {
    final payload = validManifestPayload();
    final envelopeJson = await signedManifestEnvelope(payload);
    final envelope =
        UpdateManifestEnvelope.tryParse(envelopeJson) as UpdateManifestEnvelope;
    final verifier = await createTestVerifier();

    final result = await verifier.verify(
      envelope,
      etag: '"abc"',
      resolvedOrigin: 'https://github.com/ShuoZhuang/Best-Planning/...',
    );

    expect(result.isValid, isTrue, reason: '${result.failure?.code}');
    final verified = result.verified!;
    expect(verified.manifest.semanticVersion.value, '1.9.0');
    expect(verified.etag, '"abc"');
    expect(verified.canonicalDigest, hasLength(64));
    expect(
      verified.canonicalDigest,
      sha256.convert(canonicalizeJsonToUtf8(payload)).toString(),
      reason: '摘要是规范化字节的哈希，而不是原始 JSON 文本的哈希',
    );
  });

  test('签名后改动 payload 会被发现', () async {
    final payload = validManifestPayload();
    final envelopeJson = await signedManifestEnvelope(payload);
    final tampered = (UpdateManifestEnvelope.tryParse(
      envelopeJson,
    ) as UpdateManifestEnvelope).payloadJson.cast<String, Object?>();
    tampered['release'] = {
      ...(tampered['release']! as Map).cast<String, Object?>(),
      'buildNumber': 47,
    };
    final envelope = UpdateManifestEnvelope(
      payloadJson: tampered,
      signature: (UpdateManifestEnvelope.tryParse(
        envelopeJson,
      ) as UpdateManifestEnvelope).signature,
    );

    final result = await (await createTestVerifier()).verify(envelope);
    expect(result.isValid, isFalse);
    expect(result.failure?.code, UpdateFailureCode.manifestSignatureInvalid);
  });

  test('不在允许集合里的 keyId 一律拒绝', () async {
    final signer = await createTestSigner(keyId: 'unknown-key');
    final envelope = UpdateManifestEnvelope.tryParse(
      await signedManifestEnvelope(validManifestPayload(), signer: signer),
    ) as UpdateManifestEnvelope;

    final result = await (await createTestVerifier()).verify(envelope);
    expect(result.failure?.code, UpdateFailureCode.manifestSignatureInvalid);
  });

  test('用另一把密钥签的清单不能通过', () async {
    final otherSigner = await createTestSigner(
      seedHex:
          '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f',
      keyId: testSigningKeyId,
    );
    final envelope = UpdateManifestEnvelope.tryParse(
      await signedManifestEnvelope(validManifestPayload(), signer: otherSigner),
    ) as UpdateManifestEnvelope;

    final result = await (await createTestVerifier()).verify(envelope);
    expect(result.isValid, isFalse);
  });

  test('非 base64 或长度不对的签名被拒绝', () async {
    final verifier = await createTestVerifier();
    for (final value in ['not base64!!', base64Encode(List.filled(32, 0))]) {
      final envelope = UpdateManifestEnvelope(
        payloadJson: validManifestPayload(),
        signature: ManifestSignature(
          algorithm: 'Ed25519',
          keyId: testSigningKeyId,
          value: value,
        ),
      );
      final result = await verifier.verify(envelope);
      expect(
        result.failure?.code,
        UpdateFailureCode.manifestSignatureInvalid,
        reason: '不应接受签名 $value',
      );
    }
  });

  test('签名算法不是 Ed25519 时信封解析即拒绝', () async {
    final json = await signedManifestEnvelope(validManifestPayload());
    final signature = (json['signature']! as Map).cast<String, Object?>();
    signature['algorithm'] = 'Ed448';
    final parsed = UpdateManifestEnvelope.tryParse(json);
    expect(parsed, isA<ManifestParseFailure>());
  });

  test('签名正确但 payload 自相矛盾时报告版本不一致', () async {
    final payload = validManifestPayload(tag: 'v1.8.1');
    final envelope = UpdateManifestEnvelope.tryParse(
      await signedManifestEnvelope(payload),
    ) as UpdateManifestEnvelope;

    final result = await (await createTestVerifier()).verify(envelope);
    expect(result.isValid, isFalse);
    expect(result.failure?.code, UpdateFailureCode.manifestVersionInconsistent);
  });
}
