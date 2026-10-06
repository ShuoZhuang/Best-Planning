import 'dart:collection';

import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';

final class SchedulableTask {
  const SchedulableTask({
    required this.id,
    required this.requiredMinutes,
    required this.splitMode,
    required this.minChunkMinutes,
    required this.maxChunkMinutes,
    this.dueAtUtc,
    this.availableFromUtc,
    this.priority = TaskPriority.medium,
    this.energyLevel = TaskEnergyLevel.medium,
    this.isLifeTask = false,
    this.preferredWindow,
  });

  final String id;
  final int requiredMinutes;
  final TaskSplitMode splitMode;
  final int minChunkMinutes;
  final int maxChunkMinutes;
  final DateTime? dueAtUtc;
  final DateTime? availableFromUtc;
  final TaskPriority priority;
  final TaskEnergyLevel energyLevel;
  final bool isLifeTask;

  /// 任务的期望时段，本地分钟区间；为空表示用户没有表达偏好。
  ///
  /// 设计 §5.4 的"任务期望时段"因子用。区间允许跨越本地午夜，换算时由
  /// `LocalTimeRange.splitAtMidnight` 拆成两段处理，因此 22:00–02:00 这类
  /// 写法不会被当成空区间或反向区间。
  final LocalTimeRange? preferredWindow;
}

final class BusyInterval {
  const BusyInterval({required this.id, required this.range});
  final String id;
  final TimeRange range;
}

final class PlannedBlock {
  const PlannedBlock({
    required this.id,
    required this.taskId,
    required this.range,
    this.locked = false,
    this.explanationCode,
  });

  final String id;
  final String taskId;
  final TimeRange range;
  final bool locked;
  final String? explanationCode;

  DateTime get startUtc => range.startUtc;
  DateTime get endUtc => range.endUtc;
  int get durationMinutes => range.durationMinutes;
}

final class ScheduleProblem {
  ScheduleProblem({
    required this.planningWindow,
    required this.timeZoneId,
    required List<SchedulableTask> tasks,
    required List<BusyInterval> fixedIntervals,
    required List<BusyInterval> protectedIntervals,
    required List<PlannedBlock> lockedBlocks,
    List<PlannedBlock> existingBlocks = const [],
    required this.rules,
    required this.preferences,
    required this.inputHash,
    Set<String> pinnedUnlockedBlockIds = const {},
  }) : tasks = UnmodifiableListView(List.of(tasks)),
       fixedIntervals = UnmodifiableListView(List.of(fixedIntervals)),
       protectedIntervals = UnmodifiableListView(List.of(protectedIntervals)),
       lockedBlocks = UnmodifiableListView(List.of(lockedBlocks)),
       existingBlocks = UnmodifiableListView(List.of(existingBlocks)),
       pinnedUnlockedBlockIds = UnmodifiableSetView(
         Set.of(pinnedUnlockedBlockIds),
       );

  final TimeRange planningWindow;
  final String timeZoneId;
  final List<SchedulableTask> tasks;
  final List<BusyInterval> fixedIntervals;
  final List<BusyInterval> protectedIntervals;
  final List<PlannedBlock> lockedBlocks;

  /// 已确认但**未锁定**的时间块：引擎可以移动它们，但移动应付出代价。
  ///
  /// 用于设计 §5.4 的"移动已确认但未锁定的时间块"因子。它们不进 `lockedBlocks`，
  /// 因此不会被硬约束冻结；也不进可用时间，因此新计划仍可复用这些时段。
  final List<PlannedBlock> existingBlocks;
  final PlanningRules rules;
  final PreferenceProfile preferences;
  final String inputHash;

  /// 被**手动拖动钉住、但用户选择不锁定**的计划块 id（FR-CAL-05）。
  ///
  /// 这些块同时出现在 `lockedBlocks` 里，而且在那里带着 `locked: true`——这是**故意的**：
  /// 引擎把 `lockedBlocks` 原样收进计划，且 `_improve` 会跳过 `locked` 的块，因此只有在
  /// 输入侧标成锁定，这次手动移动才不会被局部改进当场搬走（否则用户看到的是"拖了没用"）。
  /// 生成结束后，引擎再把**这些 id** 的 `locked` 改回 `false` 输出，于是它落地为未锁定，
  /// 后续重排可以移动它——这正是"可选择锁定"里"不锁定"那一支的真实含义。
  ///
  /// 用独立的集合而不是"`lockedBlocks` 里带 `locked: false` 的项"，是因为后者会被 `_improve`
  /// 当成可移动块，两条分支的区别就消失了。
  final Set<String> pinnedUnlockedBlockIds;
}
