// 持久更新状态机（规格 §9）。
//
// **这个文件回答两个问题**：
//   1. 从当前阶段能不能走到下一阶段？——合法跳转集中成一张表，非法跳转不改变安全状态；
//   2. 程序上次在某个阶段崩溃后该怎么办？——恢复动作也是纯函数，编排器只负责执行。
//
// 状态本身只是**恢复线索**，不是事实（规格 §9.4）。启动时必须重新核对文件、进程、锁与
// Windows 实际包状态；因此这里刻意不提供"读到 ready 就直接安装"这类捷径。
import 'package:personal_planner/domain/update/rollback_baseline.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_version.dart';

/// 状态文件的结构版本。字段含义变化时提升它，并拒绝按旧结构解释。
const int updateStateSchemaVersion = 1;

/// 18 个阶段（规格 §9.1），名称与规格逐字对应。
enum UpdatePhase {
  idle('idle', '空闲'),
  checking('checking', '正在检查更新'),
  upToDate('upToDate', '已是最新版'),
  updateAvailable('updateAvailable', '发现新版本'),
  downloading('downloading', '正在下载'),
  downloadPaused('downloadPaused', '下载已暂停'),
  verifying('verifying', '正在验证更新包'),
  ready('ready', '更新已就绪'),
  temporarilyBlocked('temporarilyBlocked', '暂时无法确认'),
  preparingInstall('preparingInstall', '正在准备安装'),
  waitingForExit('waitingForExit', '等待程序退出'),
  installing('installing', '正在安装'),
  launchingNewVersion('launchingNewVersion', '正在启动新版本'),
  waitingForHealth('waitingForHealth', '正在确认新版本'),
  succeeded('succeeded', '更新完成'),
  rollingBack('rollingBack', '正在回退'),
  rolledBack('rolledBack', '已回退'),
  failed('failed', '更新失败');

  const UpdatePhase(this.wireName, this.label);

  /// 状态文件里写的是这个名字（camelCase，与规格一致）。
  final String wireName;

  /// 界面用的中文阶段名。
  final String label;

  static UpdatePhase? fromWireName(String? name) {
    if (name == null) return null;
    for (final phase in UpdatePhase.values) {
      if (phase.wireName == name) return phase;
    }
    return null;
  }
}

/// 合法跳转表。
///
/// 规格 §9.3 的六条禁止跳转在这里表现为"表里没有这条边"：
/// `downloading → ready`、`checking → installing`、`failed → installing`、
/// `upToDate → ready`、`temporarilyBlocked → installing`、未健康确认即 `succeeded`。
const Map<UpdatePhase, Set<UpdatePhase>> updatePhaseTransitions = {
  UpdatePhase.idle: {UpdatePhase.checking},
  UpdatePhase.checking: {
    UpdatePhase.upToDate,
    UpdatePhase.updateAvailable,
    UpdatePhase.temporarilyBlocked,
    UpdatePhase.failed,
    UpdatePhase.idle,
  },
  UpdatePhase.upToDate: {UpdatePhase.checking},
  UpdatePhase.updateAvailable: {
    UpdatePhase.downloading,
    UpdatePhase.checking,
    UpdatePhase.temporarilyBlocked,
    UpdatePhase.failed,
    UpdatePhase.ready,
  },
  UpdatePhase.downloading: {
    UpdatePhase.verifying,
    UpdatePhase.downloadPaused,
    UpdatePhase.temporarilyBlocked,
    UpdatePhase.failed,
    UpdatePhase.updateAvailable,
    UpdatePhase.checking,
  },
  UpdatePhase.downloadPaused: {
    UpdatePhase.downloading,
    UpdatePhase.failed,
    UpdatePhase.updateAvailable,
    UpdatePhase.checking,
  },
  UpdatePhase.verifying: {
    UpdatePhase.ready,
    UpdatePhase.failed,
    UpdatePhase.temporarilyBlocked,
    UpdatePhase.updateAvailable,
  },
  UpdatePhase.ready: {
    UpdatePhase.preparingInstall,
    UpdatePhase.verifying,
    UpdatePhase.failed,
    UpdatePhase.updateAvailable,
    UpdatePhase.checking,
  },
  UpdatePhase.temporarilyBlocked: {
    UpdatePhase.checking,
    UpdatePhase.downloading,
    UpdatePhase.ready,
    UpdatePhase.updateAvailable,
    UpdatePhase.failed,
  },
  UpdatePhase.preparingInstall: {
    UpdatePhase.waitingForExit,
    UpdatePhase.ready,
    UpdatePhase.failed,
  },
  UpdatePhase.waitingForExit: {
    UpdatePhase.installing,
    UpdatePhase.ready,
    UpdatePhase.failed,
  },
  UpdatePhase.installing: {UpdatePhase.launchingNewVersion, UpdatePhase.failed},
  UpdatePhase.launchingNewVersion: {
    UpdatePhase.waitingForHealth,
    UpdatePhase.failed,
  },
  UpdatePhase.waitingForHealth: {
    UpdatePhase.succeeded,
    UpdatePhase.rollingBack,
    UpdatePhase.failed,
  },
  UpdatePhase.succeeded: {UpdatePhase.idle, UpdatePhase.checking},
  UpdatePhase.rollingBack: {UpdatePhase.rolledBack, UpdatePhase.failed},
  UpdatePhase.rolledBack: {
    UpdatePhase.idle,
    UpdatePhase.checking,
    UpdatePhase.failed,
  },
  UpdatePhase.failed: {
    UpdatePhase.checking,
    UpdatePhase.downloading,
    UpdatePhase.verifying,
    UpdatePhase.preparingInstall,
    UpdatePhase.rollingBack,
    UpdatePhase.idle,
  },
};

