import 'package:flutter/material.dart';

/// 操作式首次引导的**首页**（M8，用户 2026-10-07 定案）。
///
/// 用户原话：
/// ```
/// 引导首页继续提供：
///   [创建第一个任务]
///   [导入课表]
///   [了解主要界面]
/// 如果用户已经有任务，文案改为「再创建一个任务」，避免假装这是第一次使用。
/// ```
///
/// **它只负责列出来**：三个动作都由组合根（`planner_app.dart`）注入——
/// 与 `SettingsHubPage` 同一取舍，这一页不认识路由、不认识任务服务，
/// 因此可以用一个普通 widget 测试把文案与可达性钉死。
///
/// **为什么不把"创建任务"直接实现在这里**：引导里创建的任务必须与普通任务
/// **完全同一条路径**（同一任务表、同一套默认值与校验、可编辑可删除可重排、
/// 统计与日历里正常显示，退出引导后仍保留）。在引导页里另写一套表单，
/// 就等于开了第二条创建路径——那正是用户明确禁止的"增加特殊任务类型"的变体。
final class OnboardingHomePage extends StatelessWidget {
  const OnboardingHomePage({
    required this.hasExistingTasks,
    required this.onCreateTask,
    required this.onImportTimetable,
    required this.onLearnUi,
    this.onSkip,
    super.key,
  });

  /// 用户**曾经创建过任何任务**（含已完成／已取消）。
  ///
  /// **为什么不是"还有未完成的"**：一个把任务都做完的老用户，同样是老用户；
  /// 只看未完成的会把他叫成"第一次使用"，而这正是用户要避免的那句话。
  final bool hasExistingTasks;

  final VoidCallback onCreateTask;
  final VoidCallback onImportTimetable;
  final VoidCallback onLearnUi;

  /// 「跳过引导」。为 `null` 时**整个按钮不渲染**——与"未装配的入口不渲染"同一口径，
  /// 不留一个点了没反应的按钮。
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.rocket_launch_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                '从第一件事开始',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                // 老用户看到的说明也不一样：不假装他是第一次用。
                hasExistingTasks
                    ? '你已经有一些任务了。可以再建一个、导入一张课表，或者先看看主要界面。'
                    : '建一个任务、导入一张课表，或者先看看主要界面。'
                          '这三件事都可以稍后再做。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                key: const Key('onboarding-create-task'),
                onPressed: onCreateTask,
                icon: const Icon(Icons.add_task_outlined),
                // 用户明确要求的两句文案，二选一。
                label: Text(hasExistingTasks ? '再创建一个任务' : '创建第一个任务'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('onboarding-import-timetable'),
                onPressed: onImportTimetable,
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('导入课表'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('onboarding-learn-ui'),
                onPressed: onLearnUi,
                icon: const Icon(Icons.school_outlined),
                label: const Text('了解主要界面'),
              ),
              if (onSkip != null) ...[
                const SizedBox(height: 24),
                TextButton(
                  key: const Key('onboarding-skip'),
                  onPressed: onSkip,
                  child: const Text('跳过引导'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
