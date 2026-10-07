import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/features/tutorial/tutorial_steps.dart';

/// 新手教程：一步一张真实界面截图，配说明与要点，可前后翻、可跳过。
///
/// **两个入口共用同一实现**：① 首次启动时自动出现（`PlannerApp` 里按
/// [seenKey] 判断）；② 「设置 → 新手教程」随时重看。因此这一页不知道"自己是第几次被打开"，
/// 也不写任何设置——要不要记住由装配方在 [onComplete] 里决定。
final class TutorialPage extends StatefulWidget {
  const TutorialPage({
    required this.onComplete,
    this.steps = tutorialSteps,
    this.initialStep = 0,
    super.key,
  });

  /// 看完最后一步或点「跳过」时调用一次。**调用方负责记住"看过了"**。
  final VoidCallback onComplete;

  /// 步骤列表。可注入是为了让测试用两三条短步骤，而不必依赖真实截图数量。
  final List<TutorialStep> steps;

  final int initialStep;

  /// "已经看过教程"的设置键。存的是 [currentVersion]（整数文本），与首次引导的 schema 版本
  /// 同一套路：教程将来大改时可以抬版本，让老用户再看一次增量。
  static const String seenKey = 'onboarding.tutorialSeen.v1';
  static const int currentVersion = 1;

  @override
  State<TutorialPage> createState() => _TutorialPageState();
}

final class _TutorialPageState extends State<TutorialPage> {
  late int _index = widget.initialStep.clamp(0, widget.steps.length - 1);

  bool get _isLast => _index >= widget.steps.length - 1;

  void _next() {
    if (_isLast) {
      widget.onComplete();
      return;
    }
    setState(() => _index++);
  }

  void _previous() {
    if (_index == 0) return;
    setState(() => _index--);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.steps.isEmpty) {
      // 空列表是配置错误，但**不该崩**：给一句说明并让用户能出去。
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('教程暂时没有内容。'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: widget.onComplete,
                child: const Text('知道了'),
              ),
            ],
          ),
        ),
      );
    }

    final step = widget.steps[_index];
    final total = widget.steps.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('新手教程'),
        automaticallyImplyLeading: false,
        actions: [
          // 最后一步不再显示"跳过"：那时"完成"和"跳过"是同一件事，两个按钮只会让人犹豫。
          if (!_isLast)
            TextButton(
              key: const Key('tutorial-skip'),
              onPressed: widget.onComplete,
              child: const Text('跳过'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '第 ${_index + 1} / $total 步',
                        key: const Key('tutorial-progress-text'),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    Text(
                      step.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    key: const Key('tutorial-progress-bar'),
                    value: (_index + 1) / total,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(child: _Visual(step: step)),
                const SizedBox(height: 16),
                Text(
                  step.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(step.body, style: Theme.of(context).textTheme.bodyLarge),
                if (step.bullets.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final bullet in step.bullets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 6, right: 8),
                            child: Icon(Icons.circle, size: 6),
                          ),
                          Expanded(
                            child: Text(
                              bullet,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    OutlinedButton.icon(
                      key: const Key('tutorial-previous'),
                      // 第一步没有上一步：给一个明确禁用的按钮，而不是让它消失——
                      // 消失会让"下一步"的位置跳一下。
                      onPressed: _index == 0 ? null : _previous,
                      icon: const Icon(Icons.chevron_left),
                      label: const Text('上一步'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      key: const Key('tutorial-next'),
                      onPressed: _next,
                      icon: Icon(_isLast ? Icons.check : Icons.chevron_right),
                      label: Text(_isLast ? '开始使用' : '下一步'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 截图区。没有截图的步骤（开场页）给一个图标占位。
final class _Visual extends StatelessWidget {
  const _Visual({required this.step});
  final TutorialStep step;

  @override
  Widget build(BuildContext context) {
    final asset = step.assetPath;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: PlannerPalette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PlannerPalette.outline),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: asset == null
            ? Center(
                child: Icon(
                  Icons.auto_awesome_outlined,
                  size: 72,
                  color: Theme.of(context).colorScheme.primary,
                ),
              )
            : Image.asset(
                asset,
                fit: BoxFit.contain,
                // **缺图不能让教程崩**：资源没打进包时（打包/裁剪出错）给一句可读的替代文案，
                // 而不是一个红色的报错方块。
                errorBuilder: (context, error, stack) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '这一步的截图没有打包进来（$asset）。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
