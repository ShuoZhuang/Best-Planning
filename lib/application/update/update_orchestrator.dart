// 更新编排器：唯一业务入口（规格 §5.1 / §7 / §9；1.11.1 修复 §5）。
//
// 它把"检查、下载、验证、就绪、安装"收敛成一条状态机，并保证四件事：
//   · **四类检查结论不被混淆**：只有验证通过的清单比较后才可能 `upToDate`；
//   · **目标单调**：只要本机还没装上更高版本，陈旧 latest 结果不得清空已下载的目标；
//   · **磁盘事实优先于易损状态**：启动时枚举受控目录里的 `.ready`，能证明身份就收养；
//   · **同一时间只有一个事务**：检查、下载、基线各有一份 single-flight。
//
// 它不直接接触 Windows API：包身份、签名验证与安装都由端口实现（`platform/update`）。
import 'dart:async';
import 'dart:io';

import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/rollback_baseline.dart';
import 'package:personal_planner/domain/update/update_baseline_status.dart';
import 'package:personal_planner/domain/update/update_check_result.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/atomic_file.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

/// 下载前/安装前的磁盘安全余量：至少 `max(500 MB, 安装包大小 × 2)`（规格 §8.5）。
int updateDiskSafetyMarginBytes(int packageBytes) {
  const fiveHundredMegabytes = 500 * 1024 * 1024;
  final doublePackage = packageBytes * 2;
  return fiveHundredMegabytes > doublePackage
      ? fiveHundredMegabytes
      : doublePackage;
}

/// 一次更新事务所需的可用空间估算：
/// 目标包 + 回退包 + 数据快照 + 安装展开空间 + 安全余量。
int estimatedUpdateSpaceRequirementBytes(int packageBytes) =>
    packageBytes * 4 + updateDiskSafetyMarginBytes(packageBytes);

/// 重试退避（规格 §8.4）：30s → 2min → 10min → 1h → 最多 6h，带抖动。
Duration updateRetryDelay(int attempt, {double jitter = 0.2}) {
  const schedule = [
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 10),
    Duration(hours: 1),
    Duration(hours: 6),
  ];
  final base = schedule[attempt.clamp(0, schedule.length - 1)];
  // 抖动只向下浮动：让"最多每 6 小时一次"保持上界。
  final factor = 1 - jitter / 2 + (jitter / 2) * ((attempt * 37 % 100) / 100);
  return Duration(milliseconds: (base.inMilliseconds * factor).round());
}

/// 基线任务独立的退避序列。**不能与目标下载共用计数**：两者失败的次数互不相干，
/// 共用会让"下载失败三次"顺带耗尽基线重试（UPD-INC-029 / §7）。
Duration updateBaselineRetryDelay(int attempt, {double jitter = 0.2}) {
  const schedule = [
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 10),
    Duration(hours: 1),
  ];
  final base = schedule[attempt.clamp(0, schedule.length - 1)];
  final factor = 1 - jitter / 2 + (jitter / 2) * ((attempt * 53 % 100) / 100);
  return Duration(milliseconds: (base.inMilliseconds * factor).round());
}

/// 一次 latest 检查与既有状态合并后的**纯**结论。
///
/// 它不写状态、不读文件，因此"陈旧 latest 不得降级"这类不变量可以被穷举测试。
final class UpdateDiscoveryDecision {
  const UpdateDiscoveryDecision({
    required this.classification,
    required this.phase,
    this.target,
    this.failure,
    this.staleLatestIgnored = false,
    this.targetRevoked = false,
    this.resetDownload = false,
  });

  final UpdateCheckClassification classification;

  /// 应用结论后应处于的阶段。**保留既有 target 时它就是原阶段**。
  final UpdatePhase phase;

  final UpdateTarget? target;
  final UpdateFailure? failure;

  /// incoming 比既有 target 旧（或与已安装版本相同）且被忽略。
  final bool staleLatestIgnored;

  /// 既有 target 被新鲜清单明确撤回。
  final bool targetRevoked;

  /// 目标变化，需要清空下载进度。
  final bool resetDownload;
}

/// 把一份已验证的 latest 清单合并到既有状态（INV-03 / INV-04 / INV-17 / INV-18）。
///
/// 决策顺序是固定的，任何"先清空再比较"的写法都会重演本次事故：
///   1. 来源身份必须是 `latestStable`；
///   2. 显式撤回**优先于**单调性；
///   3. 已安装版本已经达到/超过既有 target → 该 target 已完成，先清掉再比较；
///   4. incoming 比已安装版本旧 → 不允许降级；有更高 target 时只记"陈旧"；
///   5. incoming == installed → 没有更高 target 才是真正的 upToDate；
///   6. incoming > installed → 按"新建 / 升级 / 同版本刷新 / 陈旧保留"四种情况处理。
UpdateDiscoveryDecision reconcileDiscovery({
  required InstalledPackage installed,
  required UpdateState current,
  required VerifiedManifest incomingLatest,
}) {
  final manifest = incomingLatest.manifest;
  final incomingVersion = manifest.msixVersion;

  // 1. 只有 latestStable 的清单可以参与"最新版本"的结论。
  final key = incomingLatest.requestKey;
  if (key != null && !key.isLatestStable) {
    return const UpdateDiscoveryDecision(
      classification: UpdateCheckClassification.sourceInvalid,
      phase: UpdatePhase.failed,
      failure: UpdateFailure(UpdateFailureCode.manifestSourceNotAllowed),
    );
  }

  // 3. 已安装版本已经达到既有 target：该目标已完成，不再保留。
  final currentTarget = current.target;
  final activeTarget =
      currentTarget != null && installed.version >= currentTarget.msixVersion
      ? null
      : currentTarget;

  UpdateTarget buildTarget() => UpdateTarget(
    version: manifest.release.version,
    buildNumber: manifest.release.buildNumber,
    tag: manifest.tag,
    msixVersion: manifest.msixVersion,
    fileName: manifest.package.fileName,
    downloadUrl: manifest.package.downloadUrl,
    sizeBytes: manifest.package.sizeBytes,
    sha256: manifest.package.sha256,
    manifestDigest: incomingLatest.canonicalDigest,
    keyId: manifest.signature.keyId,
  );

  // 2. INV-04：新鲜清单明确撤回**已有 target** → 撤回优先，阻止安装。
  if (activeTarget != null &&
      manifest.revokedVersions.contains(activeTarget.msixVersion)) {
    return UpdateDiscoveryDecision(
      classification: UpdateCheckClassification.sourceInvalid,
      phase: UpdatePhase.failed,
      targetRevoked: true,
      failure: const UpdateFailure(UpdateFailureCode.packageVersionRevoked),
    );
  }

  // 发布方撤回了 latest 指向的版本本身：同样不能安装，也不能显示"已是最新"。
  if (manifest.isRevoked) {
    return const UpdateDiscoveryDecision(
      classification: UpdateCheckClassification.sourceInvalid,
      phase: UpdatePhase.failed,
      failure: UpdateFailure(UpdateFailureCode.packageVersionRevoked),
    );
  }

  UpdateDiscoveryDecision stale() => UpdateDiscoveryDecision(
    classification: UpdateCheckClassification.temporarilyUnconfirmed,
    phase: _retainedPhase(current.phase),
    target: activeTarget,
    staleLatestIgnored: true,
    failure: UpdateFailure(
      UpdateFailureCode.manifestStaleLatest,
      detail:
          'incoming=${incomingVersion.value} '
          'retained=${activeTarget!.msixVersion.value}',
    ),
  );

  // 4. 比已安装版本旧：不允许降级安装。
  if (incomingVersion < installed.version) {
    if (activeTarget != null) return stale();
    return UpdateDiscoveryDecision(
      classification: UpdateCheckClassification.sourceInvalid,
      phase: UpdatePhase.failed,
      failure: UpdateFailure(
        UpdateFailureCode.packageDowngradeBlocked,
        detail:
            'remote=${incomingVersion.value} '
            'installed=${installed.version.value}',
      ),
    );
  }

  // 5. incoming == installed。
  if (incomingVersion == installed.version) {
    if (activeTarget != null) return stale();
    return const UpdateDiscoveryDecision(
      classification: UpdateCheckClassification.upToDate,
      phase: UpdatePhase.upToDate,
    );
  }

  // 6. incoming > installed。
  final incomingTarget = buildTarget();
  if (activeTarget == null) {
    return UpdateDiscoveryDecision(
      classification: UpdateCheckClassification.updateAvailable,
      phase: UpdatePhase.updateAvailable,
      target: incomingTarget,
      resetDownload: true,
    );
  }
  if (incomingVersion > activeTarget.msixVersion) {
    return UpdateDiscoveryDecision(
      classification: UpdateCheckClassification.updateAvailable,
      phase: UpdatePhase.updateAvailable,
      target: incomingTarget,
      resetDownload: true,
    );
  }
  if (incomingVersion == activeTarget.msixVersion) {
    // 同一个目标：只刷新清单元数据，绝不清空下载/就绪状态（UPD-INC-004）。
    return UpdateDiscoveryDecision(
      classification: UpdateCheckClassification.updateAvailable,
      phase: _retainedPhase(current.phase),
      target: incomingTarget,
    );
  }
  return stale();
}

