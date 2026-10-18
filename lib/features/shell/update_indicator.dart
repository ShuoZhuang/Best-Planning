// 左下角更新入口（规格 §11.1 / §11.2 / §11.3）。
//
// 位置固定在主导航左下角；不随页面切换改变。它只做四件事：显示状态、展开状态卡片、
// 立即更新、重试。**它不弹窗、不弹通知、不打开浏览器、不在用户未点击时安装**。
import 'package:flutter/material.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/features/shell/update_indicator_model.dart';
import 'package:personal_planner/features/shell/update_status_card.dart';

final class UpdateIndicator extends StatefulWidget {
  const UpdateIndicator({
    super.key,
    required this.controller,
    this.onOpenDetails,
  });

  final UpdateController controller;
  final VoidCallback? onOpenDetails;

  @override
  State<UpdateIndicator> createState() => _UpdateIndicatorState();
}

final class _UpdateIndicatorState extends State<UpdateIndicator> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final snapshot = widget.controller.snapshot;
        final model = UpdateIndicatorModel.from(snapshot);
        if (!model.isVisible) {
          _expanded = false;
          return const SizedBox.shrink();
        }
        // 导航栏给子项的是无界宽度；入口内部有 Expanded 与 stretch 的 Column，
        // 必须自带一个确定宽度，否则会在真实外壳里触发布局断言。
        return SizedBox(
          key: const Key('update-indicator'),
          width: 236,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 140),
                child: _expanded
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: UpdateStatusCard(
                          snapshot: snapshot,
                          onInstall: _install,
                          onRetry: _retry,
                          onDownload: _download,
                          onCheck: _check,
                          onOpenDetails: () {
                            setState(() => _expanded = false);
                            widget.onOpenDetails?.call();
                          },
                          onClose: () => setState(() => _expanded = false),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              _IndicatorButton(
                model: model,
                onPressed: () => _handleTap(model),
                onLongPress: () => widget.onOpenDetails?.call(),
              ),
            ],
          ),
          ),
        );
      },
    );
  }

  void _handleTap(UpdateIndicatorModel model) {
    switch (model.action) {
      case UpdateIndicatorAction.install:
        _install();
      case UpdateIndicatorAction.retry:
        _retry();
      case UpdateIndicatorAction.expand:
        setState(() => _expanded = !_expanded);
      case UpdateIndicatorAction.none:
        break;
    }
  }

  /// **点击就绪图标直接进入更新流程**，不出现二次确认（规格 §11.3 / UPD-024）。
  Future<void> _install() async {
    if (!mounted) return;
    await widget.controller.install();
  }

  Future<void> _retry() async {
    await widget.controller.retry();
  }

  Future<void> _download() async {
    await widget.controller.startDownload();
  }

  Future<void> _check() async {
    await widget.controller.checkNow();
  }
}

final class _IndicatorButton extends StatelessWidget {
  const _IndicatorButton({
    required this.model,
    required this.onPressed,
    required this.onLongPress,
  });

  final UpdateIndicatorModel model;
  final VoidCallback onPressed;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _color(theme);
    final icon = Icon(_icon, size: 20, color: color);
    return Semantics(
      button: true,
      label: model.tooltip,
      child: Tooltip(
        message: model.tooltip,
        child: Material(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: const Key('update-indicator-button'),
            borderRadius: BorderRadius.circular(12),
            onTap: model.canTap ? onPressed : null,
            onLongPress: onLongPress,
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (model.kind == UpdateIndicatorKind.downloading)
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              value: model.progress,
                              strokeWidth: 2,
                            ),
                          )
                        else
                          icon,
                        if (model.kind == UpdateIndicatorKind.downloading)
                          Icon(_icon, size: 12, color: color),
                        if (model.showsBadge)
                          Positioned(
                            right: 0,
                            top: 0,
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _label(model),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: model.canTap
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (model.kind == UpdateIndicatorKind.ready &&
                      model.canInstall)
                    Icon(Icons.arrow_forward_rounded, size: 16, color: color),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _label(UpdateIndicatorModel model) {
    final progress = model.progress;
    return switch (model.kind) {
      UpdateIndicatorKind.downloading => progress == null
          ? model.title
          : '${model.title} ${(progress * 100).round()}%',
      UpdateIndicatorKind.verifying => model.title,
      UpdateIndicatorKind.ready =>
        model.canInstall ? '更新已就绪' : '更新已就绪（暂时不可用）',
      UpdateIndicatorKind.blocked => '暂时无法确认更新',
      UpdateIndicatorKind.failedRetryable => '更新失败，点击重试',
      UpdateIndicatorKind.failedPermanent => '更新失败',
      UpdateIndicatorKind.paused => '下载已暂停',
      UpdateIndicatorKind.hidden => '',
    };
  }

  IconData get _icon => switch (model.kind) {
    UpdateIndicatorKind.downloading => Icons.download_rounded,
    UpdateIndicatorKind.paused => Icons.pause_circle_outline_rounded,
    UpdateIndicatorKind.verifying => Icons.verified_outlined,
    UpdateIndicatorKind.ready => Icons.system_update_alt_rounded,
    UpdateIndicatorKind.blocked => Icons.cloud_off_rounded,
    UpdateIndicatorKind.failedRetryable ||
    UpdateIndicatorKind.failedPermanent =>
      Icons.error_outline_rounded,
    UpdateIndicatorKind.hidden => Icons.circle_outlined,
  };

  Color _color(ThemeData theme) => switch (model.kind) {
    UpdateIndicatorKind.ready => theme.colorScheme.primary,
    UpdateIndicatorKind.failedRetryable ||
    UpdateIndicatorKind.failedPermanent =>
      theme.colorScheme.error,
    UpdateIndicatorKind.blocked ||
    UpdateIndicatorKind.paused =>
      theme.colorScheme.onSurfaceVariant,
    _ => theme.colorScheme.primary,
  };
}

