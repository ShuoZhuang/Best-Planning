// 左下角更新入口的投影（规格 §11.2 的逐行映射；1.11.1 修复 §9）。
//
// 纯函数：输入是 [UpdateSnapshot]，输出是"图标长什么样、能不能点、点了做什么"。
// 这样界面行为的断言不需要 pump 整个应用，也不会因为某个页面没挂载而漏测。
//
// 1.11.1 的两条硬要求：
//   · 普通卡片**不显示内部错误码**，只显示可理解的下一步；
//   · 基线准备有自己的可见状态："正在准备安全更新 / 等待网络恢复 / 更新暂时无法安装"，
//     而不是把 `UPDATE_BLOCKED_ROLLBACK_NOT_READY` 直接甩给用户。
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/domain/update/update_baseline_status.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_state.dart';

/// 入口的视觉档位。
enum UpdateIndicatorKind {
  hidden,
  downloading,
  paused,
  verifying,
  preparingSafety,
  waitingNetwork,
  ready,
  staleRetained,
  blocked,
  revoked,
  failedRetryable,
  failedPermanent,
}

/// 点击入口时执行的动作。**没有"弹二次确认"这一项**（规格 §11.3）。
enum UpdateIndicatorAction {
  none,
  expand,
  retry,
  retryBaseline,
  retryCheck,
  install,
}

final class UpdateIndicatorModel {
  const UpdateIndicatorModel({
    required this.kind,
    required this.title,
    required this.tooltip,
    this.message,
    this.progress,
    this.canTap = false,
    this.canInstall = false,
    this.action = UpdateIndicatorAction.none,
  });

  final UpdateIndicatorKind kind;
  final String title;
  final String tooltip;
  final String? message;

  /// 0..1 的下载进度；未知总量时为 `null`。
  final double? progress;

  final bool canTap;

  /// 仅 `ready` 且无业务阻塞时为真。
  final bool canInstall;

  final UpdateIndicatorAction action;

  bool get isVisible => kind != UpdateIndicatorKind.hidden;

  /// 入口是否显示高亮标记（就绪或失败）。
  bool get showsBadge =>
      kind == UpdateIndicatorKind.ready ||
      kind == UpdateIndicatorKind.preparingSafety ||
      kind == UpdateIndicatorKind.waitingNetwork ||
      kind == UpdateIndicatorKind.failedRetryable ||
      kind == UpdateIndicatorKind.failedPermanent;

  /// 陈旧 latest 但保留了已下载更新时的说明（"暂时无法重新确认，但更新还在"）。
  static const String staleNote = '暂时无法重新确认更新；已下载的更新仍会保留。';