/// 崩溃恢复动作（规格 §9.5 的逐行映射）。
enum UpdateRecoveryAction {
  /// `idle`/`checking`：回到 `idle` 后重查。
  recheck,

  /// `downloading`：核对分段后续传。
  resumeDownload,

  /// `verifying`：从头验证完整文件。
  verifyFromScratch,

  /// `ready`：再次验证文件、哈希与签名。
  verifyReadyPackage,

  /// `temporarilyBlocked`：重新判断阻塞条件。
  recheckBlockers,

  /// `preparingInstall`：助手未启动则退回 `ready`。
  returnToReady,

  /// `waitingForExit`：检查助手和主进程实际状态。
  inspectHelperAndProcess,

  /// `installing`：查询 Windows 实际包状态。
  queryInstalledPackage,

  /// `waitingForHealth`：继续等待、确认或回退。
  continueHealthWait,

  /// `rollingBack`：恢复回退流程。
  resumeRollback,

  /// `succeeded`：核对版本后清理。
  verifyAndCleanup,

  /// `failed`：保留原因并等待合法重试。
  keepFailureAndWait,
}

/// 某阶段崩溃后的恢复动作。
UpdateRecoveryAction recoveryActionFor(UpdatePhase phase) => switch (phase) {
  UpdatePhase.idle || UpdatePhase.checking => UpdateRecoveryAction.recheck,
  UpdatePhase.upToDate ||
  UpdatePhase.updateAvailable => UpdateRecoveryAction.recheck,
  UpdatePhase.downloading => UpdateRecoveryAction.resumeDownload,
  UpdatePhase.downloadPaused => UpdateRecoveryAction.resumeDownload,
  UpdatePhase.verifying => UpdateRecoveryAction.verifyFromScratch,
  UpdatePhase.ready => UpdateRecoveryAction.verifyReadyPackage,
  UpdatePhase.temporarilyBlocked => UpdateRecoveryAction.recheckBlockers,
  UpdatePhase.preparingInstall => UpdateRecoveryAction.returnToReady,
  UpdatePhase.waitingForExit => UpdateRecoveryAction.inspectHelperAndProcess,
  UpdatePhase.installing => UpdateRecoveryAction.queryInstalledPackage,
  UpdatePhase.launchingNewVersion ||
  UpdatePhase.waitingForHealth => UpdateRecoveryAction.continueHealthWait,
  UpdatePhase.succeeded => UpdateRecoveryAction.verifyAndCleanup,
  UpdatePhase.rollingBack ||
  UpdatePhase.rolledBack => UpdateRecoveryAction.resumeRollback,
  UpdatePhase.failed => UpdateRecoveryAction.keepFailureAndWait,
};

