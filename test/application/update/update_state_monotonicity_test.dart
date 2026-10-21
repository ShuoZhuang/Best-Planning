// 目标单调性（1.11.1 修复 §5.1 / INV-03 / INV-04 / UPD-INC-017 / UPD-INC-018）。
//
// 这些用例直接调用纯函数 `reconcileDiscovery`：事故里的"已下载 1.11.0 被 stale latest
// 清空"是决策逻辑的缺陷，把它从编排器的 IO 里拆出来之后可以穷举。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/update/manifest_request_key.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';

import '../../support/update_doubles.dart';

const InstalledPackage _installed1102 = InstalledPackage(
  identityName: appPackageIdentityName,
  publisher: appPublisher,
  familyName: appPackageFamilyName,
  architecture: PackageArchitecture.x64,
  version: MsixVersion(1, 10, 2, 0),
);

const UpdateTarget _target1110 = UpdateTarget(
  version: SemVer(1, 11, 0),
  buildNumber: 52,
  tag: 'v1.11.0',
  msixVersion: MsixVersion(1, 11, 0, 0),
  fileName: 'BestPlanning_1.11.0.0_x64.msix',
  downloadUrl: 'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.11.0/BestPlanning_1.11.0.0_x64.msix',
  sizeBytes: 2048,
  sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  manifestDigest:
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  keyId: 'best-planning-2026-10',
);

