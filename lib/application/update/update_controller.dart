// 界面与业务之间的唯一适配层（规格 §11.6 最后一条：左下角与设置页读同一个状态源）。
//
// 它把编排器的状态、安全阻塞与用户设置聚合成一个不可变快照；界面只读快照，不自己比较
// 版本、不自己判断"是否可以安装"、也不缓存第二份状态。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_check_result.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_settings.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';

/// 一次界面渲染所需的全部事实。
final class UpdateSnapshot {
  const UpdateSnapshot({
    required this.state,
    required this.safety,
    required this.autoUpdateEnabled,
    this.installed,
    this.manifest,
    this.baselineRequired = false,
  });

  final UpdateState state;
  final UpdateSafetyStatus safety;
  final bool autoUpdateEnabled;
  final InstalledPackage? installed;
  final VerifiedManifest? manifest;

  /// 本环境是否把"回退基线就绪"作为安装前置条件。
  ///
  /// 只有装配了基线任务的生产组合根才为真；未打包的开发/测试环境没有这项能力，
  /// 因此界面不应把"没有基线"说成"正在准备安全更新"。
  final bool baselineRequired;

  bool get isReady => state.phase == UpdatePhase.ready && state.target != null;

  /// 就绪且没有业务阻塞时才允许点击安装。
  bool get canInstall => isReady && safety.canInstall;

  /// 当前安装版本。未打包时为 `null`。
  MsixVersion? get installedVersion => installed?.version;

  /// 最新稳定版本（来自已验证清单；没有确认过时为 `null`）。
  MsixVersion? get latestVersion => manifest?.manifest.msixVersion;

  bool get hasConfirmedManifest => manifest != null;

  String? get releaseNotesUrl => manifest?.manifest.presentation.releaseUrl;

  String? get releaseTitle => manifest?.manifest.presentation.title;

  String? get releaseSummary => manifest?.manifest.presentation.summary;
}

final class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.orchestrator,
    required this.settings,
    required this.safety,
  });

  final UpdateOrchestrator orchestrator;
  final UpdateSettingsStore settings;
  final UpdateSafetyCoordinator safety;

  UpdateSettings _settings = const UpdateSettings();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  bool _initialized = false;
  bool _disposed = false;

  UpdateState get state => orchestrator.state;

  InstalledPackage? get installed => orchestrator.installed;

  bool get autoUpdateEnabled => _settings.autoUpdateEnabled;

  UpdateSnapshot get snapshot => UpdateSnapshot(
    state: orchestrator.state,
    safety: safety.status,
    autoUpdateEnabled: _settings.autoUpdateEnabled,
    installed: orchestrator.installed,
    manifest: orchestrator.latestManifest,
    baselineRequired: orchestrator.baselineService != null,
  );

  bool get isInitialized => _initialized;

  /// 本次启动是否为"升级后第一次启动"；非空时组合根应写健康确认。
  String? get pendingHealthTransaction => orchestrator.pendingHealthTransaction;

  MsixVersion? get pendingHealthVersion => orchestrator.pendingHealthVersion;

  Future<void> initialize() async {
    if (_initialized) return;
    _settings = await settings.load();
    await orchestrator.initialize();
    _subscriptions
      ..add(orchestrator.states.listen((_) => _notify()))
      ..add(
        safety.changes.listen((_) {
          orchestrator.notifySafetyChanged();
          _notify();
        }),
      );
    _initialized = true;
    _notify();
  }

  Future<UpdateCheckResult> checkNow() async {
    final result = await orchestrator.check(
      manual: true,
      autoDownload: _settings.autoUpdateEnabled,
    );
    // 手动检查也触发基线准备，但**不等待**：缓存已按请求身份隔离，两者可并行。
    unawaited(ensureBaseline());
    _notify();
    return result;
  }

  Future<void> startDownload() async {
    await orchestrator.startDownload();
    // 下载目标版本的同时后台准备基线：只受磁盘预算约束，不改变当前结论。
    unawaited(ensureBaseline());
    _notify();
  }

  Future<void> retry() async {
    await orchestrator.retry();
    _notify();
  }

  /// 点击左下角就绪入口——**没有二次确认**（规格 §11.3）。
  Future<void> install() async {
    await orchestrator.install();
    _notify();
  }

  Future<void> setAutoUpdateEnabled(bool enabled) async {
    final changed = _settings.autoUpdateEnabled != enabled;
    _settings = _settings.copyWith(autoUpdateEnabled: enabled);
    _notify();
    await settings.save(_settings);
    // 从"关"改成"开"必须立即开始准备回退基线，无需重启（UPD-INC-007）。
    if (changed && enabled) {
      unawaited(ensureBaseline());
    }
  }

  /// 手动模式下的"开始下载"（自动更新关闭但用户主动要求）。
  Future<void> downloadManually() => startDownload();

  /// 基线准备（single-flight 在编排器里，多入口调用安全）。
  Future<void> ensureBaseline() async {
    await orchestrator.ensureRollbackBaseline();
    _notify();
  }

  /// 强制重试基线（用户点击"重试准备"）。
  Future<void> retryBaseline() async {
    await orchestrator.ensureRollbackBaseline(userInitiated: true);
    _notify();
  }

  /// 健康确认成功后晋升基线（由组合根在写完健康确认之后调用）。
  Future<void> confirmHealth() async {
    await orchestrator.confirmHealthPromotion();
    _notify();
  }

  Future<List<String>> readLogs({int maxLines = 200}) =>
      orchestrator.readLogs(maxLines: maxLines);

  Future<void> clearLogs() => orchestrator.clearLogs();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    super.dispose();
  }
}
