// 清单签名验证（规格 §6.2 第 2～4 条、§10.3）。
//
// 信任根只有一处：本文件里的公钥允许集合。清单里写了什么算法、什么 keyId 都不构成信任，
// 它只是"请用哪把公钥验证"的提示；不在允许集合里的 keyId 一律按签名无效处理。
//
// 公钥轮换的规则（§10.3）：新旧密钥**至少重叠一个正式版本**——先发布同时信任新旧密钥的
// 客户端，再用新密钥签名。因此这里用 Map 而不是单个常量。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/infrastructure/update/json_canonicalizer.dart';

/// 客户端的 Ed25519 公钥允许集合：`keyId -> 32 字节公钥的十六进制`。
///
/// **2026-10-18 首把密钥**（`best-planning-2026-10`）：由发布机生成，私钥保存在仓库之外
/// （`C:\Users\zs200\signing\update-manifest-ed25519.pem`，与 MSIX 的 `.pfx` 同一口径）。
/// 这里只放公钥——公钥不是秘密，它必须能被审计。
const Map<String, String> manifestPublicKeys = {
  'best-planning-2026-10':
      '87f122c2f90e1c125df2e849a3beebc1b5633e0f2502c12e14d2c53f254918bc',
};

/// 验签结果。
final class ManifestVerification {
  const ManifestVerification.verified(this.verified) : failure = null;

  const ManifestVerification.invalid(this.failure) : verified = null;

  final VerifiedManifest? verified;
  final UpdateFailure? failure;

  bool get isValid => verified != null;
}

/// Ed25519 清单验证器。
///
/// [publicKeys] 只在测试里注入；生产实现使用 [manifestPublicKeys]。
final class Ed25519ManifestVerifier {
  Ed25519ManifestVerifier({
    Map<String, String>? publicKeys,
    DateTime Function()? nowUtc,
  }) : _publicKeys = publicKeys ?? manifestPublicKeys,
       _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final Map<String, String> _publicKeys;
  final DateTime Function() _nowUtc;
  final Ed25519 _ed25519 = Ed25519();

  /// 验证信封：规范化 payload → Ed25519 → 严格解析。
  Future<ManifestVerification> verify(
    UpdateManifestEnvelope envelope, {
    String? etag,
    String? manifestUrl,
  }) async {
    final publicKeyHex = _publicKeys[envelope.signature.keyId];
    if (publicKeyHex == null) {
      // 未知 keyId：不是"暂时无法确认"，而是这份清单不该被信任。
      return const ManifestVerification.invalid(
        UpdateFailure(UpdateFailureCode.manifestSignatureInvalid),
      );
    }

    final List<int> signatureBytes;
    try {
      signatureBytes = base64.decode(envelope.signature.value);
    } on FormatException {
      return const ManifestVerification.invalid(
        UpdateFailure(UpdateFailureCode.manifestSignatureInvalid),
      );
    }
    // Ed25519 签名固定 64 字节；长度不对时不必进入密码学库。
    if (signatureBytes.length != 64) {
      return const ManifestVerification.invalid(
        UpdateFailure(UpdateFailureCode.manifestSignatureInvalid),
      );
    }

    final canonical = canonicalizeJson(envelope.payloadJson);
    final canonicalBytes = utf8.encode(canonical);
    final publicKeyBytes = _decodeHex(publicKeyHex);
    if (publicKeyBytes == null || publicKeyBytes.length != 32) {
      // 内置公钥被写坏属于程序错误，但也不能"跳过验签"。
      return const ManifestVerification.invalid(
        UpdateFailure(UpdateFailureCode.manifestSignatureInvalid),
      );
    }

    final bool valid;
    try {
      valid = await _ed25519.verify(
        canonicalBytes,
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      return const ManifestVerification.invalid(
        UpdateFailure(UpdateFailureCode.manifestSignatureInvalid),
      );
    }
    if (!valid) {
      return const ManifestVerification.invalid(
        UpdateFailure(UpdateFailureCode.manifestSignatureInvalid),
      );
    }

    final parsed = parseUpdateManifestPayload(
      envelope.payloadJson,
      signature: envelope.signature,
    );
    final manifest = parsed.manifest;
    if (manifest == null) {
      return ManifestVerification.invalid(
        parsed.failure?.code == null
            ? const UpdateFailure(UpdateFailureCode.manifestInvalidJson)
            : UpdateFailure(parsed.failure!.code),
      );
    }

    return ManifestVerification.verified(
      VerifiedManifest(
        manifest: manifest,
        payloadJson: envelope.payloadJson,
        canonicalDigest: sha256.convert(canonicalBytes).toString(),
        confirmedAtUtc: _nowUtc(),
        etag: etag,
        manifestUrl: manifestUrl,
      ),
    );
  }

  static List<int>? _decodeHex(String hex) {
    if (hex.length.isOdd) return null;
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (byte == null) return null;
      bytes.add(byte);
    }
    return bytes;
  }
}

/// 清单签名器。发布流水线与测试共用，确保"签名的字节"与"验签的字节"是同一套规则。
final class Ed25519ManifestSigner {
  Ed25519ManifestSigner._(this.keyId, this._keyPair);

  final String keyId;
  final SimpleKeyPair _keyPair;
  final Ed25519 _ed25519 = Ed25519();

  /// 用 32 字节种子构造。种子就是 Ed25519 私钥的本体（PKCS#8 里最后 32 字节）。
  static Future<Ed25519ManifestSigner> fromSeedHex(
    String seedHex, {
    required String keyId,
  }) async {
    final bytes = Ed25519ManifestVerifier._decodeHex(seedHex);
    if (bytes == null || bytes.length != 32) {
      throw ArgumentError('Ed25519 种子必须是 32 字节十六进制');
    }
    final keyPair = await Ed25519().newKeyPairFromSeed(bytes);
    return Ed25519ManifestSigner._(keyId, keyPair);
  }

  /// 对 payload 签名，返回可直接放进信封的签名段。
  Future<Map<String, Object?>> signPayload(Map<String, Object?> payload) async {
    final canonical = canonicalizeJsonToUtf8(payload);
    final signature = await _ed25519.sign(canonical, keyPair: _keyPair);
    return {
      'algorithm': ManifestSignature.supportedAlgorithm,
      'keyId': keyId,
      'value': base64Encode(signature.bytes),
    };
  }

  /// 公钥十六进制。测试用它构造允许集合；发布流水线用它核对内置公钥。
  Future<String> publicKeyHex() async {
    final publicKey = await _keyPair.extractPublicKey();
    return publicKey.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// 把 payload 包成完整信封。
  Future<Map<String, Object?>> signEnvelope(
    Map<String, Object?> payload,
  ) async => {'payload': payload, 'signature': await signPayload(payload)};
}