/// 保留既有 target 时应该停留在哪个阶段。
UpdatePhase _retainedPhase(UpdatePhase phase) => switch (phase) {
  UpdatePhase.ready ||
  UpdatePhase.downloading ||
  UpdatePhase.verifying ||
  UpdatePhase.downloadPaused ||
  UpdatePhase.updateAvailable ||
  UpdatePhase.temporarilyBlocked => phase,
  _ => UpdatePhase.updateAvailable,
};

final class UpdateOrchestrator {
  UpdateOrchestrator({
    required this.manifestSource,
    required this.stateStore,
    required this.installedPackages,
    required this.downloader,
    required this.verifier,
    required this.layout,
    required this.safety,
    required this.log,
    required this.clock,
    this.diskSpace,
    this.windowsBuild,
    this.helper,
    this.installCoordinator,
    this.baselineService,
    this.updateLock,
    this.processProbe,
  });

  final UpdateManifestSource manifestSource;
  final UpdateStateStore stateStore;
  final InstalledPackageProvider installedPackages;
  final UpdatePackageDownloader downloader;
  final UpdatePackageVerifier verifier;
  final UpdateStorageLayout layout;
  final UpdateSafetyCoordinator safety;
  final UpdateLogSink log;
  final Clock clock;
  final DiskSpaceProbe? diskSpace;

  /// 当前 Windows 构建；`null` 表示无法读取（跳过兼容性检查，但仍在诊断页显示未知）。
  final Future<MsixVersion?> Function()? windowsBuild;

  final UpdateHelper? helper;

  /// 安装准备（快照、一次性请求、助手握手、退出）。为空时点击就绪入口会明确报告"助手缺失"。
  final UpdateInstallCoordinator? installCoordinator;

  /// 回退基线任务的提供者。为空时不尝试建立基线（测试/未装配）。
  final UpdateBaselinePreparer? baselineService;

  /// 跨进程锁；为空时（测试）不做跨进程互斥。
  final UpdateLock? updateLock;

  /// 进程身份探测：记录锁持有者的 PID 与启动时间。
  final ProcessIdentityProbe? processProbe;

  final StreamController<UpdateState> _states =
      StreamController<UpdateState>.broadcast();

  UpdateState _state = const UpdateState();
  VerifiedManifest? _latestManifest;
  InstalledPackage? _installed;
  UpdateFailure? _disabledReason;
  String? _pendingHealthTransaction;
  MsixVersion? _pendingHealthVersion;

  Future<UpdateCheckResult>? _activeCheck;
  Future<void>? _activeDownload;
  Future<UpdateBaselineResult>? _baselineInFlight;
  bool _disposed = false;
  DateTime? _lastPersistedProgressUtc;
  int _lastPersistedBytes = -1;

  UpdateState get state => _state;

  /// 最近一次**验证通过**的清单。界面展示标题/摘要时用它；为 `null` 时只显示版本事实。
  VerifiedManifest? get latestManifest => _latestManifest;

  InstalledPackage? get installed => _installed;

  /// 基线准备状态：界面据此显示"正在准备安全更新/等待网络恢复/可重试"。
  BaselinePreparationState get baselineStatus => _state.baselinePreparation;

  /// 状态文件由更新版本客户端写入时，本次会话禁用更新（不覆盖、不降级解析）。
  UpdateFailure? get disabledReason => _disabledReason;

  bool get updatesDisabled => _disabledReason != null;

  /// 本次启动是否正是"助手装完新版后拉起来"的那一次；非空时组合根应写健康确认。
  String? get pendingHealthTransaction => _pendingHealthTransaction;

  MsixVersion? get pendingHealthVersion => _pendingHealthVersion;

  Stream<UpdateState> get states => _states.stream;

  /// 启动时恢复：状态文件只是线索，文件、已安装包与进程才是事实（规格 §9.4 / INV-05）。
  Future<void> initialize() async {
    _state = await stateStore.load();
    if (stateStore.sawFutureSchema) {
      _disabledReason = const UpdateFailure(
        UpdateFailureCode.stateSchemaUnsupported,
      );
      _state = _state.copyWith(
        phase: UpdatePhase.temporarilyBlocked,
        lastFailure: _disabledReason,
      );
      _emit();
      return;
    }
    _installed = await installedPackages.current();
    if (_installed != null) {
      _state = _state.copyWith(currentMsixVersion: _installed!.version);
    }
    if (_state.phase == UpdatePhase.checking) {
      _state = _state.copyWith(phase: UpdatePhase.idle);
    }
    if (_state.phase == UpdatePhase.rollingBack) {
      // 回退流程由助手负责；主程序重启后把状态交给恢复窗口，而不是假装继续。
      _state = _state.copyWith(phase: UpdatePhase.rolledBack);
    }
    if (_state.phase == UpdatePhase.rolledBack) {
      _state = _state.copyWith(
        phase: UpdatePhase.failed,
        pausedTargetVersion: _state.target?.msixVersion.value,
        lastFailure: const UpdateFailure(UpdateFailureCode.rollbackSucceeded),
        retryAttempt: 0,
        targetFailureCount: 0,
        nextAttemptUtc: null,
      );
    }
    if (_state.phase == UpdatePhase.installing ||
        _state.phase == UpdatePhase.launchingNewVersion ||
        _state.phase == UpdatePhase.waitingForHealth) {
      final target = _state.target;
      if (target != null && _installed?.version == target.msixVersion) {
        // 记下"这次启动是升级后的第一次启动"：组合根据此写健康确认，
        // 之后才允许把目标包晋升为新的回退基线（INV-09）。
        _pendingHealthTransaction = _state.transactionId;
        _pendingHealthVersion = target.msixVersion;
        _state = _state.copyWith(phase: UpdatePhase.succeeded);
      } else if (target != null) {
        _state = _state.copyWith(phase: UpdatePhase.ready);
      } else {
        _state = _state.copyWith(phase: UpdatePhase.idle);
      }
    }
    if (_state.phase == UpdatePhase.preparingInstall ||
        _state.phase == UpdatePhase.waitingForExit) {
      _state = _state.copyWith(phase: UpdatePhase.ready);
    }

    await _reconcileReadyPackages();
    await _reconcileBaselineState();

    _emit();
    await _persist();
  }

