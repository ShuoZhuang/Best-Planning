// 真实组合根的事故恢复链路（1.11.1 Task 11 / §7.1）。
//
// 与其它更新测试的区别：这里使用**真实的文件缓存、真实的状态文件、真实编排器与控制器**
// 以及真实的 widget 路由；只替换两样东西——网络（MockClient）与原生安装链（替身）。
//
// 完整路径：
//   旧 v1 state + 旧全局缓存 + 磁盘 1.11.0 ready
//   → 启动迁移（v1→v2，旧缓存隔离）
//   → latest 检查（200，建立分区缓存）
//   → 建立 1.10.2 回退基线
//   → latest 304
//   → 左下角仍显示 1.11.0 可更新
//   → 点击更新 → 安装服务收到 target=1.11.0 与 rollback=1.10.2
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/update/update_baseline_service.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_settings.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/infrastructure/update/file_update_manifest_cache.dart';
import 'package:personal_planner/infrastructure/update/file_update_state_store.dart';
import 'package:personal_planner/infrastructure/update/http_update_manifest_repository.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../support/update_doubles.dart';
import '../support/update_fixtures.dart';

const InstalledPackage _installed1102 = InstalledPackage(
  identityName: appPackageIdentityName,
  publisher: appPublisher,
  familyName: appPackageFamilyName,
  architecture: PackageArchitecture.x64,
  version: MsixVersion(1, 10, 2, 0),
);

