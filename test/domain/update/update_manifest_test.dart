// 清单严格解析（规格 §6.2 / §6.3 / §6.4 / UPD-007 / UPD-018）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/manifest_request_key.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_version.dart';

import '../../support/update_fixtures.dart';

/// 结构解析不验签，因此签名值只需要是"形状合法的 64 字节 base64"。
final _signature = ManifestSignature(
  algorithm: 'Ed25519',
  keyId: 'test-key-2026-10',
  value: base64Encode(List<int>.filled(64, 0)),
);

ManifestParseResult _parse(Map<String, Object?> payload) =>
    parseUpdateManifestPayload(payload, signature: _signature);

void main() {
  group('合法清单', () {
    test('解析出全部事实并保持版本一致', () {
      final result = _parse(validManifestPayload());
      expect(result.isSuccess, isTrue, reason: '${result.failure?.code}');
      final manifest = result.manifest!;
      expect(manifest.schemaVersion, 1);
      expect(manifest.channel, 'stable');
      expect(manifest.release.version.value, '1.9.0');
      expect(manifest.release.buildNumber, 46);
      expect(manifest.msixVersion.value, '1.9.0.0');
      expect(manifest.tag, 'v1.9.0');
      expect(manifest.package.sizeBytes, 2048);
      expect(manifest.package.sha256, testPackageSha256);
      expect(manifest.revokedVersions, isEmpty);
      expect(manifest.isRevoked, isFalse);
    });

    test('候选版本关系只看四段 MSIX 版本', () {
      final manifest = _parse(validManifestPayload()).manifest!;
      expect(
        manifest.relationTo(MsixVersion.tryParse('1.8.1.0')!),
        UpdateVersionRelation.newer,
      );
      expect(manifest.isNewerThan(MsixVersion.tryParse('1.9.0.0')!), isFalse);
      expect(
        manifest.relationTo(MsixVersion.tryParse('1.9.0.0')!),
        UpdateVersionRelation.same,
      );
      expect(
        manifest.relationTo(MsixVersion.tryParse('1.9.1.0')!),
        UpdateVersionRelation.older,
      );
    });

    test('撤回列表命中目标版本时 isRevoked 为真', () {
      final payload = validManifestPayload(revokedVersions: ['1.9.0.0']);
      final manifest = _parse(payload).manifest!;
      expect(manifest.isRevoked, isTrue);
    });
  });

  group('结构严格性（UPD-007）', () {
    test('payload 多出未知字段被拒绝', () {
      final payload = deepCopy(validManifestPayload())..['futureField'] = true;
      expect(
        _parse(payload).failure?.code,
        UpdateFailureCode.manifestSchemaUnsupported,
      );
    });

    test('嵌套段多出未知字段被拒绝', () {
      final payload = replaceAt(validManifestPayload(), [
        'release',
        'channel',
      ], 'stable');
      expect(
        _parse(payload).failure?.code,
        UpdateFailureCode.manifestSchemaUnsupported,
      );
    });

    test('缺少必填字段是结构不合法，而不是被忽略', () {
      final payload = removeAt(validManifestPayload(), ['package', 'sha256']);
      expect(
        _parse(payload).failure?.code,
        UpdateFailureCode.manifestInvalidJson,
      );
    });

    test('不支持的 schemaVersion 被拒绝', () {
      expect(
        _parse(validManifestPayload(schemaVersion: 2)).failure?.code,
        UpdateFailureCode.manifestSchemaUnsupported,
      );
    });

    test('非 stable 通道被拒绝', () {
      expect(
        _parse(validManifestPayload(channel: 'beta')).failure?.code,
        UpdateFailureCode.manifestSchemaUnsupported,
      );
    });

    test('签名算法不是 Ed25519 时信封解析失败', () {
      final envelope = UpdateManifestEnvelope.tryParse({
        'payload': validManifestPayload(),
        'signature': {
          'algorithm': 'Ed448',
          'keyId': 'test-key-2026-10',
          'value': _signature.value,
        },
      });
      expect(envelope, isA<ManifestParseFailure>());
      expect(
        (envelope as ManifestParseFailure).code,
        UpdateFailureCode.manifestSchemaUnsupported,
      );
    });

    test('信封多出字段被拒绝', () {
      final envelope = UpdateManifestEnvelope.tryParse({
        'payload': validManifestPayload(),
        'signature': {
          'algorithm': 'Ed25519',
          'keyId': 'test-key-2026-10',
          'value': _signature.value,
        },
        'extra': 1,
      });
      expect(envelope, isA<ManifestParseFailure>());
    });
  });

  group('版本一致性（UPD-017 / UPD-018）', () {
    test('tag 与 SemVer 不一致被拒绝', () {
      expect(
        _parse(validManifestPayload(tag: 'v1.8.1')).failure?.code,
        UpdateFailureCode.manifestVersionInconsistent,
      );
    });

    test('MSIX 版本与 SemVer 不一致被拒绝', () {
      expect(
        _parse(validManifestPayload(msixVersion: '1.9.1.0')).failure?.code,
        UpdateFailureCode.manifestVersionInconsistent,
      );
    });

    test('历史非标准 tag 不会被猜测成合法版本', () {
      expect(
        _parse(validManifestPayload(version: '1.8.1', tag: 'v1.8.1-build45'))
            .failure
            ?.code,
        UpdateFailureCode.manifestVersionInconsistent,
      );
    });

    test('撤回列表里的版本必须是四段', () {
      expect(
        _parse(validManifestPayload(revokedVersions: ['1.9.0'])).failure?.code,
        UpdateFailureCode.manifestInvalidJson,
      );
    });
  });

  group('包与地址约束（UPD-008 / UPD-016）', () {
    test('sha256 必须是小写 64 位十六进制', () {
      for (final bad in [
        testPackageSha256.toUpperCase(),
        'abc',
        '${testPackageSha256}0',
      ]) {
        expect(
          _parse(validManifestPayload(sha256: bad)).failure?.code,
          UpdateFailureCode.manifestInvalidJson,
          reason: '不应接受 $bad',
        );
      }
    });

    test('大小必须为正', () {
      expect(
        _parse(validManifestPayload(sizeBytes: 0)).failure?.code,
        UpdateFailureCode.manifestInvalidJson,
      );
      expect(
        _parse(validManifestPayload(sizeBytes: -1)).failure?.code,
        UpdateFailureCode.manifestInvalidJson,
      );
    });

    test('文件名必须是单段安全名称', () {
      for (final bad in [
        '../evil.msix',
        'C:/evil.msix',
        'evil.zip',
        'dir/evil.msix',
        'evil.msix.exe',
      ]) {
        expect(
          _parse(validManifestPayload(fileName: bad)).failure?.code,
          UpdateFailureCode.manifestInvalidJson,
          reason: '不应接受 $bad',
        );
      }
    });

    test('下载地址必须是同仓库同 Tag 同文件名的不可变地址', () {
      final payload = validManifestPayload(
        downloadUrl: 'https://github.com/ShuoZhuang/Other/releases/download/v1.9.0/BestPlanning_1.9.0.0_x64.msix',
      );
      expect(
        _parse(payload).failure?.code,
        UpdateFailureCode.manifestSourceNotAllowed,
      );

      final httpPayload = validManifestPayload(
        downloadUrl: 'http://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/BestPlanning_1.9.0.0_x64.msix',
      );
      expect(
        _parse(httpPayload).failure?.code,
        UpdateFailureCode.manifestSourceNotAllowed,
      );
    });

    test('Release 页面必须是同仓库对应 tag', () {
      expect(
        _parse(
          validManifestPayload(
            releaseUrl: 'https://github.com/ShuoZhuang/Best-Planning/releases/tag/v1.9.1',
          ),
        ).failure?.code,
        UpdateFailureCode.manifestSourceNotAllowed,
      );
      expect(
        _parse(
          validManifestPayload(
            releaseUrl: 'https://example.com/releases/tag/v1.9.0',
          ),
        ).failure?.code,
        UpdateFailureCode.manifestSourceNotAllowed,
      );
    });
  });

  group('展示文本只作为纯文本', () {
    test('标题不能为空或超长', () {
      expect(
        _parse(replaceAt(validManifestPayload(), ['presentation', 'title'], ''))
            .failure
            ?.code,
        UpdateFailureCode.manifestInvalidJson,
      );
      expect(
        _parse(
          replaceAt(validManifestPayload(), [
            'presentation',
            'title',
          ], 'x' * 121),
        ).failure?.code,
        UpdateFailureCode.manifestInvalidJson,
      );
    });

    test('摘要不能包含控制字符', () {
      expect(
        _parse(
          replaceAt(validManifestPayload(), [
            'presentation',
            'summary',
          ], 'bad\u0000summary'),
        ).failure?.code,
        UpdateFailureCode.manifestInvalidJson,
      );
    });
  });

  group('请求身份（ManifestRequestKey）', () {
    test('latest 与 tag 的存储键、路径与固定地址互不相同', () {
      const latest = ManifestRequestKey.latestStable();
      final tag = ManifestRequestKey.releaseTag('v1.10.2');

      expect(latest.storageKey, 'latest-stable');
      expect(tag.storageKey, 'tag-v1.10.2');
      expect(latest.relativePath, 'manifests/latest-stable.json');
      expect(tag.relativePath, 'manifests/tags/v1.10.2.json');
      expect(latest.canonicalUri.toString(), updateManifestLatestUrl);
      expect(
        tag.canonicalUri.toString(),
        updateManifestUrlForTag('v1.10.2').toString(),
      );
      expect(latest, isNot(tag));
      expect(latest, const ManifestRequestKey.latestStable());
    });

    test('同一 tag 的两次构造相等；不同 tag 不等', () {
      expect(
        ManifestRequestKey.releaseTag('v1.10.2'),
        ManifestRequestKey.releaseTag('v1.10.2'),
      );
      expect(
        ManifestRequestKey.releaseTag('v1.10.2'),
        isNot(ManifestRequestKey.releaseTag('v1.10.3')),
      );
    });

    test('非法 tag 不产生请求身份', () {
      for (final tag in [
        '',
        '../evil',
        'v1.10',
        'v01.10.2',
        '1.10.2',
        'v1.10.2/../x',
        'v1.10.2 ',
        'v1.10.2\n',
      ]) {
        expect(
          ManifestRequestKey.tryReleaseTag(tag),
          isNull,
          reason: '应拒绝 $tag',
        );
        expect(
          () => ManifestRequestKey.releaseTag(tag),
          throwsA(isA<ArgumentError>()),
        );
      }
    });

    test('JSON 表达稳定，非法 JSON 不产生身份', () {
      const latest = ManifestRequestKey.latestStable();
      final tag = ManifestRequestKey.releaseTag('v1.11.0');

      expect(ManifestRequestKey.fromJson(latest.toJson()), latest);
      expect(ManifestRequestKey.fromJson(tag.toJson()), tag);
      expect(ManifestRequestKey.fromJson({'kind': 'releaseTag'}), isNull);
      expect(
        ManifestRequestKey.fromJson({'kind': 'releaseTag', 'tag': 'bad'}),
        isNull,
      );
      expect(ManifestRequestKey.fromJson({'kind': 'other'}), isNull);
      expect(ManifestRequestKey.fromJson('latest'), isNull);
    });

    test('界面来源名不包含 URL 或查询串', () {
      const latest = ManifestRequestKey.latestStable();
      final tag = ManifestRequestKey.releaseTag('v1.10.2');
      expect(latest.label, 'GitHub 稳定通道');
      expect(tag.label, contains('v1.10.2'));
      for (final label in [latest.label, tag.label]) {
        expect(label, isNot(contains('http')));
        expect(label, isNot(contains('?')));
      }
    });
  });
}