  /// 枚举受控版本目录里的 `.ready`，收养能证明身份的最高版本，隔离无法证明的（INV-05）。
  Future<void> _reconcileReadyPackages() async {
    final installed = _installed;
    if (installed == null) return;

    VerifiedManifest? manifest;
    try {
      manifest = await manifestSource.cachedLatest();
    } on Object {
      manifest = null;
    }
    if (manifest != null) _latestManifest = manifest;

    final adopted = <UpdateTarget>[];
    for (final directory in layout.versionDirectories()) {
      final version = MsixVersion.tryParse(
        directory.path.split(RegExp(r'[\\/]')).last,
      );
      if (version == null || version <= installed.version) continue;
      final ready = File(
        '${directory.path}${Platform.pathSeparator}package.msix.ready',
      );
      if (!ready.existsSync()) continue;

      final target = _targetFor(version, manifest);
      if (target == null) {
        if (manifest == null) {
          // 还没有任何已签名清单可用（例如首次以 1.11.1 启动、旧缓存已隔离）：
          // 保留文件，等下一次成功检查后再证明身份或隔离。直接隔离会让用户
          // 已经下载好的包被白扔掉（违反 INV-10）。
          log.writeLine('ready_pending_manifest version=${version.value}');
          continue;
        }
        await _quarantine(ready, 'unproven_identity');
        continue;
      }
      final revoked = manifest?.manifest.revokedVersions.contains(version);
      if (revoked == true) {
        await _quarantine(ready, 'revoked');
        continue;
      }
      // 长度是零成本的第一道检查：不匹配的文件连验签都不必做。
      if (ready.lengthSync() != target.sizeBytes) {
        await _quarantine(ready, 'length_mismatch');
        continue;
      }
      final verification = await verifier.verify(
        path: ready.path,
        target: target,
        installed: installed,
        verifyNativeSignature: helper != null,
      );
      if (!verification.ok) {
        await _quarantine(
          ready,
          verification.failure?.code.code ?? 'verification_failed',
        );
        continue;
      }
      adopted.add(target);
    }

    if (adopted.isNotEmpty) {
      // 多个可用版本只选最高者；其余保留给清理阶段（不删除已验证文件）。
      adopted.sort((a, b) => b.msixVersion.compareTo(a.msixVersion));
      final best = adopted.first;
      _state = _state.copyWith(
        phase: UpdatePhase.ready,
        target: best,
        receivedBytes: best.sizeBytes,
        totalBytes: best.sizeBytes,
        retryAttempt: 0,
        targetFailureCount: 0,
        nextAttemptUtc: null,
        lastFailure: null,
      );
      log.writeLine('ready_adopted version=${best.msixVersion.value}');
      return;
    }

    // 没有可收养的包时，核对状态指向的 target 是否还在。
    final target = _state.target;
    if (target == null) return;
    final ready = layout.readyPackage(target);
    if (_state.phase == UpdatePhase.ready && !ready.existsSync()) {
      _state = _state.copyWith(
        phase: UpdatePhase.failed,
        receivedBytes: 0,
        lastFailure: const UpdateFailure(
          UpdateFailureCode.packageFormatInvalid,
          detail: 'ready_missing',
        ),
      );
    }
  }

  UpdateTarget? _targetFor(MsixVersion version, VerifiedManifest? manifest) {
    final manifestVersion = manifest?.manifest.msixVersion;
    if (manifest != null && manifestVersion == version) {
      final m = manifest.manifest;
      return UpdateTarget(
        version: m.release.version,
        buildNumber: m.release.buildNumber,
        tag: m.tag,
        msixVersion: m.msixVersion,
        fileName: m.package.fileName,
        downloadUrl: m.package.downloadUrl,
        sizeBytes: m.package.sizeBytes,
        sha256: m.package.sha256,
        manifestDigest: manifest.canonicalDigest,
        keyId: m.signature.keyId,
      );
    }
    final stateTarget = _state.target;
    if (stateTarget != null && stateTarget.msixVersion == version) {
      return stateTarget;
    }
    return null;
  }

  /// 基线阶段收敛：已有基线必须通过严格校验才算 ready（INV-06 / UPD-INC-011）。
  Future<void> _reconcileBaselineState() async {
    final service = baselineService;
    final installed = _installed;
    if (service == null || installed == null) return;
    final baseline = _state.baseline;
    final preparation = _state.baselinePreparation;
    final targetReady = _state.phase == UpdatePhase.ready;

    if (baseline == null || baseline.version != installed.version) {
      _state = _state.copyWith(
        baseline: null,
        baselinePreparation: BaselinePreparationState(
          phase: BaselinePhase.absent,
          requiredForInstalledVersion: installed.version,
        ),
      );
      safety.setRollbackNotReady(targetReady);
      return;
    }

    final validation = await service.validate(
      installed: installed,
      baseline: baseline,
    );
    if (validation.usable) {
      _state = _state.copyWith(
        baselinePreparation: BaselinePreparationState(
          phase: BaselinePhase.ready,
          requiredForInstalledVersion: installed.version,
        ),
      );
      safety.setRollbackNotReady(false);
      return;
    }

    _state = _state.copyWith(
      baseline: null,
      baselinePreparation: BaselinePreparationState(
        phase: preparation.phase == BaselinePhase.failed
            ? BaselinePhase.failed
            : BaselinePhase.absent,
        requiredForInstalledVersion: installed.version,
        attempt: preparation.attempt,
        lastFailure: validation.failure,
      ),
    );
    safety.setRollbackNotReady(targetReady);
  }

  /// 检查更新。多次触发合并为一次（规格 §7.1）。
  Future<UpdateCheckResult> check({
    required bool manual,
    bool autoDownload = true,
  }) {
    if (_disposed) {
      return Future.value(
        UpdateCheckResult(
          classification: UpdateCheckClassification.temporarilyUnconfirmed,
          state: _state,
          failure: const UpdateFailure(UpdateFailureCode.internalError),
        ),
      );
    }
    final running = _activeCheck;
    if (running != null) return running;
    final future = _runCheck(manual: manual, autoDownload: autoDownload);
    _activeCheck = future;
    return future.whenComplete(() {
      if (identical(_activeCheck, future)) _activeCheck = null;
    });
  }

