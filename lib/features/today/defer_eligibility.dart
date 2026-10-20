import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

/// 「延后本次」入口的资格（计划 Task 9 Step 2、DFR-007/020）。
///
/// 修复前入口只按 `_isTask` 判断：历史块、进行中块、已完成任务和锁定块都会显示
/// "延后本次"，点了之后才由服务静默拒绝。这里把"能不能点、为什么不能点"提前算出来，
/// 页面据此隐藏或显示**带原因的禁用项**。
enum DeferEntryReason {
  eligible,
  notTask,
  notInCurrentPlan,
  completed,
  alreadyStarted,
  locked,
}

final class DeferEligibility {
  const DeferEligibility._({
    required this.isVisible,
    required this.isEnabled,
    required this.reason,
  });

  /// 是否渲染这个入口。
  final bool isVisible;

  /// 渲染时是否可点击。
  final bool isEnabled;

  final DeferEntryReason reason;

  /// 只依据页面**已经拥有的**事实判断：是否任务、任务是否完成、块是否已经到点。
  /// 锁定与执行事实仍由服务在点击时复核。
  ///
  /// 今日页只展示当前确认计划与固定安排，因此"待确认预排"不在这里判断。
  factory DeferEligibility.forItem({
    required ScheduleViewItem item,
    required DateTime nowUtc,
  }) {
    if (item.kind != ScheduleItemKind.task || item.taskId == null) {
      return const DeferEligibility._(
        isVisible: false,
        isEnabled: false,
        reason: DeferEntryReason.notTask,
      );
    }
    if (item.isCompleted) {
      return const DeferEligibility._(
        isVisible: true,
        isEnabled: false,
        reason: DeferEntryReason.completed,
      );
    }
    if (item.isLocked) {
      return const DeferEligibility._(
        isVisible: true,
        isEnabled: false,
        reason: DeferEntryReason.locked,
      );
    }
    if (!item.range.startUtc.isAfter(nowUtc)) {
      return const DeferEligibility._(
        isVisible: true,
        isEnabled: false,
        reason: DeferEntryReason.alreadyStarted,
      );
    }
    return const DeferEligibility._(
      isVisible: true,
      isEnabled: true,
      reason: DeferEntryReason.eligible,
    );
  }

  /// 禁用项的文案：说明**为什么**不能延后，而不是一句"不可用"。
  String? get disabledLabel => switch (reason) {
    DeferEntryReason.completed => '任务已完成，不能延后',
    DeferEntryReason.locked => '这一块已锁定，不能延后',
    DeferEntryReason.alreadyStarted => '这一块已经开始，不能延后',
    DeferEntryReason.notInCurrentPlan => '计划已变化，请刷新',
    DeferEntryReason.notTask => null,
    DeferEntryReason.eligible => null,
  };
}
