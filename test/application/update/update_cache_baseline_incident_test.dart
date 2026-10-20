// 1.11.1 事故序列：latest / tag 共用缓存、304 误用缓存、same 清空目标、ready 孤儿。
//
// 这些用例与其它更新测试的区别是：**不分别替换组件**。清单仓库与真实文件缓存一起使用，
// 编排器与真实状态存储/真实磁盘目录一起使用——事故正是发生在组件之间的顺序上，把任何
// 一方换成"各自 fake"都会把缺陷重新藏起来。
//
// 对应用户可见现象（1.10.2 已下载 1.11.0 后显示"已是最新版"、安装被永久阻塞）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';
import 'package:personal_planner/infrastructure/update/file_update_manifest_cache.dart';
import 'package:personal_planner/infrastructure/update/http_update_manifest_repository.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_doubles.dart';
import '../../support/update_fixtures.dart';

/// 1.10.2 已安装：事故机器上的当前版本。
const InstalledPackage installed1102 = InstalledPackage(
  identityName: appPackageIdentityName,
  publisher: appPublisher,
  familyName: appPackageFamilyName,
  architecture: PackageArchitecture.x64,
  version: MsixVersion(1, 10, 2, 0),
);

/// 已下载完成、签名与哈希都验证过的 1.11.0。
const UpdateTarget target1110 = UpdateTarget(
  version: SemVer(1, 11, 0),
  buildNumber: 52,
  tag: 'v1.11.0',
  msixVersion: MsixVersion(1, 11, 0, 0),
  fileName: 'BestPlanning_1.11.0.0_x64.msix',
  downloadUrl: 'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.11.0/BestPlanning_1.11.0.0_x64.msix',
  sizeBytes: 2048,
  sha256: testPackageSha256,
  manifestDigest:
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  keyId: 'test-key-2026-10',
);