/// 一次更新的目标事实。它把"清单说了什么"压缩成恢复时足够重新验证的字段。
final class UpdateTarget {
  const UpdateTarget({
    required this.version,
    required this.buildNumber,
    required this.tag,
    required this.msixVersion,
    required this.fileName,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.sha256,
    required this.manifestDigest,
    required this.keyId,
  });

  final SemVer version;
  final int buildNumber;
  final String tag;
  final MsixVersion msixVersion;
  final String fileName;
  final String downloadUrl;
  final int sizeBytes;
  final String sha256;

  /// 已验证清单 payload 的 SHA-256（规范化字节）。状态恢复时用它判断"还是不是同一份清单"。
  final String manifestDigest;

  final String keyId;

  Uri get downloadUri => Uri.parse(downloadUrl);

  Map<String, Object?> toJson() => {
    'version': version.value,
    'buildNumber': buildNumber,
    'tag': tag,
    'msixVersion': msixVersion.value,
    'fileName': fileName,
    'downloadUrl': downloadUrl,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'manifestDigest': manifestDigest,
    'keyId': keyId,
  };

  static UpdateTarget? tryParse(Object? json) {
    if (json is! Map) return null;
    final version = SemVer.tryParse(json['version'] as String?);
    final buildNumber = json['buildNumber'];
    final tag = json['tag'];
    final msixVersion = MsixVersion.tryParse(json['msixVersion'] as String?);
    final fileName = json['fileName'];
    final downloadUrl = json['downloadUrl'];
    final sizeBytes = json['sizeBytes'];
    final sha256 = json['sha256'];
    final manifestDigest = json['manifestDigest'];
    final keyId = json['keyId'];
    if (version == null ||
        buildNumber is! int ||
        buildNumber <= 0 ||
        tag is! String ||
        msixVersion == null ||
        fileName is! String ||
        downloadUrl is! String ||
        sizeBytes is! int ||
        sizeBytes <= 0 ||
        sha256 is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        manifestDigest is! String ||
        keyId is! String) {
      return null;
    }
    return UpdateTarget(
      version: version,
      buildNumber: buildNumber,
      tag: tag,
      msixVersion: msixVersion,
      fileName: fileName,
      downloadUrl: downloadUrl,
      sizeBytes: sizeBytes,
      sha256: sha256,
      manifestDigest: manifestDigest,
      keyId: keyId,
    );
  }

  @override
  String toString() =>
      'UpdateTarget(${msixVersion.value}, ${version.value}, $tag)';
}

/// 持久状态的全部字段（规格 §9.4）。
///
/// 可空的字段都用显式 `clear*` 之外的哨兵方式赋值：`copyWith` 里传 `null` 表示**清空**，
/// 不传表示保留。这样调用处写 `state.copyWith(healthDeadlineUtc: null)` 的意图是明确的。
final class UpdateState {
  const UpdateState({
    this.schemaVersion = updateStateSchemaVersion,
    this.phase = UpdatePhase.idle,
    this.currentMsixVersion,
    this.target,
    this.receivedBytes = 0,
    this.totalBytes,
    this.etag,
    this.lastModified,
    this.retryAttempt = 0,
    this.targetFailureCount = 0,
    this.pausedTargetVersion,
    this.nextAttemptUtc,
    this.lastCheckedUtc,
    this.lastConfirmedUtc,
    this.manifestEtag,
    this.lastCheckClassification,
    this.lastFailure,
    this.transactionId,
    this.baseline,
    this.snapshotPath,
    this.healthDeadlineUtc,
    this.helperStartedUtc,
    this.updatedAtUtc,
  });

