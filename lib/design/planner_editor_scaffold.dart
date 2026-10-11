import 'package:flutter/material.dart';

/// 编辑器页共用的骨架（1.8.0，设计规范 §7.2 最后一段）。
///
/// **只抽布局，不抽字段模型**：四类事项（普通任务、周期目标、固定日程、保护时间）的字段
/// 差别很大，强行统一字段会变成一个什么都塞得下的巨型表单。用户真正看到的不一致只有四处：
/// 标题区的位置、返回行为、底部保存栏、错误摘要。这四处在这里定死。
///
/// **为什么不是抽象基类**：这几页各自是 `StatefulWidget`，继承会把它们的 `State` 也绑进来；
/// 而这里需要的只是布局。组合比继承更小也更好测。
final class PlannerEditorScaffold extends StatelessWidget {
  const PlannerEditorScaffold({
    required this.title,
    required this.child,
    required this.actions,
    this.subtitle,
    this.onCancel,
    this.cancelLabel = '取消',
    this.errorSummary,
    this.maxContentWidth = 780,
    super.key,
  });

  /// 页面标题，例如「新建固定日程」。
  final String title;

  /// 标题下的一句说明。为空时不占位。
  final String? subtitle;

  /// 可滚动的内容区（各页自己的字段）。
  final Widget child;

  /// 底部保存栏里的动作按钮，从右往左排。
  final List<Widget> actions;

  /// 返回上一页。为 `null` 时底栏不显示取消按钮——与"不给点了没反应的入口"同一口径。
  final VoidCallback? onCancel;
  final String cancelLabel;

  /// 校验失败摘要。非空时显示在底栏上方，且带一个稳定 key 供测试与屏幕阅读器定位。
  final Widget? errorSummary;

  /// 内容区最大宽度。**必须有一个上限**：编辑器在 2560 宽的窗口上铺满整屏时，
  /// 一行标签与它右侧的输入框会隔着半米远，读起来是两件不相干的东西。
  final double maxContentWidth;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    key: const Key('editor-title'),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  if (subtitle case final subtitle?) ...[
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (errorSummary case final summary?) ...[
                    summary,
                    const SizedBox(height: 16),
                  ],
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 12,
              children: [
                if (onCancel case final onCancel?)
                  TextButton(
                    key: const Key('editor-cancel'),
                    onPressed: onCancel,
                    child: Text(cancelLabel),
                  ),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// 校验失败摘要：一句话加若干条具体原因。
///
/// 存在的理由与规范 §3 第 7 条同源：错误必须**可操作**。"有字段没填对"没有告诉用户
/// 该改哪一处；列出具体字段才有用。这里只负责显示，判定仍由各页自己做。
final class PlannerEditorErrorSummary extends StatelessWidget {
  const PlannerEditorErrorSummary({
    required this.messages,
    this.lead = '还有几处需要修改',
    super.key,
  });

  final List<String> messages;
  final String lead;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.error;
    return Container(
      key: const Key('editor-error-summary'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: color),
              const SizedBox(width: 8),
              Text(lead, style: TextStyle(color: color)),
            ],
          ),
          const SizedBox(height: 6),
          for (final message in messages)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: Text(message, style: TextStyle(color: color)),
            ),
        ],
      ),
    );
  }
}