  Future<UpdateCheckResult> _runCheck({
    required bool manual,
    required bool autoDownload,
  }) async {
    final installed = await installedPackages.current();
    _installed = installed;

    final disabled = _disabledReason;
    if (disabled != null) {
      return _resultFromFailure(disabled.code, installed: installed);
    }

    if (installed == null || !installed.isPackaged) {
      return _resultFromFailure(
        UpdateFailureCode.environmentNotPackaged,
        installed: installed,
      );
    }
    if (!installed.matchesClientIdentity) {
      return _resultFromFailure(
        _mismatchToCode(installed.mismatches),
        installed: installed,
      );
    }

    // 正在进行的事务优先：不打断、不并发。返回当前状态对应的结论。
    if (_state.isBusy &&
        _state.phase != UpdatePhase.checking &&
        _state.phase != UpdatePhase.failed) {
      return _currentResult(installed);
    }

    final startState = _state;
    _state = _state.copyWith(
      currentMsixVersion: installed.version,
      lastCheckedUtc: clock.nowUtc(),
      lastFailure: null,
    );
    if (!await _go(UpdatePhase.checking)) {
      return _currentResult(installed);
    }

    // 请求身份由仓库自己持有；这里不再传 ETag（INV-02）。
    final fetch = await manifestSource.fetchLatest();
    final failure = fetch.failure;
    if (failure != null) {
      return _handleCheckFailure(failure, installed);
    }

    final verified = fetch.verified!;
    _latestManifest = verified;

    final compatibilityFailure = _compatibilityFailure(verified.manifest);
    if (compatibilityFailure != null) {
      return _handleCheckFailure(compatibilityFailure, installed);
    }

    final windows = await windowsBuild?.call();
    if (windows != null &&
        windows < verified.manifest.compatibility.minimumWindowsBuild) {
      return _handleCheckFailure(
        UpdateFailure(
          UpdateFailureCode.packageOsUnsupported,
          detail:
              'windows=${windows.value} '
              'required=${verified.manifest.compatibility.minimumWindowsBuild.value}',
        ),
        installed,
      );
    }

    final pausedTarget = startState.pausedTargetVersion;
    if (pausedTarget != null &&
        pausedTarget == verified.manifest.msixVersion.value) {
      return _handleCheckFailure(
        const UpdateFailure(UpdateFailureCode.installTargetPaused),
        installed,
      );
    }

    final decision = reconcileDiscovery(
      installed: installed,
      current: startState,
      incomingLatest: verified,
    );
    final now = clock.nowUtc();

    if (decision.classification == UpdateCheckClassification.sourceInvalid) {
      if (decision.targetRevoked) {
        // INV-04：撤回的包移到隔离位置，绝不再执行。
        final revokedTarget = startState.target ?? _state.target;
        if (revokedTarget != null) {
          await _quarantine(layout.readyPackage(revokedTarget), 'revoked');
        }
        _state = _state.copyWith(
          target: null,
          receivedBytes: 0,
          totalBytes: null,
          etag: null,
          lastModified: null,
        );
      }
      return _handleCheckFailure(
        decision.failure ??
            const UpdateFailure(UpdateFailureCode.manifestInvalidJson),
        installed,
      );
    }

    if (decision.classification == UpdateCheckClassification.upToDate) {
      await _go(UpdatePhase.upToDate);
      _state = _state.copyWith(
        target: null,
        receivedBytes: 0,
        totalBytes: null,
        etag: null,
        lastModified: null,
        retryAttempt: 0,
        nextAttemptUtc: null,
        lastConfirmedUtc: now,
        lastCheckClassification: UpdateCheckClassification.upToDate,
        lastFailure: null,
      );
      await _persist();
      _emit();
      return UpdateCheckResult(
        classification: UpdateCheckClassification.upToDate,
        state: _state,
        manifest: verified,
        installed: installed,
      );
    }

    if (decision.classification ==
        UpdateCheckClassification.temporarilyUnconfirmed) {
      // 陈旧 latest：保留既有 target 与下载进度，只记录"本轮无法重新确认"。
      _state = _state.copyWith(
        phase: decision.phase,
        target: decision.target,
        lastConfirmedUtc: now,
        lastCheckClassification:
            UpdateCheckClassification.temporarilyUnconfirmed,
        lastFailure: decision.failure,
      );
      final retained = decision.target?.msixVersion.value;
      log.writeLine(
        'stale_latest_ignored incoming='
        '${verified.manifest.msixVersion.value} retained=${retained ?? 'none'}',
      );
      if (decision.failure != null) log.write(decision.failure!);
      await _persist();
      _emit();
      return UpdateCheckResult(
        classification: UpdateCheckClassification.temporarilyUnconfirmed,
        state: _state,
        manifest: verified,
        failure: decision.failure,
        installed: installed,
      );
    }

    // updateAvailable
    final target = decision.target!;
    final reset = decision.resetDownload;
    _state = _state.copyWith(
      phase: decision.phase,
      target: target,
      receivedBytes: reset ? 0 : _state.receivedBytes,
      totalBytes: target.sizeBytes,
      etag: reset ? null : _state.etag,
      lastModified: reset ? null : _state.lastModified,
      retryAttempt: reset ? 0 : _state.retryAttempt,
      targetFailureCount: reset ? 0 : _state.targetFailureCount,
      pausedTargetVersion: reset ? null : _state.pausedTargetVersion,
      nextAttemptUtc: reset ? null : _state.nextAttemptUtc,
      lastConfirmedUtc: now,
      lastCheckClassification: UpdateCheckClassification.updateAvailable,
      lastFailure: null,
    );
    await _persist();
    _emit();

    if (autoDownload && _state.phase == UpdatePhase.updateAvailable) {
      // 自动下载失败不改变"发现更新"这个结论；状态会落到 failed/downloadPaused。
      await startDownload();
      return UpdateCheckResult(
        classification: _state.phase == UpdatePhase.failed
            ? UpdateCheckClassification.temporarilyUnconfirmed
            : UpdateCheckClassification.updateAvailable,
        state: _state,
        manifest: verified,
        failure: _state.phase == UpdatePhase.failed ? _state.lastFailure : null,
        installed: installed,
      );
    }

    return UpdateCheckResult(
      classification: UpdateCheckClassification.updateAvailable,
      state: _state,
      manifest: verified,
      installed: installed,
    );
  }

  Future<UpdateCheckResult> _handleCheckFailure(
    UpdateFailure failure,
    InstalledPackage installed,
  ) async {
    final classification = classificationFor(failure.code);
    final phase = failure.retryable
        ? UpdatePhase.temporarilyBlocked
        : UpdatePhase.failed;
    if (!await _go(phase)) {
      return _currentResult(installed);
    }
    _state = _state.copyWith(
      lastFailure: UpdateFailure(
        failure.code,
        detail: failure.detail,
        windowsResultCode: failure.windowsResultCode,
        occurredAtUtc: clock.nowUtc(),
      ),
      lastCheckClassification: classification,
      lastCheckedUtc: clock.nowUtc(),
    );
    log.write(_state.lastFailure!);
    await _persist();
    _emit();
    return UpdateCheckResult(
      classification: classification,
      state: _state,
      failure: failure,
      installed: installed,
    );
  }

