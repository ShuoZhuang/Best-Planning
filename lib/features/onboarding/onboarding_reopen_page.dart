import 'package:flutter/material.dart';
import 'package:personal_planner/application/onboarding_progress.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_home_page.dart';

/// 从设置重开引导时的步骤标识。
///
/// **与 `planner_app.dart` 里那个 [`_stepGuidedHome`] 用同一个字符串值**，
/// 因为它们是同一步（引导首页）。两处各写一个字面量是有意的取舍：
/// 让这个页面**不依赖 app 层**（它只是个设置子页），代价是这一对字符串要一起改——
/// 因此两处都留了这句注释指向对方。
const _reopenStep = 'guidedHome';

/// **从设置里重新打开首次引导**（用户 2026-10-08 反馈后补）。
///
/// 用户的原话是"我怎么从引导首页点进去啊，这个的前提是我没有装软件吧"——
/// 他说得对：引导首页只在**首次启动那条路径**上出现，一旦走完（或跳过），
/// 设置里**没有任何入口**能再看到它。而与此对照，**新手教程一直有个"随时重看"入口**。
/// 这条不一致本身就是缺口：帮助材料应当随时可达。
///
/// 这个页面把"重新打开引导"做成一个**真正的设置子页**：
/// - 进入时把进度记成**进行中**（这正是"重新打开引导"的语义：你确实在走引导）；
///   但**不会**把 `completed`／`skipped` 抹成别的状态去骗人——见下面 `_open` 的说明。
/// - 三个入口复用与首次启动**同一个** `OnboardingHomePage`，因此文案规则
///   （"已有任务时写「再创建一个任务」"）与首次启动**只有一处实现**。
/// - 导航由路由器注入：这一页不认识路由，与 `SettingsHubPage` 同一取舍。
///
/// **它不会重置任何真实数据**：任务、课程、已确认计划都不在 `SettingsRepository` 里，
/// 这里也只写引导进度的那两个键。
final class OnboardingReopenPage extends StatefulWidget {
  const OnboardingReopenPage({
    required this.settings,
    required this.tasks,
    required this.onCreateTask,
    required this.onImportTimetable,
    required this.onLearnUi,
    super.key,
  });

  final SettingsRepository settings;

  /// 只用来回答一个问题：**用户是否曾经创建过任何任务**（决定首页文案）。
  final TaskRepository tasks;

  final VoidCallback onCreateTask;
  final VoidCallback onImportTimetable;
  final VoidCallback onLearnUi;

  @override
  State<OnboardingReopenPage> createState() => _OnboardingReopenPageState();
}

final class _OnboardingReopenPageState extends State<OnboardingReopenPage> {
  late final OnboardingProgressStore _progress = OnboardingProgressStore(
    settings: widget.settings,
  );
  late final Future<bool> _hasExistingTasks = _probeTasks();

  @override
  void initState() {
    super.initState();
    _open();
  }

  /// 记成**进行中**并落在 `guidedHome` 这一步。
  ///
  /// **为什么从设置进来也要写这一步**：用户点了"首次引导"，他就**确实在走引导**。
  /// 若只在首次启动那条路径上写，那么从设置进来、中途返回主界面、再重启时，
  /// 进度仍是旧的（已完成／已跳过），启动**不会再问"要不要继续"**——
  /// 而他明明正在走。这条与用户定的"退出不冒充完成"是同一件事的两面。
  ///
  /// **它不重置任何真实数据**：任务、课程与已确认计划都不在 `SettingsRepository` 里，
  /// 这里只写引导进度的那两个键。
  Future<void> _open() async {
    await _progress.begin(step: _reopenStep);
  }

  Future<bool> _probeTasks() async {
    try {
      // **判据是"曾经创建过任何任务"**（含已完成／已取消），与首次启动同一口径：
      // 一个把任务都做完的老用户同样是老用户，不该被告知"创建第一个任务"。
      return (await widget.tasks.watchAllTasks().first).isNotEmpty;
    } on Object {
      // 读不出来就当没有：只影响一句文案，不该让这一页打不开。
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('首次引导')),
    body: FutureBuilder<bool>(
      future: _hasExistingTasks,
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return OnboardingHomePage(
          // 这一页自带 AppBar 当返回入口，因此首页**不再渲染自己的 Scaffold 标题区**
          // 也不必额外说明——它只是一个内容区。
          hasExistingTasks: snapshot.data!,
          onCreateTask: widget.onCreateTask,
          onImportTimetable: widget.onImportTimetable,
          onLearnUi: widget.onLearnUi,
          // 从设置进来的这一次**不显示「跳过引导」**：用户是主动来重看的，
          // 给他一个"跳过"既没有意义，又可能把状态改成 skipped 而产生副作用。
          // 想离开直接返回即可。
          onSkip: null,
        );
      },
    ),
  );
}