void main() {
  Future<VerifiedManifest> latest(
    String version,
    int buildNumber, {
    List<String> revoked = const [],
    ManifestRequestKey? key,
  }) async {
    final verified = await verifiedManifestFixture(
      version: version,
      buildNumber: buildNumber,
      revokedVersions: revoked,
    );
    return VerifiedManifest(
      manifest: verified.manifest,
      payloadJson: verified.payloadJson,
      canonicalDigest: verified.canonicalDigest,
      confirmedAtUtc: verified.confirmedAtUtc,
      requestKey: key ?? const ManifestRequestKey.latestStable(),
    );
  }

  test('ready(1.11.0) + 陈旧 latest(1.10.2) 保留 ready 与进度', () async {
    final current = const UpdateState(
      phase: UpdatePhase.ready,
      target: _target1110,
      receivedBytes: 2048,
      totalBytes: 2048,
    );

    final decision = reconcileDiscovery(
      installed: _installed1102,
      current: current,
      incomingLatest: await latest('1.10.2', 51),
    );

    expect(decision.target!.msixVersion.value, '1.11.0.0');
    expect(decision.phase, UpdatePhase.ready);
    expect(decision.staleLatestIgnored, isTrue);
    expect(decision.resetDownload, isFalse);
    expect(
      decision.classification,
      UpdateCheckClassification.temporarilyUnconfirmed,
      reason: '不能把"暂时无法确认"说成"已是最新"',
    );
  });

  test('target(1.11.0) + latest(1.11.1) 升级目标并重置下载', () async {
    final current = const UpdateState(
      phase: UpdatePhase.ready,
      target: _target1110,
      receivedBytes: 2048,
      totalBytes: 2048,
    );

    final decision = reconcileDiscovery(
      installed: _installed1102,
      current: current,
      incomingLatest: await latest('1.11.1', 53),
    );

    expect(decision.target!.msixVersion.value, '1.11.1.0');
    expect(decision.phase, UpdatePhase.updateAvailable);
    expect(decision.resetDownload, isTrue);
    expect(decision.classification, UpdateCheckClassification.updateAvailable);
  });

  test('同一目标只刷新元数据，不清空下载进度', () async {
    final current = const UpdateState(
      phase: UpdatePhase.downloading,
      target: _target1110,
      receivedBytes: 1024,
      totalBytes: 2048,
    );

    final decision = reconcileDiscovery(
      installed: _installed1102,
      current: current,
      incomingLatest: await latest('1.11.0', 52),
    );

    expect(decision.target!.msixVersion.value, '1.11.0.0');
    expect(decision.phase, UpdatePhase.downloading);
    expect(decision.resetDownload, isFalse);
  });

  test('明确撤回 target：禁止安装且不是 upToDate', () async {
    final current = const UpdateState(
      phase: UpdatePhase.ready,
      target: _target1110,
    );

    final decision = reconcileDiscovery(
      installed: _installed1102,
      current: current,
      incomingLatest: await latest('1.11.1', 53, revoked: ['1.11.0.0']),
    );

    expect(decision.targetRevoked, isTrue);
    expect(decision.target, isNull);
    expect(
      decision.classification,
      UpdateCheckClassification.sourceInvalid,
      reason: '撤回是明确事实，不是暂时无法确认',
    );
    expect(decision.failure!.code, UpdateFailureCode.packageVersionRevoked);
  });

  test('没有更高目标且 incoming == installed 才是 upToDate', () async {
    final decision = reconcileDiscovery(
      installed: _installed1102,
      current: const UpdateState(phase: UpdatePhase.upToDate),
      incomingLatest: await latest('1.10.2', 51),
    );

    expect(decision.classification, UpdateCheckClassification.upToDate);
    expect(decision.phase, UpdatePhase.upToDate);
    expect(decision.target, isNull);
  });

  test('已安装版本达到 target 时清理该目标', () async {
    final current = const UpdateState(
      phase: UpdatePhase.ready,
      target: _target1110,
    );

    final decision = reconcileDiscovery(
      installed: const InstalledPackage(
        identityName: appPackageIdentityName,
        publisher: appPublisher,
        familyName: appPackageFamilyName,
        architecture: PackageArchitecture.x64,
        version: MsixVersion(1, 11, 0, 0),
      ),
      current: current,
      incomingLatest: await latest('1.11.0', 52),
    );

    expect(decision.target, isNull);
    expect(decision.classification, UpdateCheckClassification.upToDate);
  });

  test('比已安装版本旧的 latest 且无更高目标：拒绝降级而不是 upToDate', () async {
    final decision = reconcileDiscovery(
      installed: _installed1102,
      current: const UpdateState(phase: UpdatePhase.upToDate),
      incomingLatest: await latest('1.9.0', 46),
    );

    expect(decision.classification, UpdateCheckClassification.sourceInvalid);
    expect(decision.failure!.code, UpdateFailureCode.packageDowngradeBlocked);
  });

  test('tag 来源的清单不能参与"最新版本"结论', () async {
    final decision = reconcileDiscovery(
      installed: _installed1102,
      current: const UpdateState(),
      incomingLatest: await latest(
        '1.11.0',
        52,
        key: ManifestRequestKey.releaseTag('v1.11.0'),
      ),
    );

    expect(decision.classification, UpdateCheckClassification.sourceInvalid);
    expect(decision.failure!.code, UpdateFailureCode.manifestSourceNotAllowed);
  });

  test('性质：任意低于保留目标的非撤回 incoming 都不会让 target 下降', () async {
    final incomingVersions = ['1.9.0', '1.10.0', '1.10.2', '1.11.0', '1.11.1'];
    final retained = [
      _target1110,
      const UpdateTarget(
        version: SemVer(1, 11, 1),
        buildNumber: 53,
        tag: 'v1.11.1',
        msixVersion: MsixVersion(1, 11, 1, 0),
        fileName: 'BestPlanning_1.11.1.0_x64.msix',
        downloadUrl: 'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.11.1/BestPlanning_1.11.1.0_x64.msix',
        sizeBytes: 2048,
        sha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        manifestDigest:
            'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
        keyId: 'best-planning-2026-10',
      ),
    ];
    for (final target in retained) {
      for (final version in incomingVersions) {
        final build = version == '1.11.1' ? 53 : 52;
        final decision = reconcileDiscovery(
          installed: _installed1102,
          current: UpdateState(phase: UpdatePhase.ready, target: target),
          incomingLatest: await latest(version, build),
        );
        final decided = decision.target?.msixVersion;
        expect(
          decided == null || decided >= target.msixVersion,
          isTrue,
          reason:
              'incoming=$version retained=${target.msixVersion.value} '
              'decided=${decided?.value}',
        );
        if (decision.classification == UpdateCheckClassification.upToDate) {
          fail('有更高 target 时不得给出 upToDate（incoming=$version）');
        }
      }
    }
  });
}