  UpdateCheckResult _resultFromFailure(
    UpdateFailureCode code, {
    InstalledPackage? installed,
  }) {
    final failure = UpdateFailure(code, occurredAtUtc: clock.nowUtc());
    log.write(failure);
    return UpdateCheckResult(
      classification: classificationFor(code),
      state: _state,
      failure: failure,
      installed: installed,
    );
  }

  UpdateCheckResult _currentResult(InstalledPackage? installed) {
    final classification = switch (_state.phase) {
      UpdatePhase.upToDate => UpdateCheckClassification.upToDate,
      UpdatePhase.updateAvailable ||
      UpdatePhase.downloading ||
      UpdatePhase.downloadPaused ||
      UpdatePhase.verifying ||
      UpdatePhase.ready => UpdateCheckClassification.updateAvailable,
      UpdatePhase.temporarilyBlocked =>
        UpdateCheckClassification.temporarilyUnconfirmed,
      _ => UpdateCheckClassification.sourceInvalid,
    };
    return UpdateCheckResult(
      classification: classification,
      state: _state,
      manifest: _latestManifest,
      failure: _state.lastFailure,
      installed: installed,
    );
  }

  UpdateFailure? _compatibilityFailure(UpdateManifest manifest) {
    final mismatches = manifest.compatibility.mismatches;
    if (mismatches.isEmpty) return null;
    final code = switch (mismatches.first) {
      CompatibilityMismatch.identityName || CompatibilityMismatch.publisher =>
        UpdateFailureCode.packagePublisherMismatch,
      CompatibilityMismatch.familyName =>
        UpdateFailureCode.packageFamilyMismatch,
      CompatibilityMismatch.architecture =>
        UpdateFailureCode.packageArchMismatch,
    };
    return UpdateFailure(
      code,
      detail: mismatches.map((mismatch) => mismatch.name).join(','),
    );
  }

  UpdateFailureCode _mismatchToCode(Set<PackageIdentityMismatch> mismatches) {
    if (mismatches.contains(PackageIdentityMismatch.publisher)) {
      return UpdateFailureCode.packagePublisherMismatch;
    }
    if (mismatches.contains(PackageIdentityMismatch.identityName)) {
      return UpdateFailureCode.packageIdentityMismatch;
    }
    if (mismatches.contains(PackageIdentityMismatch.familyName)) {
      return UpdateFailureCode.packageFamilyMismatch;
    }
    return UpdateFailureCode.packageArchMismatch;
  }

  /// 开始（或继续）下载。重复调用返回同一个 Future（规格 §15.2）。
  Future<void> startDownload() {
    final running = _activeDownload;
    if (running != null) return running;
    final future = _runDownload();
    _activeDownload = future;
    return future.whenComplete(() {
      if (identical(_activeDownload, future)) _activeDownload = null;
    });
  }

  Future<void> _runDownload() async {
    final target = _state.target;
    if (target == null) return;

    final installed = _installed ?? await installedPackages.current();
    if (installed == null) {
      await _failDownload(
        const UpdateFailure(UpdateFailureCode.environmentNotPackaged),
        target: target,
      );
      return;
    }
    _installed = installed;

    if (_state.phase == UpdatePhase.ready) {
      await _reverifyReadyPackage(target);
      return;
    }

    final allowed =
        _state.phase == UpdatePhase.updateAvailable ||
        _state.phase == UpdatePhase.downloadPaused ||
        _state.phase == UpdatePhase.failed ||
        _state.phase == UpdatePhase.temporarilyBlocked;
    if (!allowed) return;

    // INV-10：磁盘上已有完整且校验通过的 `.ready` 时直接复用，绝不从 0 重下。
    if (await _tryReuseReady(target, installed)) return;

    // 磁盘检查（规格 §8.5）：空间不足不删除任何已下载内容。
    final probe = diskSpace;
    if (probe != null) {
      final available = await probe.availableBytes(layout.root.path);
      final required = estimatedUpdateSpaceRequirementBytes(target.sizeBytes);
      if (available != null && available < required) {
        safety.setDiskSpaceLow(true);
        if (await _go(UpdatePhase.temporarilyBlocked)) {
          _state = _state.copyWith(
            lastFailure: UpdateFailure(
              UpdateFailureCode.blockedDiskSpaceLow,
              detail: 'available=$available required=$required',
              occurredAtUtc: clock.nowUtc(),
            ),
          );
          await _persist();
          _emit();
        }
        return;
      }
      safety.setDiskSpaceLow(false);
    }

    // 同一个时间只能有一个更新事务（规格 §15.1）。
    if (!await _acquireUpdateLock('download', target.msixVersion.value)) {
      if (await _go(UpdatePhase.temporarilyBlocked)) {
        _state = _state.copyWith(
          lastFailure: const UpdateFailure(
            UpdateFailureCode.blockedInstallerBusy,
          ),
        );
        await _persist();
        _emit();
      }
      return;
    }

    try {
      if (!await _go(UpdatePhase.downloading)) return;
      _state = _state.copyWith(
        receivedBytes: 0,
        totalBytes: target.sizeBytes,
        lastFailure: null,
      );
      await _persist();
      _emit();

      final partialPath = layout.partialPackage(target).path;
      final readyPath = layout.readyPackage(target).path;
      _lastPersistedBytes = -1;
      _lastPersistedProgressUtc = null;

      final outcome = await downloader.download(
        target: target,
        partialPath: partialPath,
        readyPath: readyPath,
        etag: _state.etag,
        lastModified: _state.lastModified,
        shouldCancel: () =>
            _disposed || _state.target?.msixVersion != target.msixVersion,
        onProgress: (received, total) {
          _onProgress(received, total);
        },
      );

      if (outcome.cancelled) return;

      if (!outcome.isSuccess) {
        final failure =
            outcome.failure ??
            const UpdateFailure(UpdateFailureCode.internalError);
        await _failDownload(failure, target: target);
        return;
      }

      _state = _state.copyWith(
        receivedBytes: outcome.sizeBytes,
        totalBytes: target.sizeBytes,
        etag: outcome.etag,
        lastModified: outcome.lastModified,
        lastFailure: null,
      );
      await _go(UpdatePhase.verifying);
      await _persist();
      _emit();

      final verification = await verifier.verify(
        path: outcome.path!,
        target: target,
        installed: installed,
        // 只有在生产装配了助手时才要求原生签名验证；测试与未打包开发环境没有助手，
        // 结构/哈希/身份三层仍然照常验证。
        verifyNativeSignature: helper != null,
      );

      if (!verification.ok) {
        final failure =
            verification.failure ??
            const UpdateFailure(UpdateFailureCode.packageFormatInvalid);
        await _discardReadyPackage(target);
        await _failDownload(failure, target: target);
        return;
      }

      await _go(UpdatePhase.ready);
      _state = _state.copyWith(
        receivedBytes: target.sizeBytes,
        totalBytes: target.sizeBytes,
        lastFailure: null,
        retryAttempt: 0,
        targetFailureCount: 0,
        pausedTargetVersion: null,
        nextAttemptUtc: null,
      );
      log.writeLine(
        'ready target=${target.msixVersion.value} '
        'sha256Prefix=${target.sha256.substring(0, 8)}',
      );
      await _persist();
      _emit();
    } finally {
      await _releaseUpdateLock();
    }
  }

