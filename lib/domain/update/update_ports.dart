// 更新子系统的端口（规格 §5.2 的依赖方向）。
//
// 领域层只认识这些接口：它们全部是纯 Dart，参数与返回值只有领域类型，不出现 `File`、`Uri`
// 之外的 IO 细节（`String path` 是唯一允许的"文件"表示，由基础设施解释）。
// 这样编排器可以在测试里用内存/临时目录替身跑完整状态机，而不需要真的联网或装 MSIX。
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';

/// 已通过签名验证、并与来源绑定的清单。
final class VerifiedManifest {
  const VerifiedManifest({
    required this.manifest,
    required this.payloadJson,
    required this.canonicalDigest,
    required this.confirmedAtUtc,
    this.etag,
    this.fromCache = false,
    this.manifestUrl,
  });

  final UpdateManifest manifest;

  /// 原始 payload（信封里的 `payload` 节点）。缓存与再次验签都需要**原始字节对应的内容**，
  /// 而不是"解析后再序列化"的结果——后者会丢掉解析器不认识的字段，而签名覆盖的正是它们。
  final Map<String, Object?> payloadJson;

  /// 规范化 payload 字节的 SHA-256（64 位小写十六进制）。
  final String canonicalDigest;

  final DateTime confirmedAtUtc;

  final String? etag;

  /// 是否来自本地缓存（`304` 的有效缓存路径）。
  final bool fromCache;

  /// 实际取回清单的地址（用于诊断）。
  final String? manifestUrl;

  VerifiedManifest copyWith({
    DateTime? confirmedAtUtc,
    String? etag,
    bool? fromCache,
    String? manifestUrl,
  }) => VerifiedManifest(
    manifest: manifest,
    payloadJson: payloadJson,
    canonicalDigest: canonicalDigest,
    confirmedAtUtc: confirmedAtUtc ?? this.confirmedAtUtc,
    etag: etag ?? this.etag,
    fromCache: fromCache ?? this.fromCache,
    manifestUrl: manifestUrl ?? this.manifestUrl,
  );
}

/// 清单获取结果。**只有 [verified] 非空才算"确认过"**。
final class ManifestFetchResult {
  const ManifestFetchResult.verified(this.verified) : failure = null;

  const ManifestFetchResult.failed(this.failure) : verified = null;

  final VerifiedManifest? verified;
  final UpdateFailure? failure;

  bool get isVerified => verified != null;
}

/// 清单来源（固定地址 + 缓存 + `304` 处理 + 重定向限制）。
abstract interface class UpdateManifestSource {
  Future<ManifestFetchResult> fetchLatest({String? etag});

  Future<ManifestFetchResult> fetchForTag(String tag, {String? etag});
}

/// 已验证清单的本地缓存。**只缓存通过结构、来源与签名验证的清单**（规格 §7.5）。
abstract interface class UpdateManifestCache {
  Future<VerifiedManifest?> load();

  Future<void> save(VerifiedManifest manifest);

  Future<void> clear();
}

/// 持久状态存储（原子替换，损坏时可重建）。
abstract interface class UpdateStateStore {
  Future<UpdateState> load();

  Future<void> save(UpdateState state);

  /// 丢弃状态文件。用于"状态损坏且无法解释"时的重建。
  Future<void> reset();
}

/// 下载结果。
final class DownloadOutcome {
  const DownloadOutcome.success({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    this.etag,
    this.lastModified,
  }) : failure = null,
       cancelled = false;

  const DownloadOutcome.failed(this.failure, {this.cancelled = false})
    : path = null,
      sizeBytes = 0,
      sha256 = null,
      etag = null,
      lastModified = null;

  const DownloadOutcome.cancelled()
    : failure = null,
      path = null,
      sizeBytes = 0,
      sha256 = null,
      etag = null,
      lastModified = null,
      cancelled = true;

  final String? path;
  final int sizeBytes;
  final String? sha256;
  final String? etag;
  final String? lastModified;
  final UpdateFailure? failure;
  final bool cancelled;

  bool get isSuccess => path != null;
}

