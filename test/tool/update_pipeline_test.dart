// 发布流水线（UPD-042 / UPD-044 / UPD-006 的发布侧）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';

import '../support/update_fixtures.dart';
import '../../tool/update_pipeline.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_pipeline_test_');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<File> writeMsix({String version = '1.9.0.0'}) async {
    final archive = Archive()
      ..add(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
      ..add(ArchiveFile.string('AppxBlockMap.xml', '<BlockMap/>'))
      ..add(ArchiveFile.string('AppxSignature.p7x', 'signature'))
      ..add(
        ArchiveFile.string('AppxManifest.xml', '''<?xml version="1.0"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="$appPackageIdentityName" Publisher="$appPublisher" Version="$version" ProcessorArchitecture="x64" />
</Package>'''),
      );
    final file = File('${directory.path}${Platform.pathSeparator}package.msix');
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }

  test('从成品生成的大小、哈希、文件名与地址都来自成品', () async {
    final msix = await writeMsix();
    final payload = await buildManifestPayload(
      msix: msix,
      version: '1.9.0',
      buildNumber: 46,
      msixVersion: '1.9.0.0',
    );
    final bytes = await msix.readAsBytes();
    final package = (payload['package']! as Map).cast<String, Object?>();
    expect(package['sizeBytes'], bytes.length);
    expect(package['sha256'], sha256.convert(bytes).toString());
    expect(package['fileName'], 'BestPlanning_1.9.0.0_x64.msix');
    expect(
      package['downloadUrl'],
      'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/BestPlanning_1.9.0.0_x64.msix',
    );
    expect(payload['revokedVersions'], isEmpty);
  });

  test('版本不自洽时拒绝生成清单', () async {
    final msix = await writeMsix();
    await expectLater(
      buildManifestPayload(
        msix: msix,
        version: '1.9.0',
        buildNumber: 46,
        msixVersion: '1.9.1.0',
      ),
      throwsA(isA<PipelineException>()),
    );
    await expectLater(
      buildManifestPayload(
        msix: msix,
        version: '1.9',
        buildNumber: 46,
        msixVersion: '1.9.0.0',
      ),
      throwsA(isA<PipelineException>()),
    );
  });

  test('生成的清单可以被内置验签器验证，且与成品一致', () async {
    final msix = await writeMsix();
    final payload = await buildManifestPayload(
      msix: msix,
      version: '1.9.0',
      buildNumber: 46,
      msixVersion: '1.9.0.0',
    );
    final signer = await createTestSigner();
    final envelopeJson = await signer.signEnvelope(payload);
    final envelope = UpdateManifestEnvelope.tryParse(envelopeJson);
    expect(envelope, isA<UpdateManifestEnvelope>());

    await verifyManifestEnvelope(
      envelope: envelope as UpdateManifestEnvelope,
      msix: msix,
      publicKeys: {testSigningKeyId: await signer.publicKeyHex()},
    );
  });

  test('成品被替换后复验失败', () async {
    final msix = await writeMsix();
    final payload = await buildManifestPayload(
      msix: msix,
      version: '1.9.0',
      buildNumber: 46,
      msixVersion: '1.9.0.0',
    );
    final signer = await createTestSigner();
    final envelope = UpdateManifestEnvelope.tryParse(
      await signer.signEnvelope(payload),
    ) as UpdateManifestEnvelope;

    await msix.writeAsBytes([...await msix.readAsBytes(), 0]);

    await expectLater(
      verifyManifestEnvelope(
        envelope: envelope,
        msix: msix,
        publicKeys: {testSigningKeyId: await signer.publicKeyHex()},
      ),
      throwsA(isA<PipelineException>()),
    );
  });

  group('发布门禁', () {
    List<String> gate({
      String version = '1.9.1',
      String build = '47',
      String msix = '1.9.1.0',
      String previousVersion = '1.9.0',
      String previousBuild = '46',
    }) => gateIssues(
      version: version,
      buildNumber: build,
      msixVersion: msix,
      previousVersion: previousVersion,
      previousBuild: previousBuild,
    );

    test('版本与构建号单调递增时通过', () {
      expect(gate(), isEmpty);
    });

    test('版本或构建号未递增时阻断', () {
      expect(gate(version: '1.9.0'), contains('SemVer 未递增'));
      expect(gate(build: '46'), contains('构建号未递增'));
    });

    test('MSIX 与 SemVer 不一致时阻断', () {
      expect(gate(msix: '1.9.2.0'), contains('MSIX 版本与 SemVer 不一致'));
    });
  });

  test('PKCS#8 私钥里的种子可以被读出（只取最后 32 字节）', () async {
    final seed = List<int>.generate(32, (index) => index);
    final der = [...List<int>.filled(16, 1), ...seed];
    final pem = '-----BEGIN PRIVATE KEY-----\n'
        '${base64.encode(der)}\n'
        '-----END PRIVATE KEY-----\n';
    final file = File('${directory.path}${Platform.pathSeparator}key.pem');
    await file.writeAsString(pem);

    final hex = await readEd25519SeedFromPem(file);
    expect(
      hex,
      seed.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
    );
    expect(
      () => readEd25519SeedFromPem(
        File('${directory.path}${Platform.pathSeparator}missing.pem'),
      ),
      throwsA(isA<PipelineException>()),
    );
  });
}