  final int schemaVersion;
  final UpdatePhase phase;

  /// 最近一次核对到的已安装版本。**不是权威**，权威是 Windows 包身份。
  final MsixVersion? currentMsixVersion;

  final UpdateTarget? target;

  final int receivedBytes;
  final int? totalBytes;

  /// 下载响应里的 `ETag` / `Last-Modified`，用于 `If-Range`。
  final String? etag;
  final String? lastModified;

  final int retryAttempt;

  /// 同一目标版本的连续下载/验证失败次数。达到上限后停止自动重试（规格 §13.4 / UPD-039）。
  final int targetFailureCount;

  /// 已因"安装后未通过健康确认并回退"而暂停的版本。为空表示没有暂停。
  final String? pausedTargetVersion;

  final DateTime? nextAttemptUtc;

  final DateTime? lastCheckedUtc;

  /// 最近一次**成功验证**清单的时间（与 [lastCheckedUtc] 不同：失败也会更新后者）。
  final DateTime? lastConfirmedUtc;

  /// 清单响应的 ETag（与安装包的 [etag] 分开存）。
  final String? manifestEtag;

  final UpdateCheckClassification? lastCheckClassification;

  final UpdateFailure? lastFailure;

  /// 安装事务编号。请求文件、健康确认、助手状态都用它匹配。
  final String? transactionId;

  final RollbackBaseline? baseline;

  /// 更新前数据快照路径（快照文件本身由 `UpdateSnapshotService` 生成）。
  final String? snapshotPath;

  /// 健康确认的**绝对**截止时间（规格 §13.2：初始 60 秒，绝对上限 5 分钟）。
  final DateTime? healthDeadlineUtc;

  final DateTime? helperStartedUtc;

  final DateTime? updatedAtUtc;

  static const Object _unset = Object();

  static T? _pick<T>(Object? value, T? current) =>
      identical(value, _unset) ? current : value as T?;

  UpdateState copyWith({
    int? schemaVersion,
    Object? phase = _unset,
    Object? currentMsixVersion = _unset,
    Object? target = _unset,
    int? receivedBytes,
    Object? totalBytes = _unset,
    Object? etag = _unset,
    Object? lastModified = _unset,
    int? retryAttempt,
    int? targetFailureCount,
    Object? pausedTargetVersion = _unset,
    Object? nextAttemptUtc = _unset,
    Object? lastCheckedUtc = _unset,
    Object? lastConfirmedUtc = _unset,
    Object? manifestEtag = _unset,
    Object? lastCheckClassification = _unset,
    Object? lastFailure = _unset,
    Object? transactionId = _unset,
    Object? baseline = _unset,
    Object? snapshotPath = _unset,
    Object? healthDeadlineUtc = _unset,
    Object? helperStartedUtc = _unset,
    Object? updatedAtUtc = _unset,
  }) => UpdateState(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    phase: _pick(phase, this.phase)!,
    currentMsixVersion: _pick(currentMsixVersion, this.currentMsixVersion),
    target: _pick(target, this.target),
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: _pick(totalBytes, this.totalBytes),
    etag: _pick(etag, this.etag),
    lastModified: _pick(lastModified, this.lastModified),
    retryAttempt: retryAttempt ?? this.retryAttempt,
    targetFailureCount: targetFailureCount ?? this.targetFailureCount,
    pausedTargetVersion: _pick(pausedTargetVersion, this.pausedTargetVersion),
    nextAttemptUtc: _pick(nextAttemptUtc, this.nextAttemptUtc),
    lastCheckedUtc: _pick(lastCheckedUtc, this.lastCheckedUtc),
    lastConfirmedUtc: _pick(lastConfirmedUtc, this.lastConfirmedUtc),
    manifestEtag: _pick(manifestEtag, this.manifestEtag),
    lastCheckClassification: _pick(
      lastCheckClassification,
      this.lastCheckClassification,
    ),
    lastFailure: _pick(lastFailure, this.lastFailure),
    transactionId: _pick(transactionId, this.transactionId),
    baseline: _pick(baseline, this.baseline),
    snapshotPath: _pick(snapshotPath, this.snapshotPath),
    healthDeadlineUtc: _pick(healthDeadlineUtc, this.healthDeadlineUtc),
    helperStartedUtc: _pick(helperStartedUtc, this.helperStartedUtc),
    updatedAtUtc: _pick(updatedAtUtc, this.updatedAtUtc),
  );

