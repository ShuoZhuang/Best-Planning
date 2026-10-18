// 更新编排器：唯一业务入口（规格 §5.1 / §7 / §9）。
//
// 它把"检查、下载、验证、就绪、安装"收敛成一条状态机，并保证三件事：
//   · **四类检查结论不被混淆**：只有验证通过的清单比较后才可能 `upToDate`；
//   · **同一时间只有一个事务**：检查进行中再来的触发合并成同一个 Future；
//   · **失败可恢复**：所有错误写进状态与日志，下载分段与已验证包不因一次失败被丢弃。
//
// 它不直接接触 Windows API：包身份、签名验证与安装都由端口实现（`platform/update`）。
import 'dart:async';

import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_check_result.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

/// 下载前/安装前的磁盘安全余量：至少 `max(500 MB, 安装包大小 × 2)`（规格 §8.5）。
int updateDiskSafetyMarginBytes(int packageBytes) {
  const fiveHundredMegabytes = 500 * 1024 * 1024;
  final doublePackage = packageBytes * 2;
  return fiveHundredMegabytes > doublePackage ? fiveHundredMegabytes : doublePackage;
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

  final StreamController<UpdateState> _states =
      StreamController<UpdateState>.broadcast();

  UpdateState _state = const UpdateState();
  VerifiedManifest? _latestManifest;
  InstalledPackage? _installed;

  Future<UpdateCheckResult>? _activeCheck;
  Future<void>? _activeDownload;
  bool _disposed = false;
  DateTime? _lastPersistedProgressUtc;
  int _lastPersistedBytes = -1;

  UpdateState get state => _state;

  /// 最近一次**验证通过**的清单。界面展示标题/摘要时用它；为 `null` 时只显示版本事实。
  VerifiedManifest? get latestManifest => _latestManifest;

  InstalledPackage? get installed => _installed;

  Stream<UpdateState> get states => _states.stream;

  /// 启动时恢复：状态文件只是线索，文件、已安装包与进程才是事实（规格 §9.4）。
  Future<void> initialize() async {
    _state = await stateStore.load();
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
      _state = _state.copyWith(phase: UpdatePhase.idle);
    }
    if (_state.phase == UpdatePhase.installing ||
        _state.phase == UpdatePhase.launchingNewVersion ||
        _state.phase == UpdatePhase.waitingForHealth) {
      final target = _state.target;
      if (target != null && _installed?.version == target.msixVersion) {
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
    _emit();
    await _persist();
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

    _state = _state.copyWith(
      currentMsixVersion: installed.version,
      lastCheckedUtc: clock.nowUtc(),
      lastFailure: null,
    );
    if (!await _go(UpdatePhase.checking)) {
      return _currentResult(installed);
    }

    final fetch = await manifestSource.fetchLatest(etag: _state.manifestEtag);
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
              'windows=${windows.value} required=${verified.manifest.compatibility.minimumWindowsBuild.value}',
        ),
        installed,
      );
    }

    if (verified.manifest.isRevoked) {
      return _handleCheckFailure(
        const UpdateFailure(UpdateFailureCode.packageVersionRevoked),
        installed,
      );
    }

    final relation = verified.manifest.relationTo(installed.version);
    final now = clock.nowUtc();
    if (relation == UpdateVersionRelation.older) {
      return _handleCheckFailure(
        UpdateFailure(
          UpdateFailureCode.packageDowngradeBlocked,
          detail: 'remote=${verified.manifest.msixVersion.value} installed=${installed.version.value}',
        ),
        installed,
      );
    }

    if (relation == UpdateVersionRelation.same) {
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
        manifestEtag: verified.etag,
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

    final target = UpdateTarget(
      version: verified.manifest.release.version,
      buildNumber: verified.manifest.release.buildNumber,
      tag: verified.manifest.tag,
      msixVersion: verified.manifest.msixVersion,
      fileName: verified.manifest.package.fileName,
      downloadUrl: verified.manifest.package.downloadUrl,
      sizeBytes: verified.manifest.package.sizeBytes,
      sha256: verified.manifest.package.sha256,
      manifestDigest: verified.canonicalDigest,
      keyId: verified.manifest.signature.keyId,
    );

    await _go(UpdatePhase.updateAvailable);
    _state = _state.copyWith(
      target: target,
      receivedBytes: 0,
      totalBytes: target.sizeBytes,
      etag: null,
      lastModified: null,
      retryAttempt: 0,
      nextAttemptUtc: null,
      lastConfirmedUtc: now,
      manifestEtag: verified.etag,
      lastCheckClassification: UpdateCheckClassification.updateAvailable,
      lastFailure: null,
    );
    await _persist();
    _emit();

    if (autoDownload) {
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
      CompatibilityMismatch.identityName ||
      CompatibilityMismatch.publisher => UpdateFailureCode.packagePublisherMismatch,
      CompatibilityMismatch.familyName => UpdateFailureCode.packageFamilyMismatch,
      CompatibilityMismatch.architecture => UpdateFailureCode.packageArchMismatch,
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
    if (_state.phase == UpdatePhase.ready) {
      await _reverifyReadyPackage(target);
      return;
    }
    final allowed = _state.phase == UpdatePhase.updateAvailable ||
        _state.phase == UpdatePhase.downloadPaused ||
        _state.phase == UpdatePhase.failed ||
        _state.phase == UpdatePhase.temporarilyBlocked;
    if (!allowed) return;

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

    final installed = _installed ?? await installedPackages.current();
    if (installed == null) {
      await _failDownload(
        const UpdateFailure(UpdateFailureCode.environmentNotPackaged),
        target: target,
      );
      return;
    }
    _installed = installed;

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
          _disposed ||
          _state.target?.msixVersion != target.msixVersion,
      onProgress: (received, total) {
        _onProgress(received, total);
      },
    );

    if (outcome.cancelled) return;

    if (!outcome.isSuccess) {
      final failure = outcome.failure ?? const UpdateFailure(UpdateFailureCode.internalError);
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
      final failure = verification.failure ?? const UpdateFailure(UpdateFailureCode.packageFormatInvalid);
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
      nextAttemptUtc: null,
    );
    log.writeLine(
      'ready target=${target.msixVersion.value} sha256=${target.sha256}',
    );
    await _persist();
    _emit();
  }

  /// `ready` 状态的包在崩溃/重启后必须再次验证（规格 §9.5）。
  Future<void> _reverifyReadyPackage(UpdateTarget target) async {
    final installed = _installed;
    if (installed == null) return;
    final ready = layout.readyPackage(target);
    if (!await ready.exists()) {
      await _go(UpdatePhase.failed);
      _state = _state.copyWith(
        lastFailure: const UpdateFailure(UpdateFailureCode.packageFormatInvalid),
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
        verification.failure ?? const UpdateFailure(UpdateFailureCode.packageFormatInvalid),
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
        failure.code,
        detail: failure.detail,
        windowsResultCode: failure.windowsResultCode,
        occurredAtUtc: clock.nowUtc(),
        attempt: attempt,
      ),
      retryAttempt: attempt,
      nextAttemptUtc: failure.retryable ? next : null,
    );
    log.write(failure);
    await _persist();
    _emit();
  }

  Future<void> _discardReadyPackage(UpdateTarget target) async {
    try {
      final ready = layout.readyPackage(target);
      if (await ready.exists()) await ready.delete();
    } on Object {
      // 删不掉时保留文件；下一次验证仍会失败，不会误装。
    }
  }

  /// 用户点击就绪入口后的安装请求（规格 §12.3 的前半段在这里）。
  ///
  /// 在原生安装链装配之前，它只做两件事：检查安全阻塞、记录明确原因。**不弹二次确认**，
  /// 也不假装已经开始安装。
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

    final safetyStatus = safety.status;
    if (!safetyStatus.canInstall) {
      final failure = safetyStatus.failure;
      _state = _state.copyWith(lastFailure: failure);
      log.write(failure!);
      _emit();
      await _persist();
      return;
    }

    final coordinator = installCoordinator;
    if (coordinator == null) {
      await _failDownload(
        const UpdateFailure(UpdateFailureCode.helperMissing),
        target: target,
      );
      return;
    }

    if (!await _go(UpdatePhase.preparingInstall)) return;
    await _persist();
    _emit();

    final outcome = await coordinator.prepareAndLaunch(
      target: target,
      state: _state,
      installed: installed,
    );
    final failure = outcome.failure;
    if (!outcome.launched || failure != null) {
      // 助手没有确认之前不得退出：退回到就绪，保留包，等待用户重试。
      await _go(UpdatePhase.ready);
      _state = _state.copyWith(
        lastFailure: failure ??
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
    if (failure != null && !failure.retryable) return;
    _state = _state.copyWith(
      retryAttempt: 0,
      nextAttemptUtc: null,
      lastFailure: null,
    );
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

