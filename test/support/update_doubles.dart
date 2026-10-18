// 更新编排器的测试替身。
//
// 这些替身只实现端口，不模拟网络或文件系统——编排器的价值在于"什么时候推进状态、
// 失败怎么分类"，把它绑到真实 IO 上会让测试又慢又脆。
import 'dart:async';

import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';

import 'update_fixtures.dart';

final class FakeClock implements Clock {
  FakeClock([DateTime? now]) : _now = now ?? DateTime.utc(2026, 10, 18, 12);

  DateTime _now;

  set now(DateTime value) => _now = value;

  void advance(Duration duration) => _now = _now.add(duration);

  @override
  DateTime nowUtc() => _now;
}

final class InMemoryStateStore implements UpdateStateStore {
  InMemoryStateStore([this.state = const UpdateState()]);

  UpdateState state;
  int saveCount = 0;

  @override
  Future<UpdateState> load() async => state;

  @override
  Future<void> save(UpdateState value) async {
    state = value;
    saveCount++;
  }

  @override
  Future<void> reset() async {
    state = const UpdateState();
  }
}

final class FakeInstalledPackages implements InstalledPackageProvider {
  FakeInstalledPackages([this.value = installedFixture]);

  InstalledPackage? value;

  @override
  Future<InstalledPackage?> current() async => value;
}

const InstalledPackage installedFixture = InstalledPackage(
  identityName: appPackageIdentityName,
  publisher: appPublisher,
  familyName: appPackageFamilyName,
  architecture: PackageArchitecture.x64,
  version: MsixVersion(1, 8, 1, 0),
);

/// 与 [verifiedManifestFixture] 默认 payload 对应的目标。
const UpdateTarget targetFixture = UpdateTarget(
  version: SemVer(1, 9, 0),
  buildNumber: 46,
  tag: 'v1.9.0',
  msixVersion: MsixVersion(1, 9, 0, 0),
  fileName: 'BestPlanning_1.9.0.0_x64.msix',
  downloadUrl:
      'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/BestPlanning_1.9.0.0_x64.msix',
  sizeBytes: 2048,
  sha256: testPackageSha256,
  manifestDigest:
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  keyId: 'test-key-2026-10',
);

final class FakeManifestSource implements UpdateManifestSource {
  FakeManifestSource(this.result);

  ManifestFetchResult result;
  int calls = 0;
  String? lastEtag;

  @override
  Future<ManifestFetchResult> fetchLatest({String? etag}) async {
    calls++;
    lastEtag = etag;
    return result;
  }

  @override
  Future<ManifestFetchResult> fetchForTag(String tag, {String? etag}) async =>
      result;
}

final class FakeDownloader implements UpdatePackageDownloader {
  FakeDownloader({this.outcome, this.onDownload});

  DownloadOutcome? outcome;
  Future<DownloadOutcome> Function()? onDownload;
  int calls = 0;
  int cancelChecks = 0;

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
    onProgress(0, target.sizeBytes);
    final custom = onDownload;
    if (custom != null) return custom();
    onProgress(target.sizeBytes, target.sizeBytes);
    return outcome ??
        DownloadOutcome.success(
          path: readyPath,
          sizeBytes: target.sizeBytes,
          sha256: target.sha256,
        );
  }
}

final class FakeVerifier implements UpdatePackageVerifier {
  FakeVerifier({this.onVerify});

  PackageVerification Function()? onVerify;
  int calls = 0;
  bool? lastNativeFlag;

  @override
  Future<PackageVerification> verify({
    required String path,
    required UpdateTarget target,
    required InstalledPackage installed,
    required bool verifyNativeSignature,
  }) async {
    calls++;
    lastNativeFlag = verifyNativeSignature;
    final custom = onVerify;
    if (custom != null) return custom();
    return PackageVerification.valid(
      path: path,
      sizeBytes: target.sizeBytes,
      sha256: target.sha256,
      identity: installedFixture,
    );
  }
}

final class MemoryLogSink implements UpdateLogSink {
  final List<String> lines = [];

  @override
  void write(UpdateFailure failure) => lines.add(failure.diagnosticLine);

  @override
  void writeLine(String line) => lines.add(line);

  @override
  Future<List<String>> readRecent({int maxLines = 200}) async =>
      lines.length <= maxLines ? lines : lines.sublist(lines.length - maxLines);

  @override
  Future<void> clear() async => lines.clear();
}

final class FakeDiskSpace implements DiskSpaceProbe {
  FakeDiskSpace(this.available);

  int? available;

  @override
  Future<int?> availableBytes(String path) async => available;
}

/// 构造一份**真实签名并通过验证**的清单结果。
Future<VerifiedManifest> verifiedManifestFixture({
  String version = '1.9.0',
  int buildNumber = 46,
  List<String> revokedVersions = const [],
  String? publisher,
  String? identityName,
  String? architecture,
}) async {
  final payload = validManifestPayload(
    version: version,
    buildNumber: buildNumber,
    revokedVersions: revokedVersions,
  );
  if (publisher != null) {
    payload['compatibility'] =
        (payload['compatibility']! as Map).cast<String, Object?>();
    (payload['compatibility']! as Map)['publisher'] = publisher;
  }
  if (identityName != null) {
    (payload['compatibility']! as Map)['packageIdentityName'] = identityName;
  }
  if (architecture != null) {
    (payload['compatibility']! as Map)['architecture'] = architecture;
  }
  final envelope = UpdateManifestEnvelope.tryParse(
    await signedManifestEnvelope(payload),
  ) as UpdateManifestEnvelope;
  final verifier = await createTestVerifier();
  final result = await verifier.verify(envelope);
  final verified = result.verified;
  if (verified == null) {
    throw StateError('测试夹具签名失败：${result.failure?.code}');
  }
  return verified;
}

/// 阻塞直到被放行的下载器，用于测试"下载期间不再并发检查"。
final class BlockingDownloader implements UpdatePackageDownloader {
  final Completer<void> started = Completer<void>();
  final Completer<DownloadOutcome> _outcome = Completer<DownloadOutcome>();

  void complete(DownloadOutcome outcome) => _outcome.complete(outcome);

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
    if (!started.isCompleted) started.complete();
    final result = await _outcome.future;
    if (result.isSuccess) {
      onProgress(target.sizeBytes, target.sizeBytes);
    }
    return result;
  }
}

/// 一个总是"暂时无法确认"的清单来源（网络失败）。
ManifestFetchResult networkFailureFixture() => ManifestFetchResult.failed(
  const UpdateFailure(UpdateFailureCode.networkOffline),
);