  /// 从当前阶段能否走到 [next]。
  bool canTransitionTo(UpdatePhase next) =>
      updatePhaseTransitions[phase]!.contains(next);

  /// 推进到下一阶段；非法跳转返回未改变的状态与结构化错误（规格 §9.3）。
  UpdateTransitionResult transitionTo(UpdatePhase next, {DateTime? atUtc}) {
    if (!canTransitionTo(next)) {
      return UpdateTransitionResult.rejected(
        this,
        UpdateFailure(
          UpdateFailureCode.stateIllegalTransition,
          detail: '${phase.wireName} -> ${next.wireName}',
          occurredAtUtc: atUtc,
        ),
      );
    }
    return UpdateTransitionResult.accepted(
      copyWith(phase: next, updatedAtUtc: atUtc ?? updatedAtUtc),
    );
  }

  /// 下载中、校验中或安装中的状态：这些阶段不允许第二个事务并发进入（规格 §15.1）。
  bool get isBusy => switch (phase) {
    UpdatePhase.checking ||
    UpdatePhase.downloading ||
    UpdatePhase.verifying ||
    UpdatePhase.preparingInstall ||
    UpdatePhase.waitingForExit ||
    UpdatePhase.installing ||
    UpdatePhase.launchingNewVersion ||
    UpdatePhase.waitingForHealth ||
    UpdatePhase.rollingBack => true,
    _ => false,
  };

  /// 已经有可安装的 `.ready` 包。
  bool get hasReadyPackage => phase == UpdatePhase.ready && target != null;

