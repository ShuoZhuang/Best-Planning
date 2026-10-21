import 'dart:collection';

import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';

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
    this.preferLater = false,
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

  /// 同分候选的平局顺序：为真时偏后，而不是默认的最早。
  final bool preferLater;

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
  const BusyInterval({
    required this.id,
    required this.range,
    this.protectedKind,
  });

  final String id;
  final TimeRange range;

  /// 这一段保护时间**是哪一个类别**（早餐／午餐／晚餐／固定休息）。
  ///
  /// **为什么必须是一个字段**（计划 §2.5）：类别此前只被编码进 [id] 的字符串
  /// （`protected:<kind>:<date>:<minute>`），于是视图层要靠 `id.split(':')` 反推
  /// 它——那等于把 id 的拼接格式当契约，格式一变就静默读错，而且当时那份推断
  /// **漏了 breakfast**。类型化的字段由展开层直接写入，视图层不必认识 id。
  ///
  /// 为空表示**这不是一条带类别的保护时间规则**：固定日程、睡眠与锁定块都是
  /// `null`（睡眠虽然有作息含义，但它不是 `protectedTimes` 里的一条规则）。
  final ProtectedTimeKind? protectedKind;
}

final class PlannedBlock {
  const PlannedBlock({
    required this.id,
    required this.taskId,
    required this.range,
    this.locked = false,
    this.explanationCode,
    this.continuedFromId,
  });

  final String id;
  final String taskId;
  final TimeRange range;
  final bool locked;
  final String? explanationCode;

  /// 这一块**延续自**当前确认计划里的哪一块；`null` 表示它是新排进来的。
  ///
  /// **为什么必须与 [id] 分开**（裁定第 1 点，设计 §5.1）：
  /// `applyProposal` 落库时构造 `persistedId = '<提案 id>:<block.id>'`，
  /// **并把 `PlannedBlock.id` 设成这个 persistedId 存回确认计划**。
  /// 因此若让新提案的 `block.id` 去复用确认计划里的旧 id，下一次确认就会得到
  /// `'<新提案 id>:<旧提案 id>:<原引擎 id>'` —— **每确认一次就再套一层提案前缀**。
  ///
  /// 分工因此写死：
  /// - **落库**用 [id]（保持 `'<提案 id>:<id>'`，绝不叠加）；
  /// - **查原位**（`referenceBlocks`）与**判"移动"**（`PlanDiffer`）用 [continuedFromId]；
  /// - **引擎内部**占用与冲突用 [id]（同一次生成内的唯一标识）。
  ///
  /// 它只作为**提案期关联**存在：落库时被丢掉，下次生成由来源匹配重新建立，
  /// 因此**不需要数据库迁移**（裁定第 1 点末句）。
  final String? continuedFromId;

  /// 基于本块派生一个**延续块**：换上新 id，并把**本块**登记为它的来源。
  ///
  /// **纯操作**：不修改本块。原地改 id 会让同一份输入在不同阶段看到不同的块。
  ///
  /// **来源永远是本块**，与 [nextId] 无关。这是刻意的：把 `continuedFromId`
  /// 设成 [nextId] 会让来源关联退化成"指向自己"，而 §5.1 的用途
  /// （查原位、判"移动"）要的恰恰是**指回上一版的那一块**。
  ///
  /// [nextId] 是新提案里给这一块起的名字；[newRange] 为空时沿用本块位置。
  ///
  /// **位置用 `TimeRange` 而不是"小时数"**：本块的 `range` 已经是 UTC 时刻，
  /// 再引入一个"本地钟点"参数就会多出一次时区换算——而规范 §4.1 的教训正是
  /// "同一件事不要在两层各算一次"。调用方（引擎／装配层）本来就有
  /// `TimeRange`，传进来即可。
  PlannedBlock continueFrom(
    String nextId, {
    TimeRange? newRange,
    String? explanationCode,
  }) => PlannedBlock(
    id: nextId,
    taskId: taskId,
    range: newRange ?? range,
    locked: locked,
    explanationCode: explanationCode ?? this.explanationCode,
    continuedFromId: id,
  );

  /// 登记/改写本块的来源（设计 §5.2 的配对结果用）。
  ///
  /// 与 [continueFrom] 的区别是**不改 id、不改位置**，只回答"它延续自谁"。
  /// 配对是"生成之后"的后处理，那时块的位置与 id 都已经定了。
  PlannedBlock withProvenance(String? sourceId) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: range,
    locked: locked,
    explanationCode: explanationCode,
    continuedFromId: sourceId,
  );

  DateTime get startUtc => range.startUtc;
  DateTime get endUtc => range.endUtc;
  int get durationMinutes => range.durationMinutes;

  @override
  bool operator ==(Object other) =>
      other is PlannedBlock &&
      other.id == id &&
      other.taskId == taskId &&
      other.range == range &&
      other.locked == locked &&
      other.explanationCode == explanationCode &&
      other.continuedFromId == continuedFromId;

  @override
  int get hashCode =>
      Object.hash(id, taskId, range, locked, explanationCode, continuedFromId);
}

