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
  });

  final UpdateState state;
  final UpdateSafetyStatus safety;
  final bool autoUpdateEnabled;
  final InstalledPackage? installed;
  final VerifiedManifest? manifest;

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
  );

  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) return;
    _settings = await settings.load();
    await orchestrator.initialize();
    _subscriptions
      ..add(orchestrator.states.listen((_) => _notify()))
      ..add(safety.changes.listen((_) {
        orchestrator.notifySafetyChanged();
        _notify();
      }));
    _initialized = true;
    _notify();
  }

  Future<UpdateCheckResult> checkNow() async {
    final result = await orchestrator.check(
      manual: true,
      autoDownload: _settings.autoUpdateEnabled,
    );
    _notify();
    return result;
  }

  Future<void> startDownload() async {
    await orchestrator.startDownload();
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
    _settings = _settings.copyWith(autoUpdateEnabled: enabled);
    _notify();
    await settings.save(_settings);
  }

  /// 手动模式下的"开始下载"（自动更新关闭但用户主动要求）。
  Future<void> downloadManually() => startDownload();

  Future<void> ensureBaseline() => orchestrator.ensureRollbackBaseline();

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



