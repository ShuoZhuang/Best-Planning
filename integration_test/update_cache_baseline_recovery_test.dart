// 已安装态的事故序列回归（1.11.1 Task 11 / §7.1）。
//
// **它能证明什么**：在真实 Windows 文件系统上，1.11.1 的分区缓存、v1→v2 状态迁移、
// 磁盘 ready 收养、目标单调性与基线校验共同工作；同一序列在 1.11.0 上会得到 1.10.2。
//
// **它不能证明什么**：签名安装、覆盖升级与回退必须由 `tool/update_e2e.ps1` 在已安装的
// MSIX 环境执行；`flutter test` 下的产物没有包身份。未执行的项在
// `docs/testing/v1.11.1-release-gate.md` 中标记为 NOT RUN。
//
// 运行方式（需要 Developer Mode 或仓库已批准的目录联接准备流程）：
//   flutter test integration_test/update_cache_baseline_recovery_test.dart -d windows
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_planner/application/update/update_baseline_service.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/file_update_manifest_cache.dart';
import 'package:personal_planner/infrastructure/update/file_update_state_store.dart';
import 'package:personal_planner/infrastructure/update/http_update_manifest_repository.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../test/support/update_doubles.dart';
import '../test/support/update_fixtures.dart';

const InstalledPackage _installed1102 = InstalledPackage(
  identityName: appPackageIdentityName,
  publisher: appPublisher,
  familyName: appPackageFamilyName,
  architecture: PackageArchitecture.x64,
  version: MsixVersion(1, 10, 2, 0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late UpdateStorageLayout layout;
  late InMemoryUpdateSafetyCoordinator safety;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_incident_e2e_');
    layout = UpdateStorageLayout(root: directory);
    safety = InMemoryUpdateSafetyCoordinator();
  });

  tearDown(() {
    safety.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('事故序列在真实文件系统上自愈：latest→tag→304 后仍是 1.11.0', () async {
    final verifier = await createTestVerifier();
    final latestJson = await signedManifestJson(
      validManifestPayload(version: '1.11.0', buildNumber: 52),
    );
    final tagJson = await signedManifestJson(
      validManifestPayload(version: '1.10.2', buildNumber: 51),
    );
    final latestVerified = (await verifier.verify(
      UpdateManifestEnvelope.tryParse(jsonDecode(latestJson))
          as UpdateManifestEnvelope,
    )).verified!;
    final target = _targetFrom(latestVerified);

    // 事故现场：已下载的 1.11.0 + v1 状态 + 旧全局缓存。
    layout.readyPackage(target)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(target.sizeBytes, 3));
    layout.stateFile.writeAsStringSync(
      jsonEncode(
        {
            ...UpdateState(
              phase: UpdatePhase.ready,
              currentMsixVersion: _installed1102.version,
              target: target,
              receivedBytes: target.sizeBytes,
              totalBytes: target.sizeBytes,
            ).toJson(),
            'schemaVersion': 1,
          }
          ..remove('baselinePreparation')
          ..remove('migratedFromSchemaVersion')
          ..remove('migrationDroppedFields'),
      ),
    );
    layout.legacyManifestCacheFile.writeAsStringSync(
      jsonEncode({'schemaVersion': 1, 'etag': '"legacy"'}),
    );

    final cache = FileUpdateManifestCache(layout: layout, verifier: verifier);
    await cache.migrateLegacyIfNeeded();
    var latestRequests = 0;
    final repository = HttpUpdateManifestRepository(
      cache: cache,
      verifier: verifier,
      client: MockClient((request) async {
        final url = request.url.toString();
        if (url == updateManifestLatestUrl) {
          latestRequests++;
          if (request.headers['If-None-Match'] == '"latest-1"') {
            return http.Response('', 304, headers: {'etag': '"latest-1"'});
          }
          return _json(latestJson, etag: '"latest-1"');
        }
        if (url == updateManifestUrlForTag('v1.10.2').toString()) {
          return _json(tagJson, etag: '"tag-1102"');
        }
        return http.Response('unexpected', 404);
      }),
    );

    final orchestrator = UpdateOrchestrator(
      manifestSource: repository,
      stateStore: FileUpdateStateStore(file: layout.stateFile),
      installedPackages: FakeInstalledPackages(_installed1102),
      downloader: FakeDownloader(),
      verifier: FakeVerifier(),
      layout: layout,
      safety: safety,
      log: MemoryLogSink(),
      clock: FakeClock(),
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
      installCoordinator: FakeInstallCoordinator(),
      baselineService: UpdateBaselineService(
        layout: layout,
        manifestSource: repository,
        downloader: _BaselineWritingDownloader(),
        verifier: FakeVerifier(),
        clock: FakeClock(),
      ),
    );

    await orchestrator.initialize();
    expect(orchestrator.state.target!.msixVersion.value, '1.11.0.0');
    expect(orchestrator.state.schemaVersion, updateStateSchemaVersion);
    expect(layout.legacyManifestCacheFile.existsSync(), isFalse);

    await orchestrator.check(manual: true, autoDownload: false);
    expect(orchestrator.state.target!.msixVersion.value, '1.11.0.0');

    await orchestrator.ensureRollbackBaseline();
    expect(orchestrator.state.baseline!.version.value, '1.10.2.0');

    await orchestrator.check(manual: true, autoDownload: false);
    expect(latestRequests, 2, reason: '第二次检查必须是真的 304');
    expect(
      orchestrator.state.target!.msixVersion.value,
      '1.11.0.0',
      reason: '304 不能把 tag 的 1.10.2 当成 latest',
    );
    expect(orchestrator.state.phase, UpdatePhase.ready);
  });
}

UpdateTarget _targetFrom(VerifiedManifest verified) {
  final m = verified.manifest;
  return UpdateTarget(
    version: m.release.version,
    buildNumber: m.release.buildNumber,
    tag: m.tag,
    msixVersion: m.msixVersion,
    fileName: m.package.fileName,
    downloadUrl: m.package.downloadUrl,
    sizeBytes: m.package.sizeBytes,
    sha256: m.package.sha256,
    manifestDigest: verified.canonicalDigest,
    keyId: m.signature.keyId,
  );
}

http.Response _json(String body, {String? etag}) => http.Response(
  body,
  200,
  headers: {'content-type': 'application/json; charset=utf-8', 'etag': ?etag},
);

final class _BaselineWritingDownloader implements UpdatePackageDownloader {
  @override
  Future<DownloadOutcome> download({
    required UpdateTarget target,
    required String partialPath,
    required String readyPath,
    String? etag,
    String? lastModified,
    required bool Function() shouldCancel,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
  }) async {
    final file = File(readyPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(target.sizeBytes, 0));
    onProgress(target.sizeBytes, target.sizeBytes);
    return DownloadOutcome.success(
      path: readyPath,
      sizeBytes: target.sizeBytes,
      sha256: target.sha256,
    );
  }
}