/// 一次「调整当前计划块」的上下文（1.8.0，裁定第 3 点；设计 §5.3）。
///
/// **为什么必须是块级而不是任务级**：修复前装配层把"指定块的延后请求"转成
/// **整个任务的** `availableFromUtc`，于是**延后一块会把它自己其余的块也一起推后**。
/// 规范 §11.1 的文案是"只调整当前计划块"，§11.4 第 3、4 条要求"移动的其他块数量最少"
/// —— 任务级下界与这两条都不符。
///
/// **它是"意图"而不是"约束"**：`notBeforeUtc` 是**下界**，不是必须精确占用的点
/// （规范 §11.2 末条）。引擎据此判断"这一块最早可以从哪里开始"。
final class BlockAdjustmentContext {
  const BlockAdjustmentContext({
    required this.targetBlockId,
    required this.notBeforeUtc,
    required this.kind,
  });

  /// 要调整的那一块在**当前确认计划**里的 id。**不是任务 id。**
  final String targetBlockId;

  /// 目标块最早可以开始的位置（下界）。
  final DateTime notBeforeUtc;

  final BlockAdjustmentKind kind;
}

/// 调整的种类。目前只有延后；提前是独立操作、不在本批次（规范 §11.2）。
enum BlockAdjustmentKind { defer }

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
    required Map<DateTime, DailySchedulingPolicy> dailyPolicies,
    Map<DateTime, int> weeklyLifeQuotaByWeekStart = const {},
    required this.preferences,
    required this.inputHash,
    Set<String> pinnedUnlockedBlockIds = const {},
    Map<String, DateTime> referenceBlocks = const {},
    this.adjustment,
    List<PlannedBlock> confirmedBlocks = const [],
    List<PlanningConflict> admissionConflicts = const [],
  }) : tasks = UnmodifiableListView(List.of(tasks)),
       fixedIntervals = UnmodifiableListView(List.of(fixedIntervals)),
       protectedIntervals = UnmodifiableListView(List.of(protectedIntervals)),
       lockedBlocks = UnmodifiableListView(List.of(lockedBlocks)),
       existingBlocks = UnmodifiableListView(List.of(existingBlocks)),
       pinnedUnlockedBlockIds = UnmodifiableSetView(
         Set.of(pinnedUnlockedBlockIds),
       ),
       referenceBlocks = UnmodifiableMapView(Map.of(referenceBlocks)),
       confirmedBlocks = UnmodifiableListView(List.of(confirmedBlocks)),
       admissionConflicts = UnmodifiableListView(List.of(admissionConflicts)),
       dailyPolicies = UnmodifiableMapView(
         _validatedDailyPolicies(dailyPolicies),
       ),
       weeklyLifeQuotaByWeekStart = UnmodifiableMapView({
         for (final entry in weeklyLifeQuotaByWeekStart.entries)
           normalizeLocalDate(entry.key): entry.value,
       }) {
    for (final entry in this.weeklyLifeQuotaByWeekStart.entries) {
      if (entry.value < 0) {
        throw ArgumentError.value(
          entry.value,
          'weeklyLifeQuotaByWeekStart',
          '周生活配额不能为负（${entry.key}）',
        );
      }
    }
  }

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

  /// **逐日完整解析后的规则**（计划 §6）。键是归一后的本地日期，升序、连续、不重复。
  ///
  /// 这是算法 17 的核心输入之一：[rules] 从此只是**旧接口兼容快照与任务默认值来源**
  /// （计划 §6 兼容规则第 3 条），任何**按日期变化**的排程判断都必须改读
  /// [policyForLocalDate]，不得再从 [rules] 取窗口首日的值。
  ///
  /// 构造时校验（由 `ScheduleProblem` 自己的用例钉住）：
  /// - 非空；
  /// - 每个键都已归一（`DateTime(y, m, d)`）；
  /// - 按日**连续**且不重复——中间缺一天就意味着有人在装配时跳过了某个日期，
  ///   而那会让那一天悄悄回退到窗口首日规则，正是本计划要根除的缺陷。
  ///
  /// **覆盖规划窗口涉及的每一个本地日期**这一条由装配层用 `TimeZoneDatabase` 证明
  /// （计划 §6：不能把时区校验伪装成不持有时区数据库的值对象校验）。
  final Map<DateTime, DailySchedulingPolicy> dailyPolicies;

  /// **逐本地周**的生活配额，键是该周**周一**的本地日期（计划 §6 兼容规则末条）。
  ///
  /// 为什么不能继续用单一的 `rules.weeklyLifeQuotaMinutes`：窗口跨周时（滚动七天
  /// 几乎总是跨周），后半周的生活配额属于**下一周**的规则，用首周的值会算错目标。
  final Map<DateTime, int> weeklyLifeQuotaByWeekStart;

  /// 取 [localDate] 当天的规则。**缺键即装配不变量破坏**，抛 [StateError] 而不回退首日。
  DailySchedulingPolicy policyForLocalDate(DateTime localDate) {
    final key = normalizeLocalDate(localDate);
    final policy = dailyPolicies[key];
    if (policy == null) {
      throw StateError(
        '缺少本地日期 ${key.year}-${key.month}-${key.day} 的每日排程策略；'
        '装配层必须为规划窗口涉及的每一个本地日期构造 DailySchedulingPolicy，'
        '不得回退到窗口首日规则',
      );
    }
    return policy;
  }

  /// 取 [localDate] 所在**本地周**的生活配额，回退到该周的周一。
  ///
  /// 缺键同样抛 [StateError]：周配额缺失意味着装配层没有解析那一周的规则，
  /// 静默返回 0 会让生活类任务的缺口无法解释。
  int lifeQuotaForLocalWeek(DateTime localDate) {
    final monday = _localMondayOf(localDate);
    final quota = weeklyLifeQuotaByWeekStart[monday];
    if (quota == null) {
      throw StateError(
        '缺少本地周（周一 ${monday.year}-${monday.month}-${monday.day}）的生活配额；'
        '装配层必须为窗口涉及的每一个本地周解析其周一规则',
      );
    }
    return quota;
  }

  /// **睡眠区间**：按逐日策略展开、只与规划窗口相交的部分，按起点升序。
  ///
  /// 算法 17 之前，睡眠只存在于 `AvailabilityBuilder` 内部（容量扣它，而
  /// `protectedIntervals` 里没有它，于是 `PlanValidator` 不认为"块压在睡眠上"是冲突）。
  /// 现在睡眠由装配层**按当天规则**展开一次，同时进入 [protectedIntervals]（供校验）
  /// 与 `AvailabilityInput.sleepIntervals`（供容量），因此两处口径只能是同一份。
  ///
  /// 标签为 [ProtectedTimeKind] 之外的一类：它由 `AvailabilityBuilder` 记成
  /// `AvailabilityBlockerKind.sleep`，与"改保护时间"区分开。
  List<BusyInterval> get sleepIntervals => UnmodifiableListView([
    for (final interval in protectedIntervals)
      if (interval.protectedKind == null && interval.id.startsWith('sleep:'))
        interval,
  ]);

  final PreferenceProfile preferences;
  final String inputHash;

  /// 被**手动拖动钉住、但用户选择不锁定**的计划块 id（FR-CAL-05）。  ///
  /// 这些块同时出现在 `lockedBlocks` 里，而且在那里带着 `locked: true`——这是**故意的**：
  /// 引擎把 `lockedBlocks` 原样收进计划，且 `_improve` 会跳过 `locked` 的块，因此只有在
  /// 输入侧标成锁定，这次手动移动才不会被局部改进当场搬走（否则用户看到的是"拖了没用"）。
  /// 生成结束后，引擎再把**这些 id** 的 `locked` 改回 `false` 输出，于是它落地为未锁定，
  /// 后续重排可以移动它——这正是"可选择锁定"里"不锁定"那一支的真实含义。
  ///
  /// 用独立的集合而不是"`lockedBlocks` 里带 `locked: false` 的项"，是因为后者会被 `_improve`
  /// 当成可移动块，两条分支的区别就消失了。
  final Set<String> pinnedUnlockedBlockIds;

  /// **调整前**每个已确认块的位置：块 id → 开始时刻（1.8.0，规范 §11.4 第 3、4 条）。
  ///
  /// 用来数"这次调整动了几个块、一共挪了多少分钟"。规范把这两项排在**硬约束之后的
  /// 第一、二位**，而它们**天生是整体量**：必须是"与调整前相比"，不可能从单块候选的
  /// 分数里加出来。修复前引擎只有一个 900 分的移动惩罚项，把"少动"与"少走"揉成一个数——
  /// 于是三次小改动（每次都略微提高总分）整体上可能比一次大改动动得更多。
  ///
  /// **只有"已确认过的块"才在这里**：新排进来的块没有"调整前"，把它的当前位置塞进去
  /// 会让位移恒为 0，等于给自己发一张免罚单。
  ///
  /// **刻意不进 `inputHash`**：它是**比较用的参照**，不改变"哪些块可以放在哪里"。
  /// 把它算进哈希会让同一份排程输入因为参照不同而生成两份提案，而两份的**内容**相同。
  final Map<String, DateTime> referenceBlocks;

  /// 本次生成是否是一次**块级调整**（裁定第 3 点；设计 §5.3）。  ///
  /// 为空表示这是一次普通全量生成。非空时 [BlockAdjustmentContext.targetBlockId]
  /// 指向**当前确认计划里**要调整的那一块，[BlockAdjustmentContext.notBeforeUtc]
  /// 是它的下界。
  ///
  /// **它不进 `inputHash`**：与 [referenceBlocks] 同理——它是"比较与目标"的输入，
  /// 不是"哪些时间可用"的输入。把它算进哈希会让同一次调整在确认阶段被判为过期。
  final BlockAdjustmentContext? adjustment;

  /// **当前确认计划里的块**（1.8.0，裁定第 1、4 点；设计 §5.2）。
  ///
  /// 生成本身**不读它**（从零生成的结构不变）；它是给"生成**之后**建立来源关联"
  /// 用的输入：新排出的块要与它逐块配对，才能让
  /// `PlanDiffer` 把"同一块换了时间"报成「移动」而不是删除＋新增。
  ///
  /// **不进 `inputHash`**：它是"上一版长什么样"，不改变"哪些时间可用"。
  final List<PlannedBlock> confirmedBlocks;

  /// **准入期**就判定为阻断性输入错误的冲突（1.8.0「可见空闲却报容量不足」专项 §1.7）。
  ///
  /// 有些任务在**装配阶段**就已经确定它不能进入本次排程：例如它自己的
  /// `availableFromUtc >= dueAtUtc`（时间边界自相矛盾）。这类任务**不尝试排程**
  /// ——拿一件自相矛盾的任务去排只会产出无法复现的结果。
  ///
  /// 但"不排它"与"静默丢弃它"是两件事：装配层因此把判定结果作为**阻断冲突**挂在问题上，
  /// 由引擎原样并入 `proposal.conflicts`，于是预览会如实告诉用户"哪一件任务的数据有问题、
  /// 该改什么"，而不是让它悄悄消失。
  ///
  /// **刻意由装配层构造而不是由排程层判定**：判定用的是
  /// `application/schedule_window_admission.dart` 的纯函数，而 `scheduling/`
  /// **不反过来依赖 `application/`**（否则形成依赖环）。因此这里承载的是**结果**，
  /// 不是规则。装配层用 `ScheduleWindowAdmission.evidenceCode` 填
  /// `PlanningConflict.blockingInput`，由 `explanations.dart` 翻译成用户文案。
  ///
  /// **不进 `inputHash`**：它与 `tasks` 是同一批输入的两种表达（`tasks` 已经排除了这些
  /// 任务），把它算进哈希只会让同一份输入得到两个哈希。
  final List<PlanningConflict> admissionConflicts;
}

