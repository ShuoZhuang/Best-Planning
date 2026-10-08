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
    this.allowedWeekdaysMask = allWeekdaysMask,
    this.maxMinutesPerLocalDay,
    this.distributionPolicy = TaskDistributionPolicy.unconstrained,
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

  /// 允许安排的本地星期，7 位掩码，**周一是 bit 0**。默认全部允许。
  ///
  /// 与 [maxMinutesPerLocalDay] 一起表达"周期目标的节奏"（路线图 §3.4、Task 8 Step 5）。
  /// 这两项刻意做成**约束**而不是另写一个排程器：引擎照旧只有一个，节奏只是收窄了它可选的
  /// 位置与每天可放的量。用户选了"仅周三与周六"时，如果只在展开层拆窗口而引擎不知道，
  /// 引擎完全可以把量放到别的日子——`recurring_planning_test` 的"仅指定星期不会排到未选择的
  /// 本地星期"就是钉这一点的。
  final int allowedWeekdaysMask;

  /// 每个**本地日**最多安排多少分钟；为空表示不限制。
  ///
  /// "均匀分布"靠它成立：把目标除到每一天，引擎就无法把整周的量堆进同一天。
  /// 引擎在放置时会把它减去当天**已经排进去**的分钟，因此它约束的是"这一天总共多少"，
  /// 而不是"单个片段多长"。
  final int? maxMinutesPerLocalDay;

  /// 该任务在日期之间如何分配分钟；见 [TaskDistributionPolicy]。
  ///
  /// 默认 [TaskDistributionPolicy.unconstrained]，因此既有调用点无需改动，
  /// 而"周期目标的均匀分布"必须**显式**声明，不再依赖 `maxMinutesPerLocalDay` 是否为空。
  final TaskDistributionPolicy distributionPolicy;

  /// 该掩码是否允许某个本地星期（`DateTime.monday` … `DateTime.sunday`）。
  bool allowsWeekday(int weekday) =>
      allowedWeekdaysMask & (1 << (weekday - DateTime.monday)) != 0;
}

/// 任务在**日期之间**如何分配分钟。
///
/// 这是 1.7.1 新增的**明确策略标记**（计划 Task 3 Step 4）。它替换掉此前用
/// `maxMinutesPerLocalDay != null` 暗示"这是周期均分任务"的隐式做法——那是两个不同的概念：
///
/// - [unconstrained]：普通任务。引擎按优先级、截止、精力与容量自行决定落在哪些天。
/// - [even]：周期目标的"均匀分布"。先由容量感知的均分器算出**每天的分钟预算**，
///   日内选点才交给评分（计划 §3.2）。
///
/// 之所以要把两者分开：`maxMinutesPerLocalDay` 表达的是"这一天最多多少"，而"均匀分布"
/// 表达的是"每天**应当**多少、余数落在哪两天"。修复前引擎把它们混成一个会被全局放开的
/// 单日软配额，于是同一天可以被堆到 125 分钟（计划 §2.1）。
enum TaskDistributionPolicy { unconstrained, even }

/// 全部七天都允许的掩码（周一 bit 0 … 周日 bit 6）。
const int allWeekdaysMask = 0x7F;

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