/// 后台下载器：`Range`/`If-Range`、断点续传、最终整文件 SHA-256（规格 §8）。
abstract interface class UpdatePackageDownloader {
  Future<DownloadOutcome> download({
    required UpdateTarget target,
    required String partialPath,
    required String readyPath,
    String? etag,
    String? lastModified,
    required bool Function() shouldCancel,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
  });
}

/// 包验证结论。三层信任全部通过才 [ok]（规格 §10.1）。
final class PackageVerification {
  const PackageVerification.valid({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    required this.identity,
    this.nativeSignatureVerified = false,
  }) : failure = null;

  const PackageVerification.invalid(this.failure)
    : path = null,
      sizeBytes = 0,
      sha256 = null,
      identity = null,
      nativeSignatureVerified = false;

  final String? path;
  final int sizeBytes;
  final String? sha256;

  /// 从包清单里读出的身份事实。
  final InstalledPackage? identity;

  /// Windows 原生验证（签名/证书链）是否也通过。交付层负责如实填写。
  final bool nativeSignatureVerified;

  final UpdateFailure? failure;

  bool get ok => failure == null && path != null;
}

/// 安装包验证器。
abstract interface class UpdatePackageVerifier {
  Future<PackageVerification> verify({
    required String path,
    required UpdateTarget target,
    required InstalledPackage installed,
    required bool verifyNativeSignature,
  });
}

/// 当前已安装包的事实来源。
abstract interface class InstalledPackageProvider {
  Future<InstalledPackage?> current();
}

/// 当前进程与指定进程的身份（PID + 启动时间）。pid 会被复用，只有两者同时匹配才是同一个进程。
final class ProcessIdentity {
  const ProcessIdentity({required this.pid, required this.startedAtUtc});

  final int pid;
  final DateTime startedAtUtc;
}

abstract interface class ProcessIdentityProbe {
  Future<ProcessIdentity> current();

  Future<ProcessIdentity?> forPid(int pid);
}

/// 更新助手的能力（探测、独立验证、执行安装）。
abstract interface class UpdateHelper {
  /// 助手版本与当前包信息。助手缺失时返回 `null`。
  Future<HelperProbe?> probe();

  /// 助手侧的独立二次验证（规格 §10.2）。
  Future<PackageVerification> verifyPackage({required String path});

  /// 启动助手并把一次性请求交给它。**返回后不保证安装成功**，只保证助手已取得请求。
  Future<HelperLaunchResult> launch(UpdateHelperRequest request);
}

/// 一次安装准备的结果。只有 [launched] 为真时主程序才允许退出。
final class InstallPreparationOutcome {
  const InstallPreparationOutcome.launched({
    this.transactionId,
    this.snapshotPath,
  }) : failure = null;

  const InstallPreparationOutcome.failed(this.failure)
    : transactionId = null,
      snapshotPath = null;

  final UpdateFailure? failure;
  final String? transactionId;
  final String? snapshotPath;

  bool get launched => failure == null;
}

/// 安装准备：快照、一次性请求、启动助手与握手（规格 §12.3 第 1～9 步）。
abstract interface class UpdateInstallCoordinator {
  Future<InstallPreparationOutcome> prepareAndLaunch({
    required UpdateTarget target,
    required UpdateState state,
    required InstalledPackage installed,
  });

  /// 助手已握手后，主程序才调用它退出。
  Future<void> requestExit();
}

final class HelperProbe {
  const HelperProbe({
    required this.helperVersion,
    required this.protocolVersion,
    this.installedPackage,
  });

  final String helperVersion;
  final int protocolVersion;
  final InstalledPackage? installedPackage;
}

final class HelperLaunchResult {
  const HelperLaunchResult.started() : failure = null, failureCode = null;

  const HelperLaunchResult.failed(this.failure) : failureCode = null;

  const HelperLaunchResult.handshakeFailed(this.failureCode) : failure = null;

  final UpdateFailure? failure;
  final String? failureCode;

  bool get isLaunched => failure == null && failureCode == null;
}

