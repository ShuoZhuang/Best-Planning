// 左下角更新入口的投影（规格 §11.2 的逐行映射）。
//
// 纯函数：输入是 [UpdateSnapshot]，输出是"图标长什么样、能不能点、点了做什么"。
// 这样六种界面行为的断言不需要 pump 整个应用，也不会因为某个页面没挂载而漏测。
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/domain/update/update_state.dart';

/// 入口的视觉档位。
enum UpdateIndicatorKind {
  hidden,
  downloading,
  paused,
  verifying,
  ready,
  blocked,
  failedRetryable,
  failedPermanent,
}

/// 点击入口时执行的动作。**没有"弹二次确认"这一项**（规格 §11.3）。
enum UpdateIndicatorAction { none, expand, retry, install }

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
      kind == UpdateIndicatorKind.failedRetryable ||
      kind == UpdateIndicatorKind.failedPermanent;

  static UpdateIndicatorModel from(UpdateSnapshot snapshot) {
    final state = snapshot.state;
    final failure = state.lastFailure;
    final safety = snapshot.safety;
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
          action: UpdateIndicatorAction.expand,
        );
      case UpdatePhase.failed:
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