  static UpdateIndicatorModel from(UpdateSnapshot snapshot) {
    final state = snapshot.state;
    final failure = state.lastFailure;
    final safety = snapshot.safety;
    final baseline = state.baselinePreparation;
    final stale =
        state.lastCheckClassification ==
            UpdateCheckClassification.temporarilyUnconfirmed &&
        failure?.code == UpdateFailureCode.manifestStaleLatest;

    switch (state.phase) {
      case UpdatePhase.idle:
      case UpdatePhase.checking:
      case UpdatePhase.upToDate:
        return const UpdateIndicatorModel(
          kind: UpdateIndicatorKind.hidden,
          title: '',
          tooltip: '',
        );
      case UpdatePhase.updateAvailable:
        return UpdateIndicatorModel(
          kind: UpdateIndicatorKind.downloading,
          title: '发现新版本',
          tooltip: '发现新版本，正在准备下载',
          progress: state.downloadProgress,
          canTap: true,
          action: UpdateIndicatorAction.expand,
        );
      case UpdatePhase.downloading:
        return UpdateIndicatorModel(
          kind: UpdateIndicatorKind.downloading,
          title: '正在下载更新',
          tooltip: _downloadTooltip(state),
          progress: state.downloadProgress,
          canTap: true,
          action: UpdateIndicatorAction.expand,
        );
      case UpdatePhase.downloadPaused:
        return UpdateIndicatorModel(
          kind: UpdateIndicatorKind.paused,
          title: '更新下载已暂停',
          tooltip: failure?.userMessage ?? '更新下载已暂停',
          message: failure?.userMessage,
          progress: state.downloadProgress,
          canTap: true,
          action: UpdateIndicatorAction.retry,
        );
      case UpdatePhase.verifying:
        return const UpdateIndicatorModel(
          kind: UpdateIndicatorKind.verifying,
          title: '正在验证更新包',
          tooltip: '正在验证更新包',
          canTap: true,
          action: UpdateIndicatorAction.expand,
        );
      case UpdatePhase.ready:
        // 基线未就绪时**先讲清楚在准备什么**，而不是显示"更新已就绪（不可用）"。
        if (snapshot.baselineRequired && !baseline.phase.isReady) {
          final waiting = baseline.phase == BaselinePhase.retryWaiting;
          final failed = baseline.phase == BaselinePhase.failed;
          if (!waiting && !failed) {
            return const UpdateIndicatorModel(
              kind: UpdateIndicatorKind.preparingSafety,
              title: '更新已下载 · 正在准备安全更新',
              tooltip: '正在下载并校验回退包，完成后即可安装',
              message: null,
              canTap: true,
              action: UpdateIndicatorAction.expand,
            );
          }
          return UpdateIndicatorModel(
            kind: waiting
                ? UpdateIndicatorKind.waitingNetwork
                : UpdateIndicatorKind.failedRetryable,
            title: waiting ? '更新已下载 · 等待网络恢复' : '更新暂时无法安装',
            tooltip: waiting ? '安全回退包准备失败，恢复网络后可自动重试' : '安全回退包准备失败，可点击重试准备',
            message: baseline.lastFailure?.userMessage ?? '安全更新准备失败，可重试。',
            canTap: true,
            action: UpdateIndicatorAction.retryBaseline,
          );
        }
        if (stale) {
          return UpdateIndicatorModel(
            kind: UpdateIndicatorKind.staleRetained,
            title: '暂时无法重新确认',
            tooltip: staleNote,
            message: staleNote,
            canTap: true,
            action: UpdateIndicatorAction.retryCheck,
          );
        }
        final blocked = !safety.canInstall;
        return UpdateIndicatorModel(
          kind: UpdateIndicatorKind.ready,
          title: '更新已就绪',
          tooltip: blocked ? (safety.message ?? '更新已就绪') : '点击立即更新（无需再次确认）',
          message: blocked ? safety.message : null,
          canTap: true,
          canInstall: !blocked,
          action: blocked
              ? UpdateIndicatorAction.expand
              : UpdateIndicatorAction.install,
        );
      case UpdatePhase.temporarilyBlocked:
        return UpdateIndicatorModel(
          kind: UpdateIndicatorKind.blocked,
          title: '暂时无法确认更新',
          tooltip: failure?.userMessage ?? '暂时无法确认更新',
          message: failure?.userMessage,
          canTap: true,
          action: UpdateIndicatorAction.retryCheck,
        );
      case UpdatePhase.failed:
        if (failure?.code == UpdateFailureCode.packageVersionRevoked) {
          return const UpdateIndicatorModel(
            kind: UpdateIndicatorKind.revoked,
            title: '此更新已撤回',
            tooltip: '此更新已被发布方撤回，正在等待新版本',
            message: '此更新已被发布方撤回，正在等待新版本。',
            canTap: true,
            action: UpdateIndicatorAction.retryCheck,
          );
        }
        final retryable = failure?.retryable ?? false;
        return UpdateIndicatorModel(
          kind: retryable
              ? UpdateIndicatorKind.failedRetryable
              : UpdateIndicatorKind.failedPermanent,
          title: retryable ? '更新暂时失败' : '更新失败',
          tooltip: failure?.userMessage ?? '更新失败',
          message: failure?.userMessage,
          canTap: true,
          action: retryable
              ? UpdateIndicatorAction.retry
              : UpdateIndicatorAction.expand,
        );
      // 安装链阶段：入口保持可见（更新正在进行），但不允许再次点击安装。
      case UpdatePhase.preparingInstall:
      case UpdatePhase.waitingForExit:
      case UpdatePhase.installing:
      case UpdatePhase.launchingNewVersion:
      case UpdatePhase.waitingForHealth:
      case UpdatePhase.rollingBack:
      case UpdatePhase.rolledBack:
      case UpdatePhase.succeeded:
        return UpdateIndicatorModel(
          kind: UpdateIndicatorKind.verifying,
          title: state.phase.label,
          tooltip: state.phase.label,
          canTap: false,
        );
    }
  }

  static String _downloadTooltip(UpdateState state) {
    final total = state.totalBytes;
    if (total == null || total <= 0) return '正在下载更新';
    final percent = (state.receivedBytes / total * 100).clamp(0, 100).round();
    return '正在下载更新 $percent%';
  }
}