void main() {
  late Directory directory;
  late UpdateStorageLayout layout;
  late Ed25519ManifestVerifier verifier;
  late String latestJson;
  late String tag1102Json;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('update_incident_test_');
    layout = UpdateStorageLayout(root: directory);
    verifier = await createTestVerifier();
    latestJson = await signedManifestJson(
      validManifestPayload(version: '1.11.0', buildNumber: 52),
    );
    tag1102Json = await signedManifestJson(
      validManifestPayload(version: '1.10.2', buildNumber: 51),
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// 一个按**请求地址**分流的假 GitHub：latest 与 tag 返回不同版本。
  MockClient incidentClient({
    required void Function(http.Request request) onRequest,
  }) => MockClient((request) async {
    onRequest(request);
    final url = request.url.toString();
    if (url == updateManifestLatestUrl) {
      if (request.headers['If-None-Match'] == '"latest-1"') {
        return http.Response('', 304, headers: {'etag': '"latest-1"'});
      }
      return _jsonResponse(latestJson, etag: '"latest-1"');
    }
    if (url.contains('/releases/download/v1.10.2/')) {
      return _jsonResponse(tag1102Json, etag: '"tag-1102"');
    }
    return http.Response('unexpected $url', 404);
  });

  FileUpdateManifestCache createCache() =>
      FileUpdateManifestCache(layout: layout, verifier: verifier);

  test('latest 1.11.0 后读取 v1.10.2 tag 再收到 latest 304 不得返回 1.10.2', () async {
    final requests = <String>[];
    final repository = HttpUpdateManifestRepository(
      cache: createCache(),
      verifier: verifier,
      client: incidentClient(
        onRequest: (request) {
          requests.add(
            '${request.url} if-none-match=${request.headers['If-None-Match']}',
          );
        },
      ),
    );

    final first = await repository.fetchLatest();
    expect(
      first.verified?.manifest.msixVersion.value,
      '1.11.0.0',
      reason: 'latest 的第一次 200 应得到 1.11.0',
    );

    final tag = await repository.fetchForTag('v1.10.2');
    expect(
      tag.verified?.manifest.msixVersion.value,
      '1.10.2.0',
      reason: 'tag 请求本身仍然是 1.10.2（不可变历史清单）',
    );

    final second = await repository.fetchLatest();

    expect(
      second.isVerified,
      isTrue,
      reason: '304 且 latest 缓存有效时必须返回已验证清单，实际失败=${second.failure?.code}',
    );
    expect(
      second.verified!.manifest.msixVersion.value,
      '1.11.0.0',
      reason:
          '304 只能使用 latest 自己的缓存；返回 1.10.2 会把已下载的 1.11.0 判成"已是最新版"。'
          '请求序列=${requests.join(' | ')}',
    );
  });

  test('基线与 latest 并发完成顺序变化不影响最终版本结论', () async {
    // 两种顺序各用一份独立缓存目录：先 latest 后 tag、先 tag 后 latest。
    for (final tagFirst in [false, true]) {
      final orderDirectory = Directory.systemTemp.createTempSync(
        'update_incident_order_',
      );
      addTearDown(() {
        if (orderDirectory.existsSync()) {
          orderDirectory.deleteSync(recursive: true);
        }
      });
      final requests = <String>[];
      final repository = HttpUpdateManifestRepository(
        cache: FileUpdateManifestCache(
          layout: UpdateStorageLayout(root: orderDirectory),
          verifier: verifier,
        ),
        verifier: verifier,
        client: incidentClient(
          onRequest: (request) => requests.add(request.url.toString()),
        ),
      );

      late ManifestFetchResult tagResult;
      if (tagFirst) {
        tagResult = await repository.fetchForTag('v1.10.2');
        await repository.fetchLatest();
      } else {
        await repository.fetchLatest();
        tagResult = await repository.fetchForTag('v1.10.2');
      }
      expect(tagResult.verified?.manifest.msixVersion.value, '1.10.2.0');

      final confirm = await repository.fetchLatest();
      expect(
        confirm.verified?.manifest.msixVersion.value,
        '1.11.0.0',
        reason:
            'tagFirst=$tagFirst 时最终结论被基线的 1.10.2 覆盖。'
            '请求序列=${requests.join(' | ')}',
      );
    }
  });

  test('已就绪 1.11.0 时陈旧 same 清单不得清空 target', () async {
    final layout = UpdateStorageLayout(root: directory);
    final ready = layout.readyPackage(target1110);
    await ready.parent.create(recursive: true);
    await ready.writeAsBytes(List<int>.filled(target1110.sizeBytes, 0));
    final store = InMemoryStateStore(
      UpdateState(
        phase: UpdatePhase.ready,
        currentMsixVersion: installed1102.version,
        target: target1110,
        receivedBytes: target1110.sizeBytes,
        totalBytes: target1110.sizeBytes,
        manifestEtag: '"latest-1"',
        lastConfirmedUtc: DateTime.utc(2026, 10, 19, 9),
      ),
    );
    final stale = await verifiedManifestFixture(
      version: '1.10.2',
      buildNumber: 51,
    );
    final log = MemoryLogSink();
    final orchestrator = UpdateOrchestrator(
      manifestSource: FakeManifestSource(ManifestFetchResult.verified(stale)),
      stateStore: store,
      installedPackages: FakeInstalledPackages(installed1102),
      downloader: FakeDownloader(),
      verifier: FakeVerifier(),
      layout: layout,
      safety: InMemoryUpdateSafetyCoordinator(),
      log: log,
      clock: FakeClock(),
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    );
    await orchestrator.initialize();

    final result = await orchestrator.check(manual: true, autoDownload: false);

    expect(
      orchestrator.state.target?.msixVersion.value,
      '1.11.0.0',
      reason: '陈旧/相同的最新清单不得清空已下载的更高目标',
    );
    expect(
      orchestrator.state.phase,
      UpdatePhase.ready,
      reason:
          '已就绪的 1.11.0 不能退化成 upToDate；实际 phase=${orchestrator.state.phase.wireName}',
    );
    expect(
      result.classification,
      isNot(UpdateCheckClassification.upToDate),
      reason: '本机是 1.10.2 且已有 1.11.0 目标，绝不能显示"已是最新版"',
    );
  });

  test('状态被清空但磁盘 ready 有效时启动恢复收养 1.11.0', () async {
    final layout = UpdateStorageLayout(root: directory);
    final ready = layout.readyPackage(target1110);
    await ready.parent.create(recursive: true);
    await ready.writeAsBytes(List<int>.filled(target1110.sizeBytes, 7));

    final verified = await verifiedManifestFixture(
      version: '1.11.0',
      buildNumber: 52,
    );
    final store = InMemoryStateStore();
    final log = MemoryLogSink();
    final orchestrator = UpdateOrchestrator(
      manifestSource: FakeManifestSource(
        ManifestFetchResult.verified(verified),
      ),
      stateStore: store,
      installedPackages: FakeInstalledPackages(installed1102),
      downloader: FakeDownloader(),
      verifier: FakeVerifier(),
      layout: layout,
      safety: InMemoryUpdateSafetyCoordinator(),
      log: log,
      clock: FakeClock(),
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    );

    await orchestrator.initialize();

    expect(await ready.exists(), isTrue, reason: '有效 ready 不得被静默删除');
    expect(
      orchestrator.state.target?.msixVersion.value,
      '1.11.0.0',
      reason: '状态文件只是线索；磁盘上已验证的 ready 必须被收养',
    );
    expect(
      orchestrator.state.phase,
      UpdatePhase.ready,
      reason:
          '收养后应回到 ready，而不是 idle/upToDate；实际=${orchestrator.state.phase.wireName}',
    );
  });
}

/// 清单响应必须显式声明 UTF-8：`http.Response` 在没有 `charset` 时按 latin1 编码，
/// 中文标题会让响应构造直接抛异常，从而掩盖真正的缺陷。
http.Response _jsonResponse(String body, {String? etag}) => http.Response(
  body,
  200,
  headers: {'content-type': 'application/json; charset=utf-8', 'etag': ?etag},
);