  /// 复用磁盘上已存在的 `.ready`（INV-10）。验证失败的文件改名隔离，不静默删除。
  ///
  /// 存在性与长度用**同步**元数据调用：这是本地两次 `stat`，而异步文件 IO 会让
  /// widget 测试的假时钟永远等不到回调（同一段代码在真实运行时两者没有差别）。
  Future<bool> _tryReuseReady(
    UpdateTarget target,
    InstalledPackage installed,
  ) async {
    try {
      final ready = layout.readyPackage(target);
      if (!ready.existsSync()) return false;
      if (ready.lengthSync() != target.sizeBytes) return false;
      final verification = await verifier.verify(
        path: ready.path,
        target: target,
        installed: installed,
        verifyNativeSignature: helper != null,
      );
      if (!verification.ok) {
        await _quarantine(
          ready,
          verification.failure?.code.code ?? 'reuse_failed',
        );
        return false;
      }
      _state = _state.copyWith(
        phase: UpdatePhase.ready,
        receivedBytes: target.sizeBytes,
        totalBytes: target.sizeBytes,
        lastFailure: null,
        retryAttempt: 0,
        targetFailureCount: 0,
        nextAttemptUtc: null,
      );
      log.writeLine('ready_reused version=${target.msixVersion.value}');
      await _persist();
      _emit();
      return true;
    } on Object {
      return false;
    }
  }

  /// `ready` 状态的包在崩溃/重启后必须再次验证（规格 §9.5）。
  Future<void> _reverifyReadyPackage(UpdateTarget target) async {
    final installed = _installed;
    if (installed == null) return;
    final ready = layout.readyPackage(target);
    if (!ready.existsSync()) {
      await _go(UpdatePhase.failed);
      _state = _state.copyWith(
        lastFailure: const UpdateFailure(
          UpdateFailureCode.packageFormatInvalid,
        ),
      );
      await _persist();
      _emit();
      return;
    }
    final verification = await verifier.verify(
      path: ready.path,
      target: target,
      installed: installed,
      verifyNativeSignature: helper != null,
    );
    if (!verification.ok) {
      await _discardReadyPackage(target);
      await _failDownload(
        verification.failure ??
            const UpdateFailure(UpdateFailureCode.packageFormatInvalid),
        target: target,
      );
    }
  }

  void _onProgress(int received, int? total) {
    _state = _state.copyWith(
      receivedBytes: received,
      totalBytes: total ?? _state.totalBytes,
    );
    _emit();
    // 进度变化很频繁；状态文件只在跨过 1 MB 或 2 秒时落盘。
    final now = clock.nowUtc();
    final last = _lastPersistedProgressUtc;
    if (_lastPersistedBytes < 0 ||
        (received - _lastPersistedBytes).abs() >= 1024 * 1024 ||
        last == null ||
        now.difference(last) >= const Duration(seconds: 2)) {
      _lastPersistedProgressUtc = now;
      _lastPersistedBytes = received;
      unawaited(_persist());
    }
  }

  Future<void> _failDownload(
    UpdateFailure failure, {
    required UpdateTarget target,
  }) async {
    final attempt = _state.retryAttempt + 1;
    final targetFailureCount = _state.targetFailureCount + 1;
    final exhausted = targetFailureCount >= 3;
    final effectiveCode = exhausted && failure.retryable
        ? UpdateFailureCode.downloadRetryExhausted
        : failure.code;
    final next = clock.nowUtc().add(updateRetryDelay(attempt));
    if (!await _go(UpdatePhase.failed)) {
      // 从 verifying 等阶段进入 failed 是允许的；若不允许，保持原状态并只记录。
      _state = _state.copyWith(lastFailure: failure);
      log.write(failure);
      await _persist();
      _emit();
      return;
    }
    _state = _state.copyWith(
      lastFailure: UpdateFailure(
        effectiveCode,
        detail: failure.detail,
        windowsResultCode: failure.windowsResultCode,
        occurredAtUtc: clock.nowUtc(),
        attempt: attempt,
      ),
      retryAttempt: attempt,
      targetFailureCount: targetFailureCount,
      nextAttemptUtc: failure.retryable && !exhausted ? next : null,
    );
    log.write(failure);
    await _persist();
    _emit();
  }

  Future<void> _discardReadyPackage(UpdateTarget target) async {
    try {
      final ready = layout.readyPackage(target);
      if (ready.existsSync()) ready.deleteSync();
    } on Object {
      // 删不掉时保留文件；下一次验证仍会失败，不会误装。
    }
  }

  /// 把一个无法证明身份/已撤回的包改名隔离：不执行，也不静默删除（INV-05）。
  Future<void> _quarantine(File file, String reason) async {
    try {
      if (!file.existsSync()) return;
      final target = layout.quarantined(file);
      if (target.existsSync()) target.deleteSync();
      file.renameSync(target.path);
      log.writeLine('package_quarantined reason=$reason');
    } on Object {
      log.writeLine('package_quarantine_failed reason=$reason');
    }
  }

  Future<bool> _acquireUpdateLock(
    String operation,
    String targetVersion,
  ) async {
    final lock = updateLock;
    final probe = processProbe;
    if (lock == null || probe == null) return true;
    try {
      final process = await probe.current();
      return await lock.acquire(
        transactionId: '-',
        pid: process.pid,
        processStartedAtUtc: process.startedAtUtc,
        token: _lockToken(),
        operation: operation,
        targetVersion: targetVersion,
      );
    } on Object {
      return false;
    }
  }

  Future<void> _releaseUpdateLock() async {
    try {
      await updateLock?.release();
    } on Object {
      // 释放失败由 OS 在进程退出时兜底。
    }
  }

  static String _lockToken() {
    final seed = DateTime.now().microsecondsSinceEpoch;
    return List<String>.generate(32, (index) {
      final value = (seed * (index + 31) + index * 7919) & 0xFF;
      return value.toRadixString(16).padLeft(2, '0');
    }).join();
  }

  /// 后台建立回退基线（规格 §13.3 / INV-07）。
  ///
  /// 启动、自动开关、手动检查、手动下载与点击安装都可能同时调用；**进程内最多只有一个
  /// 真实基线任务**，所有调用方 await 同一个 Future。用户显式重试可以跳过尚未到期的退避，
  /// 但仍然只是加入同一个任务。
  Future<UpdateBaselineResult> ensureRollbackBaseline({
    bool userInitiated = false,
  }) {
    final pending = _baselineInFlight;
    if (pending != null) return pending;
    late final Future<UpdateBaselineResult> future;
    future = _runEnsureBaseline(userInitiated: userInitiated).whenComplete(() {
      if (identical(_baselineInFlight, future)) _baselineInFlight = null;
    });
    _baselineInFlight = future;
    return future;
  }