  double? get downloadProgress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0, 1).toDouble();
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'phase': phase.wireName,
    'currentMsixVersion': currentMsixVersion?.value,
    'target': target?.toJson(),
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'etag': etag,
    'lastModified': lastModified,
    'retryAttempt': retryAttempt,
    'targetFailureCount': targetFailureCount,
    'pausedTargetVersion': pausedTargetVersion,
    'nextAttemptUtc': nextAttemptUtc?.toUtc().toIso8601String(),
    'lastCheckedUtc': lastCheckedUtc?.toUtc().toIso8601String(),
    'lastConfirmedUtc': lastConfirmedUtc?.toUtc().toIso8601String(),
    'manifestEtag': manifestEtag,
    'lastCheckClassification': lastCheckClassification?.name,
    'lastFailure': lastFailure == null
        ? null
        : {
            'code': lastFailure!.code.code,
            'detail': lastFailure!.detail,
            'windowsResultCode': lastFailure!.windowsResultCode,
            'occurredAtUtc': lastFailure!.occurredAtUtc
                ?.toUtc()
                .toIso8601String(),
            'attempt': lastFailure!.attempt,
          },
    'transactionId': transactionId,
    'baseline': baseline?.toJson(),
    'snapshotPath': snapshotPath,
    'healthDeadlineUtc': healthDeadlineUtc?.toUtc().toIso8601String(),
    'helperStartedUtc': helperStartedUtc?.toUtc().toIso8601String(),
    'updatedAtUtc': updatedAtUtc?.toUtc().toIso8601String(),
  };

  /// 解析状态文件；任何结构问题都返回 `null`（调用方据此重建，而不是按半份状态安装）。
  static UpdateState? tryParse(Object? json) {
    if (json is! Map) return null;
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != updateStateSchemaVersion) {
      return null;
    }
    final phase = UpdatePhase.fromWireName(json['phase'] as String?);
    if (phase == null) return null;
    final receivedBytes = json['receivedBytes'];
    final retryAttempt = json['retryAttempt'];
    final targetFailureCount = json['targetFailureCount'] is int
        ? json['targetFailureCount'] as int
        : 0;
    if (receivedBytes is! int ||
        receivedBytes < 0 ||
        retryAttempt is! int ||
        retryAttempt < 0) {
      return null;
    }
    final totalBytes = json['totalBytes'];
    if (totalBytes != null && totalBytes is! int) return null;
    final etag = json['etag'];
    final lastModified = json['lastModified'];
    if ((etag != null && etag is! String) ||
        (lastModified != null && lastModified is! String)) {
      return null;
    }
    final classification = json['lastCheckClassification'];
    UpdateCheckClassification? parsedClassification;
    if (classification is String) {
      for (final value in UpdateCheckClassification.values) {
        if (value.name == classification) parsedClassification = value;
      }
      if (parsedClassification == null) return null;
    } else if (classification != null) {
      return null;
    }
    final failureJson = json['lastFailure'];
    UpdateFailure? failure;
    if (failureJson is Map) {
      final code = UpdateFailureCode.fromCode(failureJson['code'] as String?);
      if (code == null) return null;
      failure = UpdateFailure(
        code,
        detail: failureJson['detail'] as String?,
        windowsResultCode: failureJson['windowsResultCode'] as int?,
        occurredAtUtc: _parseUtc(failureJson['occurredAtUtc']),
        attempt: failureJson['attempt'] is int
            ? failureJson['attempt'] as int
            : 0,
      );
    } else if (failureJson != null) {
      return null;
    }
    final baselineJson = json['baseline'];
    final baseline = baselineJson == null
        ? null
        : RollbackBaseline.tryParse(baselineJson);
    if (baselineJson != null && baseline == null) return null;
    final current = json['currentMsixVersion'];
    MsixVersion? currentVersion;
    if (current is String) {
      currentVersion = MsixVersion.tryParse(current);
      if (currentVersion == null) return null;
    } else if (current != null) {
      return null;
    }
    final targetJson = json['target'];
    final target = targetJson == null
        ? null
        : UpdateTarget.tryParse(targetJson);
    if (targetJson != null && target == null) return null;
    final transactionId = json['transactionId'];
    final snapshotPath = json['snapshotPath'];
    final manifestEtag = json['manifestEtag'];
    if ((transactionId != null && transactionId is! String) ||
        (snapshotPath != null && snapshotPath is! String) ||
        (manifestEtag != null && manifestEtag is! String)) {
      return null;
    }
    return UpdateState(
      schemaVersion: schemaVersion,
      phase: phase,
      currentMsixVersion: currentVersion,
      target: target,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes as int?,
      etag: etag as String?,
      lastModified: lastModified as String?,
      retryAttempt: retryAttempt,
      targetFailureCount: targetFailureCount,
      pausedTargetVersion: json['pausedTargetVersion'] is String
          ? json['pausedTargetVersion'] as String
          : null,
      nextAttemptUtc: _parseUtc(json['nextAttemptUtc']),
      lastCheckedUtc: _parseUtc(json['lastCheckedUtc']),
      lastConfirmedUtc: _parseUtc(json['lastConfirmedUtc']),
      manifestEtag: manifestEtag as String?,
      lastCheckClassification: parsedClassification,
      lastFailure: failure,
      transactionId: transactionId as String?,
      baseline: baseline,
      snapshotPath: snapshotPath as String?,
      healthDeadlineUtc: _parseUtc(json['healthDeadlineUtc']),
      helperStartedUtc: _parseUtc(json['helperStartedUtc']),
      updatedAtUtc: _parseUtc(json['updatedAtUtc']),
    );
  }
}

DateTime? _parseUtc(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// 一次状态推进的结果。非法跳转时 [state] 原样返回，[failure] 非空。
final class UpdateTransitionResult {
  const UpdateTransitionResult.accepted(this.state) : failure = null;

  const UpdateTransitionResult.rejected(this.state, this.failure);

  final UpdateState state;
  final UpdateFailure? failure;

  bool get acceptedTransition => failure == null;
}
