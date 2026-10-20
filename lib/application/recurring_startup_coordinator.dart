// ignore_for_file: prefer_initializing_formals

/// 启动/恢复编排的 typed stage（1.11.0 周期预排 Task 17）。
enum RecurringStartupStage {
  fragmentBackfill,
  creditCheck,
  horizonMaintenance,
  previewRefresh,
  reminderReconcile,
}

final class RecurringStartupReport {
  const RecurringStartupReport({
    required this.completed,
    this.failedStage,
    this.error,
  });

  final List<RecurringStartupStage> completed;
  final RecurringStartupStage? failedStage;
  final Object? error;

  bool get succeeded => failedStage == null;
}

/// 按固定顺序执行启动阶段；任一阶段失败即停止，保留已完成阶段。
final class RecurringStartupCoordinator {
  RecurringStartupCoordinator({
    required Map<RecurringStartupStage, Future<void> Function()> stages,
  }) : _stages = stages;

  final Map<RecurringStartupStage, Future<void> Function()> _stages;

  Future<RecurringStartupReport> run() async {
    final completed = <RecurringStartupStage>[];
    for (final stage in RecurringStartupStage.values) {
      final action = _stages[stage];
      if (action == null) continue;
      try {
        await action();
        completed.add(stage);
      } on Object catch (error) {
        return RecurringStartupReport(
          completed: completed,
          failedStage: stage,
          error: error,
        );
      }
    }
    return RecurringStartupReport(completed: completed);
  }
}