/// 一次性安装请求（规格 §12.2）。由主程序原子写入，助手只读一次。
final class UpdateHelperRequest {
  const UpdateHelperRequest({
    required this.schemaVersion,
    required this.transactionId,
    required this.fromVersion,
    required this.toVersion,
    required this.packagePath,
    required this.packageSizeBytes,
    required this.packageSha256,
    required this.identityName,
    required this.familyName,
    required this.publisher,
    required this.architecture,
    required this.mainPid,
    required this.mainStartedAtUtc,
    required this.trayPid,
    required this.trayStartedAtUtc,
    required this.token,
    required this.createdAtUtc,
    required this.expiresAtUtc,
    required this.rollbackPackagePath,
    required this.rollbackVersion,
    required this.snapshotPath,
    this.dataDirectory,
  });

  final int schemaVersion;
  final String transactionId;
  final MsixVersion fromVersion;
  final MsixVersion toVersion;
  final String packagePath;
  final int packageSizeBytes;
  final String packageSha256;
  final String identityName;
  final String familyName;
  final String publisher;
  final String architecture;
  final int mainPid;
  final DateTime mainStartedAtUtc;
  final int trayPid;
  final DateTime trayStartedAtUtc;
  final String token;
  final DateTime createdAtUtc;
  final DateTime expiresAtUtc;
  final String? rollbackPackagePath;
  final MsixVersion? rollbackVersion;
  final String? snapshotPath;

  /// 业务数据目录：回退时快照按相对路径恢复到它下面。
  final String? dataDirectory;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'transactionId': transactionId,
    'fromVersion': fromVersion.value,
    'toVersion': toVersion.value,
    'packagePath': packagePath,
    'packageSizeBytes': packageSizeBytes,
    'packageSha256': packageSha256,
    'identityName': identityName,
    'familyName': familyName,
    'publisher': publisher,
    'architecture': architecture,
    'mainPid': mainPid,
    'mainStartedAtUtc': mainStartedAtUtc.toUtc().toIso8601String(),
    'trayPid': trayPid,
    'trayStartedAtUtc': trayStartedAtUtc.toUtc().toIso8601String(),
    'token': token,
    'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
    'expiresAtUtc': expiresAtUtc.toUtc().toIso8601String(),
    'rollbackPackagePath': rollbackPackagePath,
    'rollbackVersion': rollbackVersion?.value,
    'snapshotPath': snapshotPath,
    'dataDirectory': dataDirectory,
  };
}

/// 跨进程锁（规格 §15.1）。陈旧锁必须同时核对 PID 与进程启动时间。
abstract interface class UpdateLock {
  Future<bool> acquire({
    required String transactionId,
    required int pid,
    required DateTime processStartedAtUtc,
    required String token,
    required String operation,
    required String targetVersion,
  });

  Future<void> release();

  /// 当前是否被另一个存活进程持有。
  Future<LockInspection> inspect();
}

final class LockInspection {
  const LockInspection.free()
    : holderPid = null,
      holderStartedAtUtc = null,
      operation = null;

  const LockInspection.held({
    required this.holderPid,
    required this.holderStartedAtUtc,
    required this.operation,
  });

  final int? holderPid;
  final DateTime? holderStartedAtUtc;
  final String? operation;

  bool get isHeld => holderPid != null;
}

/// 磁盘余量探测。返回目标路径所在卷的可用字节数。
abstract interface class DiskSpaceProbe {
  Future<int?> availableBytes(String path);
}

/// 网络可用性。仅用于"从不可用变为可用"这一种触发（规格 §7.1）。
abstract interface class NetworkStatusMonitor {
  bool get isAvailable;

  Stream<bool> get changes;
}

/// 更新日志。单文件不超过 2 MB，最多 5 个轮转文件（规格 §14.4）。
abstract interface class UpdateLogSink {
  void write(UpdateFailure failure);

  void writeLine(String line);

  /// 最近的日志行（诊断页展示用，最多 [maxLines] 行）。
  Future<List<String>> readRecent({int maxLines = 200});

  Future<void> clear();
}