  Future<UpdateBaselineResult> _runEnsureBaseline({
    required bool userInitiated,
  }) async {
    final service = baselineService;
    if (service == null) {
      return const UpdateBaselineResult(
        failure: UpdateFailure(UpdateFailureCode.blockedRollbackNotReady),
      );
    }
    final installed = _installed ?? await installedPackages.current();
    _installed = installed;
    if (installed == null) {
      return const UpdateBaselineResult(
        failure: UpdateFailure(UpdateFailureCode.environmentNotPackaged),
      );
    }
    final preparation = _state.baselinePreparation;

    // 已有基线：严格复核（INV-06），通过即清掉残留 blocker（UPD-INC-013）。
    final existing = _state.baseline;
    if (existing != null && existing.version == installed.version) {
      final validation = await service.validate(
        installed: installed,
        baseline: existing,
      );
      if (validation.usable) {
        await _markBaselineReady(existing, installed);
        return UpdateBaselineResult(baseline: existing);
      }
    }

    // 退避门：自动触发遵守 nextAttemptUtc；用户显式重试忽略它。
    final next = preparation.nextAttemptUtc;
    if (!userInitiated &&
        preparation.phase == BaselinePhase.retryWaiting &&
        next != null &&
        clock.nowUtc().isBefore(next)) {
      return UpdateBaselineResult(
        failure:
            preparation.lastFailure ??
            const UpdateFailure(UpdateFailureCode.blockedRollbackNotReady),
      );
    }

    final attempt = preparation.phase == BaselinePhase.preparing
        ? preparation.attempt
        : preparation.attempt + 1;
    _state = _state.copyWith(
      baselinePreparation: BaselinePreparationState(
        phase: BaselinePhase.preparing,
        requiredForInstalledVersion: installed.version,
        attempt: attempt,
      ),
    );
    safety.setRollbackNotReady(true);
    _emit();
    await _persist();
    log.writeLine(
      'baseline_prepare_started version=${installed.version.value} '
      'attempt=$attempt',
    );

    UpdateBaselineResult result;
    try {
      result = await service.ensureBaseline(
        installed: installed,
        state: _state,
      );
    } on Object {
      result = const UpdateBaselineResult(
        failure: UpdateFailure(UpdateFailureCode.internalError),
      );
    }

    final baseline = result.baseline;
    if (baseline != null) {
      final validation = await service.validate(
        installed: installed,
        baseline: baseline,
      );
      if (validation.usable) {
        await _markBaselineReady(baseline, installed);
        return UpdateBaselineResult(baseline: baseline);
      }
      result = UpdateBaselineResult(failure: validation.failure);
    }

    final failure =
        result.failure ??
        const UpdateFailure(UpdateFailureCode.blockedRollbackNotReady);
    final retryable = failure.retryable;
    final retryAt = retryable
        ? clock.nowUtc().add(updateBaselineRetryDelay(attempt))
        : null;
    _state = _state.copyWith(
      baselinePreparation: BaselinePreparationState(
        phase: retryable ? BaselinePhase.retryWaiting : BaselinePhase.failed,
        requiredForInstalledVersion: installed.version,
        attempt: attempt,
        nextAttemptUtc: retryAt,
        lastFailure: failure,
      ),
    );
    safety.setRollbackNotReady(true);
    log.writeLine(
      'baseline_prepare_failed code=${failure.code.code} attempt=$attempt '
      'retryAt=${retryAt?.toUtc().toIso8601String() ?? 'none'}',
    );
    log.write(failure);
    await _persist();
    _emit();
    return UpdateBaselineResult(failure: failure);
  }

  Future<void> _markBaselineReady(
    RollbackBaseline baseline,
    InstalledPackage installed,
  ) async {
    _state = _state.copyWith(
      baseline: baseline,
      baselinePreparation: BaselinePreparationState(
        phase: BaselinePhase.ready,
        requiredForInstalledVersion: installed.version,
      ),
    );
    if (_state.lastFailure?.code == UpdateFailureCode.blockedRollbackNotReady) {
      _state = _state.copyWith(lastFailure: null);
    }
    safety.setRollbackNotReady(false);
    log.writeLine(
      'baseline_ready version=${baseline.version.value} '
      'sha256Prefix=${baseline.sha256.substring(0, 8)}',
    );
    await _persist();
    _emit();
  }

  /// 健康确认成功后把本次目标包晋升为"下一次更新所需的当前基线"（INV-09 / §8）。
  ///
  /// 顺序保证：先复制到临时文件 → 原子改名 → **再**校验；任何一步失败都保留旧基线指针
  /// 与旧基线包，不会出现"先删旧包再写新指针"的窗口。
  Future<void> confirmHealthPromotion({InstalledPackage? installed}) async {
    final service = baselineService;
    if (service == null) return;
    final current =
        installed ?? _installed ?? await installedPackages.current();
    _installed = current;
    if (current == null) return;
    final target = _state.target;
    if (target == null || current.version != target.msixVersion) return;

    final ready = layout.readyPackage(target);
    final baselineFile = layout.baselinePackage(current.version);
    final temp = File('${baselineFile.path}.promoting');
    try {
      // 晋升的唯一前置条件是**健康确认已写入且与本事务匹配**：没有它就不是"成功升级"。
      final confirmation = await readJsonOrNull(
        layout.healthConfirmationFile(current.version),
      );
      if (confirmation is! Map || confirmation['ok'] != true) {
        log.writeLine('baseline_promotion_waiting_health');
        return;
      }
      if (confirmation['version'] != current.version.value) {
        log.writeLine('baseline_promotion_failed code=health_version_mismatch');
        return;
      }
      final transactionId = _state.transactionId;
      if (transactionId != null &&
          confirmation['transactionId'] != transactionId) {
        log.writeLine(
          'baseline_promotion_failed code=health_transaction_mismatch',
        );
        return;
      }
      if (!await ready.exists()) {
        log.writeLine('baseline_promotion_failed code=ready_missing');
        return;
      }
      await baselineFile.parent.create(recursive: true);
      if (await temp.exists()) await temp.delete();
      await ready.copy(temp.path);
      if (await baselineFile.exists()) await baselineFile.delete();
      await temp.rename(baselineFile.path);

      final promoted = RollbackBaseline(
        version: current.version,
        packagePath: baselineFile.path,
        sha256: target.sha256,
        sizeBytes: target.sizeBytes,
        createdAtUtc: clock.nowUtc(),
      );
      final validation = await service.validate(
        installed: current,
        baseline: promoted,
      );
      if (!validation.usable) {
        // 晋升失败：删掉这份新文件，旧基线（上一版本）保持可用。
        try {
          await baselineFile.delete();
        } on Object {
          // 删除失败下一次校验仍会拒绝它。
        }
        log.writeLine(
          'baseline_promotion_failed '
          'code=${validation.failure?.code.code ?? 'invalid'}',
        );
        return;
      }

      _state = _state.copyWith(
        phase: UpdatePhase.succeeded,
        baseline: promoted,
        baselinePreparation: BaselinePreparationState(
          phase: BaselinePhase.ready,
          requiredForInstalledVersion: current.version,
        ),
        target: null,
        receivedBytes: 0,
        totalBytes: null,
        etag: null,
        lastModified: null,
        retryAttempt: 0,
        targetFailureCount: 0,
        pausedTargetVersion: null,
        nextAttemptUtc: null,
        lastFailure: null,
      );
      safety.setRollbackNotReady(false);
      log.writeLine('baseline_promoted version=${current.version.value}');
      await _persist();
      _emit();
    } on Object {
      log.writeLine('baseline_promotion_failed code=io_error');
    }
  }