void main() {
  late Directory directory;
  late UpdateStorageLayout layout;
  late InMemoryUpdateSafetyCoordinator safety;
  late FakeInstallCoordinator coordinator;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_app_recovery_');
    layout = UpdateStorageLayout(root: directory);
    safety = InMemoryUpdateSafetyCoordinator();
    coordinator = FakeInstallCoordinator();
  });

  tearDown(() {
    safety.dispose();
    // 临时目录清理是收尾工作，不该因为 Windows 上偶发的句柄占用把用例判红。
    _deleteQuietly(directory);
  });

  testWidgets('事故状态自动恢复：1.10.2 上已下载 1.11.0 不会退回“已是最新版”', (tester) async {
    final verifier = await createTestVerifier();
    final latestJson = await signedManifestJson(
      validManifestPayload(version: '1.11.0', buildNumber: 52),
    );
    final tagJson = await signedManifestJson(
      validManifestPayload(version: '1.10.2', buildNumber: 51),
    );
    final latestEnvelope = UpdateManifestEnvelope.tryParse(
      jsonDecode(latestJson),
    ) as UpdateManifestEnvelope;
    final latestVerified = (await verifier.verify(latestEnvelope)).verified!;
    final target = _targetFrom(latestVerified);

    // 1) 磁盘上已经下载完成的 1.11.0（事故现场的事实）。
    final ready = layout.readyPackage(target);
    ready.parent.createSync(recursive: true);
    ready.writeAsBytesSync(List<int>.filled(target.sizeBytes, 7));

    // 2) 1.11.0 写的 v1 状态：ready + 已下载 + 旧 ETag。
    final v1State =
        <String, Object?>{
            ...UpdateState(
              phase: UpdatePhase.ready,
              currentMsixVersion: _installed1102.version,
              target: target,
              receivedBytes: target.sizeBytes,
              totalBytes: target.sizeBytes,
              manifestEtag: '"latest-1"',
              lastConfirmedUtc: DateTime.utc(2026, 10, 19, 9),
            ).toJson(),
            'schemaVersion': 1,
          }
          ..remove('baselinePreparation')
          ..remove('migratedFromSchemaVersion')
          ..remove('migrationDroppedFields');
    layout.stateFile.writeAsStringSync(jsonEncode(v1State));

    // 3) 旧版全局缓存（没有请求身份，必须被隔离，绝不能被当成 latest）。
    layout.legacyManifestCacheFile.writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'etag': '"legacy"',
        'envelope': jsonDecode(latestJson),
      }),
    );

    // 4) 真实仓库 + 真实缓存；网络用 MockClient。
    var latestRequests = 0;
    final cache = FileUpdateManifestCache(layout: layout, verifier: verifier);
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
        return http.Response('unexpected $url', 404);
      }),
    );

    final baseline = UpdateBaselineService(
      layout: layout,
      manifestSource: repository,
      downloader: _BaselineWritingDownloader(),
      verifier: FakeVerifier(),
      clock: FakeClock(),
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
      installCoordinator: coordinator,
      baselineService: baseline,
    );
    final controller = UpdateController(
      orchestrator: orchestrator,
      settings: JsonUpdateSettingsStore(settings: MemorySettingsRepository()),
      safety: safety,
    );
    addTearDown(controller.dispose);

    // 真实文件 IO 必须在 runAsync 中执行（widget 测试的假时钟不会推进真实 IO）。
    await tester.runAsync(() async {
      // 组合根在构造后立即隔离旧全局缓存（与 lib/main.dart 一致）。
      await cache.migrateLegacyIfNeeded();

      // 启动迁移：v1→v2；旧缓存隔离；收养磁盘上的 1.11.0。
      await controller.initialize();

      expect(
        controller.state.schemaVersion,
        updateStateSchemaVersion,
        reason: 'v1 状态必须被迁移而不是重置',
      );
      expect(
        controller.state.target?.msixVersion.value,
        '1.11.0.0',
        reason: '磁盘上已验证的 ready 必须被收养，不能因为状态清空而丢失',
      );
      expect(controller.state.phase, UpdatePhase.ready);
      expect(
        await layout.legacyManifestCacheFile.exists(),
        isFalse,
        reason: '旧全局缓存必须被隔离，不能被当成 latest',
      );

      // 第一次检查：latest 200，缓存按请求身份写入。
      await controller.checkNow();
      expect(latestRequests, 1);
      expect(controller.state.target?.msixVersion.value, '1.11.0.0');

      // 建立 1.10.2 回退基线（真实服务 + 真实文件 + 替身下载器）。
      await controller.ensureBaseline();
      expect(controller.state.baselinePreparation.phase.wireName, 'ready');
      expect(controller.state.baseline!.version.value, '1.10.2.0');
      expect(
        layout.baselinePackage(_installed1102.version).existsSync(),
        isTrue,
      );

      // 第二次检查收到 304：读到的必须是 latest 自己的缓存。
      await controller.checkNow();
      expect(
        controller.state.target?.msixVersion.value,
        '1.11.0.0',
        reason: '304 之后不能把已下载的 1.11.0 判成“已是最新版”',
      );
      expect(controller.state.phase, UpdatePhase.ready);
    });

    // 5) 真实 widget 路由：左下角仍显示可更新。
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
          updateController: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('update-indicator')), findsOneWidget);
    expect(find.text('更新已就绪'), findsOneWidget);
    expect(find.textContaining('已是最新版'), findsNothing);

    // 6) 点击更新：安装服务收到 target=1.11.0 与 rollback=1.10.2。
    //
    // 点击与后续异步链都必须在 runAsync 里推进：安装前置条件会再次严格校验基线文件
    // （真实文件 IO），而 widget 测试的假时钟不会推进这条链。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('update-indicator-button')));
      for (var i = 0; i < 300 && coordinator.prepareCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(coordinator.prepareCalls, 1);
    expect(coordinator.lastTarget!.msixVersion.value, '1.11.0.0');
    expect(coordinator.lastState!.baseline!.version.value, '1.10.2.0');
    expect(coordinator.lastInstalled!.version.value, '1.10.2.0');
  });
}

/// 删除临时目录；Windows 上偶发句柄占用时重试，收尾失败不算用例失败。
void _deleteQuietly(Directory directory, {int attempts = 5}) {
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      sleep(const Duration(milliseconds: 100));
    }
  }
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

/// 基线下载器：把目标大小写满文件（只用于本测试，真实下载器由生产代码提供）。
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
