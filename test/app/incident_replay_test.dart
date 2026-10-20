// 真实事故目录回放（1.11.1 §7 验收 / §11 完成定义中的"事故机器自愈"）。
//
// **它做什么**：把一台真实事故机器的 `Updates` 目录整份复制到临时目录，然后用 1.11.1 的
// 真实实现（真实文件缓存、真实状态存储、真实 Ed25519 公钥、真实 GitHub 清单）跑一遍
// "启动 → 检查 → 建/复用基线 → 304" 的链路，断言：
//   · v1 状态被迁移而不是重置；
//   · 旧全局缓存被隔离，绝不被当成 latest；
//   · 磁盘上已下载的 1.11.0 被**复用**（不再重新下载 19 MB）；
//   · 1.10.2 回退基线通过严格校验并被标记 ready；
//   · 304 之后目标仍是 1.11.0，而不是"已是最新版"。
//
// **它不做什么**：不安装任何包、不改动真实目录（只读源目录 + 写副本），也不替代签名安装验收。
//
// 运行方式（默认在常规测试中跳过，保证 CI 不需要事故机器与网络）：
//
//   $env:INCIDENT_UPDATE_ROOT = 'C:\Users\<user>\AppData\Local\Packages\<PFN>\LocalCache\BestPlanning\Updates'
//   & G:\best-planing\.tooling\fx.ps1 test --no-pub --timeout 300s test/app/incident_replay_test.dart
//
// 可选：`INCIDENT_APPX_MANIFEST` 指向已安装包的 `AppxManifest.xml`（默认自动在
// `C:\Program Files\WindowsApps\ShuoZhuang.PersonalPlanner_*` 下查找最新的一个）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_baseline_service.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/update/manifest_request_key.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_baseline_status.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/ed25519_manifest_verifier.dart';
import 'package:personal_planner/infrastructure/update/file_update_manifest_cache.dart';
import 'package:personal_planner/infrastructure/update/file_update_state_store.dart';
import 'package:personal_planner/infrastructure/update/http_update_manifest_repository.dart';
import 'package:personal_planner/infrastructure/update/update_package_verifier.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';
import 'package:xml/xml.dart';

import '../support/update_doubles.dart';