  /// 用户点击就绪入口后的安装请求（规格 §12.3 的前半段在这里）。
  ///
  /// 基线未就绪时**不是简单报错**：立即触发/加入同一个基线任务，成功后继续安装，
  /// 失败则停留在 ready 并等待重试（触发矩阵「点击安装」一行）。
  Future<void> install() async {
    if (_state.phase != UpdatePhase.ready) return;
    final target = _state.target;
    final installed = _installed;
    if (target == null) return;
    if (installed == null) {
      await _failDownload(
        const UpdateFailure(UpdateFailureCode.environmentNotPackaged),
        target: target,
      );
      return;
    }

    // 基线以外的阻塞仍然直接拒绝（未保存编辑、导入、备份……）。
    final otherBlockers = safety.status.blockers.where(
      (blocker) => blocker != UpdateBlocker.rollbackNotReady,
    );
    if (otherBlockers.isNotEmpty) {
      final failure = safety.status.failure;
      _state = _state.copyWith(lastFailure: failure);
      if (failure != null) log.write(failure);
      _emit();
      await _persist();
      return;
    }

    if (baselineService != null) {
      final result = await ensureRollbackBaseline(userInitiated: true);
      if (result.baseline == null) {
        final failure = const UpdateFailure(
          UpdateFailureCode.blockedRollbackNotReady,
        );
        safety.setRollbackNotReady(true);
        _state = _state.copyWith(lastFailure: failure);
        log.write(failure);
        await _persist();
        _emit();
        return;
      }
    }

    final coordinator = installCoordinator;
    if (coordinator == null) {
      await _failDownload(
        const UpdateFailure(UpdateFailureCode.helperMissing),
        target: target,
      );
      return;
    }

    if (!await _acquireUpdateLock('install', target.msixVersion.value)) {
      final failure = const UpdateFailure(
        UpdateFailureCode.blockedInstallerBusy,
      );
      _state = _state.copyWith(lastFailure: failure);
      log.write(failure);
      await _persist();
      _emit();
      return;
    }

    if (!await _go(UpdatePhase.preparingInstall)) {
      await _releaseUpdateLock();
      return;
    }
    await _persist();
    _emit();

    // 第二次检查：从进入安装到真正启动助手之间，用户可能刚好开始了一个计划应用/
    // 导入/备份。只检查一次会留下"检查通过后事务才开始"的竞态，因此这里必须再读一次。
    final preLaunchSafety = safety.status;
    if (!preLaunchSafety.canInstall) {
      await _releaseUpdateLock();
      await _go(UpdatePhase.ready);
      final blockedFailure = preLaunchSafety.failure;
      _state = _state.copyWith(lastFailure: blockedFailure);
      if (blockedFailure != null) log.write(blockedFailure);
      await _persist();
      _emit();
      return;
    }

    final outcome = await coordinator.prepareAndLaunch(
      target: target,
      state: _state,
      installed: installed,
    );
    final failure = outcome.failure;
    if (!outcome.launched || failure != null) {
      await _releaseUpdateLock();
      // 助手没有确认之前不得退出：退回到就绪，保留包，等待用户重试。
      await _go(UpdatePhase.ready);
      _state = _state.copyWith(
        lastFailure:
            failure ??
            const UpdateFailure(UpdateFailureCode.helperLaunchFailed),
        transactionId: null,
      );
      log.write(_state.lastFailure!);
      await _persist();
      _emit();
      return;
    }

    _state = _state.copyWith(
      transactionId: outcome.transactionId,
      snapshotPath: outcome.snapshotPath,
      helperStartedUtc: clock.nowUtc(),
      lastFailure: null,
    );
    await _go(UpdatePhase.waitingForExit);
    await _persist();
    _emit();
    // 助手已取得请求；只有到这一步主程序才退出（规格 §12.3 第 10～11 步）。
    await coordinator.requestExit();
  }

  /// 安全阻塞变化时刷新界面（阻塞不改变已就绪的包）。
  void notifySafetyChanged() => _emit();

  /// 诊断页读取日志尾部。
  Future<List<String>> readLogs({int maxLines = 200}) =>
      log.readRecent(maxLines: maxLines);

  /// 诊断页清除日志。**只删日志**，不动安装包、回退包或快照。
  Future<void> clearLogs() => log.clear();

  /// 立即重试（用户点击或退避到点）。
  Future<void> retry() async {
    final failure = _state.lastFailure;
    final paused = _state.pausedTargetVersion;
    // 用户显式重试可以清掉"该目标已暂停"，这是唯一的人工恢复路径。
    if (failure != null && !failure.retryable && paused == null) return;
    _state = _state.copyWith(
      retryAttempt: 0,
      targetFailureCount: 0,
      pausedTargetVersion: null,
      nextAttemptUtc: null,
      lastFailure: null,
    );

    // 基线失败/退避优先恢复：用户点一次就应该同时推动基线与下载。
    final preparation = _state.baselinePreparation;
    if (baselineService != null &&
        _state.target != null &&
        (preparation.phase == BaselinePhase.retryWaiting ||
            preparation.phase == BaselinePhase.failed)) {
      await ensureRollbackBaseline(userInitiated: true);
    }

    if (_state.target != null &&
        (_state.phase == UpdatePhase.failed ||
            _state.phase == UpdatePhase.downloadPaused ||
            _state.phase == UpdatePhase.temporarilyBlocked)) {
      await startDownload();
      return;
    }
    await check(manual: true);
  }

  /// 下一次自动重试是否已到点。
  bool get canAutoRetry {
    final next = _state.nextAttemptUtc;
    if (next == null) return false;
    return !clock.nowUtc().isBefore(next);
  }

  /// 基线自动重试是否已到点。
  bool get canAutoRetryBaseline {
    final preparation = _state.baselinePreparation;
    if (preparation.phase != BaselinePhase.retryWaiting) return false;
    final next = preparation.nextAttemptUtc;
    if (next == null) return true;
    return !clock.nowUtc().isBefore(next);
  }

  Future<bool> _go(UpdatePhase next) async {
    final result = _state.transitionTo(next, atUtc: clock.nowUtc());
    if (!result.acceptedTransition) {
      log.write(result.failure!);
      return false;
    }
    _state = result.state;
    _emit();
    return true;
  }

  Future<void> _persist() async {
    try {
      await stateStore.save(_state);
    } on AtomicFileException catch (error) {
      // 状态写不进去时**不能只留一个错误码**：日志要能看出是哪个文件、哪一步、
      // 什么 Windows 错误；界面仍然只显示稳定文案（规格 §9.2.6）。
      log.write(
        UpdateFailure(
          UpdateFailureCode.stateWriteFailed,
          detail: error.diagnosticDetail,
          windowsResultCode: error.osErrorCode,
          occurredAtUtc: clock.nowUtc(),
        ),
      );
    } on FileSystemException catch (error) {
      log.write(
        UpdateFailure(
          UpdateFailureCode.stateWriteFailed,
          detail: 'op=write state.json os=${error.osError?.errorCode ?? 0}',
          windowsResultCode: error.osError?.errorCode,
          occurredAtUtc: clock.nowUtc(),
        ),
      );
    } on Object {
      log.write(
        UpdateFailure(
          UpdateFailureCode.stateWriteFailed,
          occurredAtUtc: clock.nowUtc(),
        ),
      );
    }
  }

  void _emit() {
    if (_disposed) return;
    _states.add(_state);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _states.close();
  }
}