/// 校验并复制每日策略表：非空、键已归一、按日连续且不重复。
///
/// 这个函数是 [ScheduleProblem] 构造器的一部分，独立出来只为一件事：
/// 让"哪些形状是非法输入"在一处可读、可被单独讨论，而不是散在初始化列表里。
Map<DateTime, DailySchedulingPolicy> _validatedDailyPolicies(
  Map<DateTime, DailySchedulingPolicy> source,
) {
  if (source.isEmpty) {
    throw ArgumentError.value(
      source,
      'dailyPolicies',
      '每日排程策略不得为空：算法 17 的每一次日期敏感判断都要读它',
    );
  }
  final normalized = <DateTime, DailySchedulingPolicy>{};
  for (final entry in source.entries) {
    final key = normalizeLocalDate(entry.key);
    if (normalized.containsKey(key)) {
      throw ArgumentError.value(
        key,
        'dailyPolicies',
        '同一个本地日期出现了两条策略：${key.year}-${key.month}-${key.day}',
      );
    }
    final policy = entry.value;
    if (policy.localDate != key) {
      throw ArgumentError.value(
        key,
        'dailyPolicies',
        '策略自身的 localDate（${policy.localDate}）与它的键不一致',
      );
    }
    normalized[key] = entry.value;
  }
  final dates = normalized.keys.toList()..sort();
  for (var index = 1; index < dates.length; index++) {
    final previous = dates[index - 1];
    final expected = DateTime(previous.year, previous.month, previous.day + 1);
    if (dates[index] != expected) {
      throw ArgumentError.value(
        dates[index],
        'dailyPolicies',
        '每日策略必须按日连续：$previous 之后应当是 $expected，'
            '而不是 ${dates[index]}（缺日会让那一天悄悄回退到窗口首日规则）',
      );
    }
  }
  return normalized;
}

/// [localDate] 所在**本地周**的周一（归一为 `DateTime(y, m, d)`）。
DateTime _localMondayOf(DateTime localDate) {
  final date = normalizeLocalDate(localDate);
  return DateTime(date.year, date.month, date.day - (date.weekday - 1));
}