void main() {
  final incidentRoot = Platform.environment['INCIDENT_UPDATE_ROOT'];
  final skipReason = incidentRoot == null || incidentRoot.trim().isEmpty
      ? '未设置 INCIDENT_UPDATE_ROOT：本用例只在真实事故机器上执行'
      : null;

  test(
    '真实事故目录：1.10.2 + 已下载 1.11.0 在 1.11.1 下自愈且不重下',
    () async {
      final source = Directory(incidentRoot!);
      expect(source.existsSync(), isTrue, reason: '事故目录不存在：$incidentRoot');

      // 1) 只读源目录，全部操作发生在副本上。
      final working = Directory.systemTemp.createTempSync('incident_replay_');
      addTearDown(() {
        // 收尾清理失败（Windows 句柄占用）不应把用例判红。
        for (var attempt = 0; attempt < 5; attempt++) {
          try {
            if (working.existsSync()) working.deleteSync(recursive: true);
            return;
          } on FileSystemException {
            sleep(const Duration(milliseconds: 100));
          }
        }
      });
      _copyTree(source, working);
      final layout = UpdateStorageLayout(root: working);
      // 状态文件里存的是绝对路径。副本换了根目录，必须把路径前缀一起搬过去——
      // 真实机器上它们本来就在自己的更新根内（INV-06 要求基线位于更新根下）。
      _relocateStatePaths(layout, from: source, to: working);

      // 2) 事实盘点（作为断言的前置条件，也写进输出便于取证）。
      final readiness = _describeRealState(layout);
      // ignore: avoid_print
      print('INCIDENT: $readiness');

      final legacyCache = layout.legacyManifestCacheFile;
      expect(
        legacyCache.existsSync(),
        isTrue,
        reason: '真实事故目录里应有 1.11.0 写的全局缓存（验证迁移路径）',
      );
      final stateJson = jsonDecode(
        layout.stateFile.readAsStringSync(),
      ) as Map<String, Object?>;
      expect(
        stateJson['schemaVersion'],
        1,
        reason: '真实事故状态是 v1；不是 v1 就说明这台机器已经不是事故现场',
      );
      final migratedTarget = stateJson['target'];
      // 事故现场：target 已被清空，只剩 baseline 与磁盘上的 ready。
      expect(migratedTarget, isNull, reason: '事故状态应已丢失 target');
      final readyFiles = layout
          .versionDirectories()
          .map(
            (directory) => File(
              '${directory.path}${Platform.pathSeparator}package.msix.ready',
            ),
          )
          .where((file) => file.existsSync())
          .toList();
      expect(readyFiles, isNotEmpty, reason: '事故机器上应留有已下载的包');

      // 3) 真实实现：生产公钥验签 + 真实 GitHub + 真实文件。
      final verifier = Ed25519ManifestVerifier();
      final cache = FileUpdateManifestCache(layout: layout, verifier: verifier);
      final log = MemoryLogSink();
      final repository = HttpUpdateManifestRepository(
        cache: cache,
        verifier: verifier,
        log: log,
      );
      addTearDown(repository.close);

      await cache.migrateLegacyIfNeeded();
      expect(legacyCache.existsSync(), isFalse, reason: '旧缓存必须被隔离');
      expect(
        layout.legacyManifestCacheQuarantineFile.existsSync(),
        isTrue,
        reason: '旧缓存应留一份隔离证据',
      );

      final installed = _installedPackageFromOs();
      // ignore: avoid_print
      print('INSTALLED: ${installed.version.value} ${installed.publisher}');

      final safety = InMemoryUpdateSafetyCoordinator();
      addTearDown(safety.dispose);
      // 复用 19 MB 的已验证包：任何真实下载都会让用例失败。
      final downloader = _ForbiddenDownloader();
      final orchestrator = UpdateOrchestrator(
        manifestSource: repository,
        stateStore: FileUpdateStateStore(file: layout.stateFile),
        installedPackages: _FixedInstalledPackages(installed),
        downloader: downloader,
        verifier: ZipUpdatePackageVerifier(),
        layout: layout,
        safety: safety,
        log: log,
        clock: const SystemClock(),
        // 未装配原生助手：只跳过 Windows 原生签名，结构/哈希/身份仍是真实校验。
        baselineService: UpdateBaselineService(
          layout: layout,
          manifestSource: repository,
          downloader: downloader,
          verifier: ZipUpdatePackageVerifier(),
          clock: const SystemClock(),
          verifyNativeSignature: false,
        ),
      );

      // 4) 启动：v1→v2 迁移 + 基线严格复核。
      await orchestrator.initialize();
      expect(orchestrator.state.schemaVersion, updateStateSchemaVersion);
      expect(
        orchestrator.state.currentMsixVersion,
        installed.version,
        reason: '状态里"当前版本"必须以 Windows 实际安装版本为准',
      );
      expect(
        orchestrator.state.baselinePreparation.phase,
        BaselinePhase.ready,
        reason:
            '真实 1.10.2 基线应通过版本/长度/SHA-256/包身份/发布者校验；'
            '实际失败=${orchestrator.state.baselinePreparation.lastFailure?.code.code} '
            'detail=${orchestrator.state.baselinePreparation.lastFailure?.detail}',
      );

      // 5) 第一次真实检查：latest 200 → 发现 1.11.0 → 复用磁盘上的 ready。
      final first = await orchestrator.check(manual: true, autoDownload: true);
      // ignore: avoid_print
      print(
        'CHECK1: classification=${first.classification} '
        'phase=${orchestrator.state.phase.wireName} '
        'target=${orchestrator.state.target?.msixVersion.value}',
      );
      expect(
        orchestrator.state.target?.msixVersion.value,
        '1.11.0.0',
        reason: '丢失的 1.11.0 目标必须从真实线上清单恢复',
      );
      expect(orchestrator.state.phase, UpdatePhase.ready);
      expect(downloader.calls, 0, reason: '磁盘上已有完整且校验通过的 1.11.0，绝不能重新下载');

      // 6) 第二次真实检查：条件请求（304 或 200 都应保留目标）。
      final second = await orchestrator.check(
        manual: true,
        autoDownload: false,
      );
      // ignore: avoid_print
      print(
        'CHECK2: classification=${second.classification} '
        'fromCache=${second.manifest?.fromCache} '
        'target=${orchestrator.state.target?.msixVersion.value} '
        'phase=${orchestrator.state.phase.wireName}',
      );
      expect(
        orchestrator.state.target?.msixVersion.value,
        '1.11.0.0',
        reason: '重新确认（含 304）不得把已下载的 1.11.0 降级成"已是最新版"',
      );
      expect(orchestrator.state.phase, UpdatePhase.ready);
      expect(
        first.isConfirmedUpToDate,
        isFalse,
        reason: '本机是 1.10.2 且已有 1.11.0 目标，绝不是"已是最新版"',
      );

      // 7) 缓存分区与日志证据。
      final latestCache = layout.manifestCacheFile(
        const ManifestRequestKey.latestStable(),
      );
      expect(
        latestCache.existsSync(),
        isTrue,
        reason: 'latest 的缓存必须写在 manifests/latest-stable.json',
      );
      expect(latestCache.path, isNot(contains('update-manifest.cache.json')));
      expect(
        log.lines.any((line) => line.contains('ready_reused version=1.11.0.0')),
        isTrue,
        reason: '日志应记录复用而不是重新下载',
      );
      // ignore: avoid_print
      print('LOG: ${log.lines.join(' | ')}');
    },
    skip: skipReason,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

void _copyTree(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final entity in source.listSync(recursive: false)) {
    final name = entity.path.split(RegExp(r'[\\/]')).last;
    final destination = '${target.path}${Platform.pathSeparator}$name';
    if (entity is Directory) {
      _copyTree(entity, Directory(destination));
    } else if (entity is File) {
      // 用"读字节 + 写字节"而不是 `copySync`：真实目录里有 EFS 加密/带属性的文件，
      // `copySync` 会试图复制属性并在新位置重新加密而失败；内容本身仍可正常读取。
      try {
        File(destination).writeAsBytesSync(entity.readAsBytesSync());
      } on FileSystemException {
        // 个别文件（例如被占用的日志）读不出来时跳过：它们不参与本次判定。
      }
    }
  }
}

/// 把副本状态文件里的绝对路径从原根搬到副本根。
///
/// 真实机器上这些路径本就在自己的更新根内；副本换根后若不搬，基线会被"路径不在
/// 受控目录内"正确拒绝——那是**校验在起作用**，不是数据有问题。
void _relocateStatePaths(
  UpdateStorageLayout layout, {
  required Directory from,
  required Directory to,
}) {
  final file = layout.stateFile;
  if (!file.existsSync()) return;
  final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  String? move(Object? raw) {
    if (raw is! String) return null;
    final normalized = raw.toLowerCase().replaceAll('/', r'\');
    final prefix = from.path.toLowerCase().replaceAll('/', r'\');
    if (!normalized.startsWith(prefix)) return raw;
    return '${to.path}${raw.substring(from.path.length)}';
  }

  final baseline = json['baseline'];
  if (baseline is Map) {
    final moved = move(baseline['packagePath']);
    if (moved != null) baseline['packagePath'] = moved;
  }
  final snapshot = move(json['snapshotPath']);
  if (snapshot != null) json['snapshotPath'] = snapshot;
  file.writeAsStringSync(jsonEncode(json));
}

String _describeRealState(UpdateStorageLayout layout) {
  final entries = <String>[];
  for (final entity in layout.root.listSync(recursive: false)) {
    final name = entity.path.split(RegExp(r'[\\/]')).last;
    final size = entity is File ? ' ${entity.lengthSync()}B' : '';
    entries.add('$name$size');
  }
  final ready = layout
      .versionDirectories()
      .map(
        (directory) => File(
          '${directory.path}${Platform.pathSeparator}package.msix.ready',
        ),
      )
      .where((file) => file.existsSync())
      .map(
        (file) =>
            '${file.path.split(RegExp(r'[\\/]')).reversed.elementAt(1)} '
            '${file.lengthSync()}B',
      )
      .join(',');
  return 'root=${layout.root.path} entries=[${entries.join(', ')}] ready=[$ready]';
}

/// 从已安装的包读取真实身份（不猜、不写死版本）。
///
/// 顺序：显式 `INCIDENT_APPX_MANIFEST` → 扫描 `WindowsApps` → 查询 Appx 仓库
/// （`Get-AppxPackage`）。三者都是"读操作系统事实"，不是把版本写进测试。
InstalledPackage _installedPackageFromOs() {
  final explicit = Platform.environment['INCIDENT_APPX_MANIFEST'];
  if (explicit != null && explicit.isNotEmpty) {
    final manifest = File(explicit);
    if (!manifest.existsSync()) fail('INCIDENT_APPX_MANIFEST 不存在：$explicit');
    return _packageFromManifest(manifest);
  }

  const root = r'C:\Program Files\WindowsApps';
  final directory = Directory(root);
  if (directory.existsSync()) {
    try {
      final manifests = <File>[];
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = entity.path.split(RegExp(r'[\\/]')).last;
        if (!name.startsWith('ShuoZhuang.PersonalPlanner_')) continue;
        final manifest = File(
          '${entity.path}${Platform.pathSeparator}AppxManifest.xml',
        );
        if (manifest.existsSync()) manifests.add(manifest);
      }
      if (manifests.isNotEmpty) {
        manifests.sort((a, b) => b.path.compareTo(a.path));
        return _packageFromManifest(manifests.first);
      }
    } on FileSystemException {
      // 受保护目录读不出来时退回 Appx 仓库查询。
    }
  }

  final result = Process.runSync('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    r'Get-AppxPackage -Name ShuoZhuang.PersonalPlanner | '
        r'Select-Object Name,Publisher,Version,Architecture | '
        r'ConvertTo-Json -Compress',
  ]);
  if (result.exitCode != 0) {
    fail('无法读取已安装包身份：${result.stderr}');
  }
  final decoded = jsonDecode((result.stdout as String).trim());
  if (decoded is! Map) fail('Get-AppxPackage 没有返回可解析结果：${result.stdout}');
  final name = decoded['Name'] as String?;
  final publisher = decoded['Publisher'] as String?;
  final version = MsixVersion.tryParse(decoded['Version'] as String?);
  if (name == null || publisher == null || version == null) {
    fail('Get-AppxPackage 结果缺少 Name/Publisher/Version：$decoded');
  }
  return InstalledPackage(
    identityName: name,
    publisher: publisher,
    familyName: packageFamilyNameFor(name, publisher),
    architecture:
        PackageArchitecture.tryParse(decoded['Architecture'] as String?) ??
        PackageArchitecture.x64,
    version: version,
  );
}

InstalledPackage _packageFromManifest(File manifest) {
  final document = XmlDocument.parse(manifest.readAsStringSync());
  final identity = document
      .findAllElements('Identity')
      .where((element) => element.parentElement?.name.local == 'Package')
      .first;
  final name = identity.getAttribute('Name')!;
  final publisher = identity.getAttribute('Publisher')!;
  final version = MsixVersion.tryParse(identity.getAttribute('Version'))!;
  final architecture =
      PackageArchitecture.tryParse(
        identity.getAttribute('ProcessorArchitecture'),
      ) ??
      PackageArchitecture.neutral;
  return InstalledPackage(
    identityName: name,
    publisher: publisher,
    familyName: packageFamilyNameFor(name, publisher),
    architecture: architecture,
    version: version,
  );
}

final class _FixedInstalledPackages implements InstalledPackageProvider {
  const _FixedInstalledPackages(this.package);

  final InstalledPackage package;

  @override
  Future<InstalledPackage?> current() async => package;
}

/// 任何下载都会让"复用已验证包"的断言失效，因此这里直接失败并说明原因。
final class _ForbiddenDownloader implements UpdatePackageDownloader {
  int calls = 0;

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
    calls++;
    fail(
      '事故机器上不应发生下载：target=${target.msixVersion.value} '
      'ready=$readyPath（说明磁盘上的包没有被复用）',
    );
  }
}
