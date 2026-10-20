import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/pending_moves.dart';
import 'package:personal_planner/application/pending_skips.dart';
import 'package:personal_planner/application/plan_adjustment_service.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/confirmed_block_partition.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/schedule_window_admission.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_adjustment_repository.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/course_transition.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/protected_time_expander.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/recurring_cycle_capacity.dart';
import 'package:personal_planner/scheduling/recurring_pace_curve.dart';

/// 生产用的排程输入来源：把持久化的事实数据装配成 `ScheduleProblem`。
///
/// 这是此前缺失的一环——`InputSnapshotBuilder` 只负责对已有的 `ScheduleProblem`
/// 求哈希，仓库层与排程引擎之间没有任何代码负责装配输入，因此引擎、提案与
/// 调整预览在真实运行中都不可达。
///
/// 装配规则：
/// - 规划窗口为从"本机当前时区的今天 00:00"起 [days] 天的半开区间；
/// - 固定日程取窗口内全部 `CalendarOccurrence`；
/// - 保护时间由 [ProtectedTimeExpander] 逐日展开；
/// - 仅有 `locked` 的已确认计划块进入 `lockedBlocks`，未锁定块不冻结，
///   以便重排可以移动它们；
/// - `rules` 的日间字段（精力区间、保护时间）同时保留工作日与周末两套，
///   由引擎按当天 `DayKind` 筛选；睡眠、每日上限、生活配额等"整窗口唯一"的
///   字段取窗口首日的解析结果——这是 `ScheduleProblem.rules` 单一对象的既有
///   限制，跨工作日与周末的窗口不会为周末单独取一份上限。
///
/// 已知缺口：`PreferenceProfile` 目前传入空值。学习偏好已由
/// `SettingsService.resolveForDate` 合并进 `rules`，但计划模型中的
/// `preferences` 字段（常用专注长度、偏好精力区间）尚无公开读取路径。
final class RepositoryScheduleProblemSource
    implements ScheduleProblemSource, AdjustmentProblemSource {
  RepositoryScheduleProblemSource({
    required this.tasks,
    required this.lifeAreas,
    required this.calendar,
    required this.settings,
    required this.plans,
    required this.clock,
    required this.timeZoneId,
    required this.zones,
    this.days = 7,
    this.snapshots = const InputSnapshotBuilder(),
    this.pendingMoves,
    this.pendingSkips,
    this.recurring,
    this.recurringSnapshots,
    this.adjustments,
  }) : protectedTimes = ProtectedTimeExpander(zones),
       rules = PlanningRuleResolver(settings);
  final TaskRepository tasks;
  final LifeAreaLookup lifeAreas;
  final CalendarRepository calendar;
  final SettingsService settings;
  final PlanRepository plans;
  final Clock clock;
  final String timeZoneId;
  final TimeZoneDatabase zones;
  final int days;
  final InputSnapshotBuilder snapshots;
  final ProtectedTimeExpander protectedTimes;
  final PlanningRuleResolver rules;

  /// 用户手动拖动产生的待处理移动（FR-CAL-05）。为空即"没有手动移动"，行为与从前完全一致。
  final PendingMoveDrafts? pendingMoves;

  /// 用户点「**跳过本次**」产生的待处理跳过（M4，2026-10-07 用户定义）。
  ///
  /// 为空即"没有跳过"，行为与从前完全一致。语义见 `pending_skips.dart`：
  /// **只放弃这一个块**，任务仍在 `tasks` 里继续参与重排。
  final PendingSkipDrafts? pendingSkips;

  /// 周期目标的生成与进度（M6）。**为空时行为与从前完全一致**：周期实例仍会作为普通任务
  /// 参与排程（它本来就在 `tasks` 里），只是不带"本周视角"的截止时间与剩余量。
  final RecurringTaskService? recurring;
  final DriftRecurringExecutionRepository? recurringSnapshots;

  /// 调整仓储：`loadForAdjustment` 用它读取**调整自己的基线**（计划 Task 5 Step 4）。
  ///
  /// 为空时普通 `load` 行为完全不变；只有调整路径需要它，因此不给全部测试夹具
  /// 增加一个必须装配的依赖。
  final PlanAdjustmentRepository? adjustments;

  @override
  Future<ScheduleProblem> load({
    ScheduleRuleOverride? override,
    TimeRange? window,
    BlockAdjustmentContext? adjustmentContext,
    DateTime? windowEndUtc,
  }) async {
    final nowUtc = clock.nowUtc();
    final windowStartUtc = window?.startUtc ?? nowUtc;
    final startLocalDate = _dateOnly(zones.toLocal(windowStartUtc, timeZoneId));
    // ── 窗口起点是"现在"，不是当天本地午夜（路线图 Task 12A Step 5）──────────────
    //
    // 引擎判断"现在"用的就是 `planningWindow.startUtc`（`_targetFor` 里
    // `nowUtc: problem.planningWindow.startUtc`）。此前这里取的是本地午夜，等于告诉引擎
    // "现在是凌晨 0 点"——它因此可以合法地把新块排进**今天已经过去**的时段。用户看到的现象是：
    // 下午 15:30 生成计划，日程里冒出 09:00–10:00 这种已经过去的块，而"可用时间"里还把这几个小时
    // 算成能用的容量，缺口报告也跟着失真。
    //
    // 向上取整到排程粒度（`scheduleGranularityMinutes`）而不是直接用 `nowUtc`：引擎只在粒度网格上
    // 放置片段，起点若落在网格之外，第一个合法起点会被引擎自己上取整，反而让"不得早于现在"
    // 这件事在两个地方各算一遍。这里取整一次，网格与下界就只有一个来源。
    //
    // 终点**不变**：仍是"本地日边界 + [days] 天"。因此"未来七天"的长度语义没有被改动，
    // 变的只是不再回望过去。
    //
    // ── 粒度必须来自**规则**，不能写死（1.8.0，2026-10-12 故障；冻结决策 §1.4）──────────
    //
    // 修复前这里调的是 `_ceilToGranularity(instantUtc)`，用**默认 5 分钟**取整，
    // 而引擎与 `AvailabilityBuilder` 用的是 `problem.rules.granularityMinutes`。
    // 用户把粒度配成 10 分钟时，窗口起点会落在 5 分钟网格上（例如 09:35），
    // 与引擎的 10 分钟网格错开 —— 于是"第一个合法起点"在两个地方各算一遍。
    //
    // **规则必须先解析**，因此这几行的顺序不能换：`resolveForWindow` 在下面一行之前
    // 不能读取 `resolvedRules`。
    final resolvedRules = await rules.resolveForWindow(
      startLocalDate,
      override: override,
    );
    final dayStartUtc = zones.localMidnightToUtc(startLocalDate, timeZoneId);
    final startUtc = window == null
        ? _ceilToGranularity(
            nowUtc.isAfter(dayStartUtc) ? nowUtc : dayStartUtc,
            granularityMinutes: resolvedRules.granularityMinutes,
          )
        : (window.startUtc.isAfter(nowUtc) ? window.startUtc : nowUtc);
    final defaultEndUtc =
        window?.endUtc ??
        zones.localMidnightToUtc(
          startLocalDate.add(Duration(days: days)),
          timeZoneId,
        );
    // 调整专属窗口只能**扩大**：`max(默认窗口终点, adjustmentWindowEnd)`。
    // 缩小会让延后 1–7 天的合法目标被截掉，表现为莫名其妙的无解。
    final endUtc =
        windowEndUtc != null && windowEndUtc.isAfter(defaultEndUtc)
        ? windowEndUtc
        : defaultEndUtc;

    // ── 逐日规则与逐周生活配额（算法 17，计划 Task 2 Step 3）─────────────────────
    //
    // **这一段必须排在"硬占用区间"之前**：保护时间与睡眠此后按**当天规则**展开，
    // 而"当天规则"就是这里算出来的。修复前它们用 `resolvedRules`（窗口首日）展开，
    // 于是"周末睡眠不同""周末上限更高"这类设置整周都不生效（计划 §1.2 第 1 条）。
    final dailyPoliciesResult = await _dailyPoliciesFor(
      startUtc: startUtc,
      endUtc: endUtc,
      override: override,
    );
    final windowDates = dailyPoliciesResult.windowDates;
    final dailyPolicies = dailyPoliciesResult.policies;
    final weeklyLifeQuotaByWeekStart = dailyPoliciesResult.weeklyLifeQuota;

    // **先维护周期、再读 open tasks**：否则库中尚无本周载体时，首次生成计划会漏掉它。
    final recurringInputs = await _recurringInputs(nowUtc);

    final openTasks = await tasks.watchOpenTasks().first;
    final lifeTaskIds = await lifeAreas.lifeTaskIds();
    // **固定日程从当天本地午夜开始读，而不是从窗口起点（现在）开始读。**
    //
    // 窗口起点改成"现在"之后，一个**今天已经结束**的日程（例如 00:00–10:00 的课，而现在 10:00）
    // 就不再与窗口相交，于是被整段丢掉。那会让"窗口内的事实"少一条：同一天里已经发生过的固定
    // 日程不再计入当天占用与容量判断，而这与"不要把新块排到过去"是两件事——前者是**事实**，
    // 后者是**放置约束**。
    //
    // 因此读事实用完整的当天起点（`dayStartUtc`），放置下界仍由窗口起点表达。
    final occurrences = await calendar.occurrencesBetween(dayStartUtc, endUtc);
    // **按 `kind` 分成互为补集的两份**（1.8.0，规范 §9.1）：固定日程进 `fixedIntervals`，
    // 保护时间进 `protectedIntervals`，一次且仅一次。分成互为补集的两份而不是两次过滤，
    // 是为了让"某条记录两边都进"在类型上就不可能发生。
    final fixedOccurrences = [
      for (final occurrence in occurrences)
        if (occurrence.kind == CalendarEventKind.fixed) occurrence,
    ];
    final protectedOccurrences = [
      for (final occurrence in occurrences)
        if (occurrence.kind == CalendarEventKind.protected) occurrence,
    ];
    final confirmed = await plans.current();

    // 1.8.0（裁定第 3 点；设计 §5.3）：延后是**块级**意图，因此**不再**把它折算成
    // 任务的 `availableFromUtc`。
    //
    // 修复前的写法是：
    //
    //     deferredTaskStarts[block.taskId] = notBefore;
    //     availableFromUtc: _laterOf(task.availableFromUtc, deferredTaskStarts[task.id])
    //
    // 后果是**延后一块会把它自己其余的块也一起推后**——与规范 §11.1
    //（"只调整当前计划块"）和 §11.4 第 3、4 条（"移动的其他块数量最少"）都不符。
    //
    // 现在只组装一个**块级**上下文交给引擎。目标块必须真实存在于确认计划里，
    // 否则这条请求无法表达为块级调整——**也不退回任务级模拟**。
    //
    // 1.11.0 起调整走 `loadForAdjustment` 显式传入 [adjustmentContext]；内存草稿
    // 只保留给尚未迁移的旧路径（生产 router 不再写它）。
    BlockAdjustmentContext? adjustment = adjustmentContext;
    final deferDrafts = adjustment == null ? pendingMoves : null;
    final confirmedBlocksForDefer = confirmed?.blocks ?? const <PlannedBlock>[];
    if (deferDrafts != null) {
      final request = deferDrafts.adjustment;
      if (request != null) {
        final target = confirmedBlocksForDefer
            .where((block) => block.id == request.blockId)
            .firstOrNull;
        final notBefore = target == null
            ? null
            : deferDrafts.notBeforeForBlock(request.blockId, zones);
        if (target != null && notBefore != null) {
          adjustment = BlockAdjustmentContext(
            targetBlockId: target.id,
            notBeforeUtc: notBefore,
            kind: BlockAdjustmentKind.defer,
          );
        }
      }
    }

    // ── 排程输入准入：**先分类、再映射**（1.8.0，“可见空闲却报容量不足”专项）────────
    //
    // 修复前这里是"把 `openTasks` 全部映射成 `SchedulableTask`"，没有任何准入判断。
    // 后果是一类**无法产生候选却带着目标分钟**的任务混进问题：`availableFromUtc` 落在
    // 规划窗口终点或之后的那些。引擎为它算出一个目标、生成不出候选，最终以
    // 「还缺 N 分钟 · 可用时间不足」出现在预览里 —— 而用户看到的日历明明还有空档。
    //
    // 分类是**唯一的准入判据**（`classifyTaskForPlanningWindow`），生产与测试共用同一个
    // 函数，不得在这里复制条件。三类处置：
    // - `intersectsWindow` ⇒ 正常进入；
    // - `deadlineElapsed` ⇒ **也进入**，但由引擎按"截止窗口为 0"归因，不得静默消失；
    // - `futureOutsideWindow` ⇒ 静默排除（不是错误，只是还没轮到）；
    // - `invalid` ⇒ 阻断性输入错误，不尝试排程。
    //
    // **周期实例先行剥离**（见下面的 `cycleByTaskId`）：一个周期实例在数据库里既是
    // "周期实例"又是"一件普通任务"，本函数只允许它通过**周期输入**这一条路径进入，
    // 因此必须先按 task id 把全部实例从普通输入里摘掉，再由周期规则决定是否加回。
    final cycleByTaskId = await _cyclesByTaskId(
      openTasks.map((task) => task.id),
    );
    final planningWindowRange = TimeRange(startUtc: startUtc, endUtc: endUtc);
    final ordinaryTasks = [
      for (final task in openTasks)
        if (!cycleByTaskId.containsKey(task.id)) task,
    ];
    final schedulable = <SchedulableTask>[];
    // **准入期就判定为阻断的输入错误**（§1.7）：`invalid` 这一支不尝试排程，
    // 但**也不能静默丢弃**——装配层把判定结果挂成冲突，于是预览会如实告诉用户
    // "哪一件任务的数据有问题、该改什么"。`unscheduled` 里不会有它
    // （它从未进入 `problem.tasks`），因此不存在"缺口 ＋ 冲突"重复显示的问题。
    final admissionConflicts = <PlanningConflict>[];
    for (final task in ordinaryTasks) {
      final admission = classifyTaskForPlanningWindow(
        task: task,
        planningWindow: planningWindowRange,
      );
      if (admission.code == ScheduleWindowAdmissionCode.invalid) {
        admissionConflicts.add(
          PlanningConflict(
            code: ConflictCode.invalidInput,
            taskId: task.id,
            // 稳定短码，**不给用户看**：由 `explanations.dart` 翻译成一句可行动的文案。
            blockingInput: admission.evidenceCode,
          ),
        );
        continue;
      }
      if (!admission.entersSchedule) continue;
      schedulable.add(
        SchedulableTask(
          id: task.id,
          requiredMinutes: task.schedulingRemainingMinutes,
          splitMode: task.splitMode,
          minChunkMinutes: task.minChunkMinutes,
          maxChunkMinutes: task.maxChunkMinutes,
          dueAtUtc: task.dueAtUtc,
          // **任务自己的最早开始时间原样保留**（裁定第 3 点）：延后是块级意图，
          // 不再折算到任务级，因此这里没有"并进延后下界"这一步。
          availableFromUtc: task.availableFromUtc,
          priority: task.priority,
          energyLevel: task.energyLevel,
          // 生活配额因子此前恒为 0，因为这里从未设置该字段。
          isLifeTask: lifeTaskIds.contains(task.id),
          preferredWindow: task.preferredWindow,
        ),
      );
    }
    // 开发期断言：普通输入里不得残留任何周期实例（生产逻辑不依赖它）。
    assert(schedulable.every((task) => !cycleByTaskId.containsKey(task.id)));
    final schedulableIds = {for (final task in schedulable) task.id};

    // ── 周期目标进排程（M6，§3.4 / §11 Task 8）────────────────────────────────
    //
    // **周期实例本身就是一件普通任务**，因此它已经在 `openTasks` 里；这里要做的是把它
    // 那份"普通任务"的排程输入**换成周期视角的那一份**：截止时间＝本周末（或按节奏提前）、
    // 只送还差的部分、`selectedWeekdays` 拆成按天窗口。没有新约束类型、没有第二个排程器。
    //
    // **真正的隔离在上一段**：`cycleByTaskId` 收的是**滚动窗口内生成的每一个实例**，
    // 不只是"本周那一个"。修复前这里只删 `recurringInputs` 里的 task id（＝本周实例），
    // 于是 `ensureCycles` 为滚动七天补出来的**下周实例**留在普通输入里，成为一条同名、
    // 不同 id、本次窗口根本不覆盖的幽灵任务 —— 预览因此显示两条一模一样的缺口。
    //
    // **过滤掉而不是重复添加**：同一个 id 出现两次会让引擎把同一份剩余时长安排两遍。
    if (recurringInputs.isNotEmpty) {
      final capacityBusy = <TimeRange>[
        for (final block in confirmed?.blocks ?? const <PlannedBlock>[])
          block.range,
        for (final occurrence in occurrences) occurrence.range,
        for (final interval in protectedTimes.sleep(
          rules: resolvedRules,
          startUtc: nowUtc,
          endUtc: endUtc,
          timeZoneId: timeZoneId,
        ))
          interval.range,
      ];
      for (final input in recurringInputs) {
        final paced = _paceInput(
          input,
          capacityBusy,
          nowUtc,
          endUtc,
          resolvedRules.dailyMovableTaskLimitMinutes,
        );
        final expanded = recurringSchedulableTasks(input: paced, zones: zones);
        for (final task in expanded) {
          // 只在与普通任务同 id 的那一份已经被移除后才加入；同时处理"同一 id 的多个窗口"
          // （selectedWeekdays）——它们**必须都留下**，否则只有第一天能被安排。
          schedulable.add(task);
        }
      }
      schedulableIds
        ..clear()
        ..addAll({for (final task in schedulable) task.id});
    }

    // FR-CAL-05：把手动拖动落成排程输入。拖动的粒度是"块"，而 `ScheduleProblem` 是任务级
    // 模型，因此这里**按块把该块钉到目标位置**：时间取"保留原来的本地钟点、换到目标本地日"，
    // 与用户跨天列拖动看到的位置变化一致。钉住的块进 `lockedBlocks`（引擎原样收进计划，
    // 且局部改进会跳过它），因此这次拖动**一定**会在提案里体现——否则用户看到的是"拖了没用"。
    final confirmedBlocks = confirmed?.blocks ?? const <PlannedBlock>[];
    final pinnedByBlockId = <String, PlannedBlock>{};
    final pinnedUnlocked = <String>{};
    final drafts = pendingMoves;
    if (drafts != null) {
      for (final block in confirmedBlocks) {
        if (!schedulableIds.contains(block.taskId)) continue;
        // **被延后的那一块不进"精确锁定"这条路**（规范 §11.2：目标是下界，不是精确点）。
        //
        // 修复前的行为：今日页把分钟换算成 `RequestedMove.atInstant`，于是延后与拖动走同一
        // 条路径，这里给它 `locked: true` 钉在**精确目标时刻**。目标点一旦被固定日程、保护
        // 时间或另一个锁定块占用，方案直接失败（规范 §2.5）——它不会去找目标之后最近的合法
        // 时段。现在延后经 `ScheduleProblem.adjustment` 以**块级下界**交给引擎
        // （裁定第 3 点），目标块留在可移动块里由引擎在下界之后重新放置。
        //
        // 注意与修复前的区别：那时这里判的是**任务级** `deferredTaskStarts`，
        // 于是同一个任务的其他块也被一并跳过；现在只跳**那一块**。
        if (adjustment?.targetBlockId == block.id) continue;
        final move = drafts.forBlock(block.id);
        if (move == null) continue;
        final targetStartUtc = move.targetStartUtc;
        final target = targetStartUtc == null
            ? _sameLocalClockOn(move.localDate!, block.range, zones, timeZoneId)
            : TimeRange(
                startUtc: targetStartUtc,
                endUtc: targetStartUtc.add(block.range.duration),
              );
        if (target == null) continue;
        pinnedByBlockId[block.id] = PlannedBlock(
          id: block.id,
          taskId: block.taskId,
          range: target,
          // 输入侧一律标成锁定：只有这样才能保证本次生成不把它搬回去（见
          // `ScheduleProblem.pinnedUnlockedBlockIds` 的说明）。
          locked: true,
          explanationCode: 'manual_move',
        );
        if (!move.lock) pinnedUnlocked.add(block.id);
      }
    }

    // M4「跳过本次」（2026-10-07 用户定义）：把被跳过的块**从两处都排除**——
    // 它既不再被冻结（`lockedBlocks`），也不再作为"可移动的已确认块"（`existingBlocks`）。
    //
    // **这是"跳过"与"拖动"的分水岭**：拖动是"把这一块钉到别处"（进 `pinnedByBlockId`），
    // 跳过是"这一块这次不要了"，因此这里**不加任何钉住**，让它彻底消失。
    //
    // 注意**刻意不把旧时段标成禁区**：用户跳过的是"这件事现在不做"，
    // 不是"这段时间不许安排别的事"。把它锁成不可用会让"跳过之后空出来"
    // 变成"跳过之后白白浪费"，与用户要的第 1、3 条都相悖。
    final skips = pendingSkips;
    final skippedBlockIds = <String>{
      if (skips != null)
        for (final block in confirmedBlocks)
          if (skips.forBlock(block.id) != null) block.id,
    };

    // **调整前的参照**（1.8.0，规范 §11.4 第 3、4 条）：确认计划里每个块的开始时刻。
    //
    // 只收**已确认过的**块：新排进来的块没有"调整前"，把它的当前位置塞进去会让位移
    // 恒为 0，等于给自己发一张免罚单。被跳过的块也不收——它这一次不参与，谈不上移动。
    //
    // **在这里算好再传**，而不是把推导式直接写在构造参数里：参数出现在 `skippedBlockIds`
    // 之后，而推导式在参数位置求值——直接写会变成"引用了后面才声明的变量"（第一版如此，
    // analyzer 当场报 `referenced_before_declaration`）。
    final referenceBlocks = <String, DateTime>{
      for (final block in confirmedBlocks)
        if (schedulableIds.contains(block.taskId) &&
            !skippedBlockIds.contains(block.id))
          block.id: block.startUtc,
    };

    // ── 硬占用区间的**唯一来源**（用户第 65 轮复核第 3 条）────────────────────
    //
    // 同样两份区间既进 `ScheduleProblem`，也作为调整路径的硬障碍。
    // **刻意先算好再复用**，而不是在调整路径里另行展开一遍：
    // "引擎的硬约束"与"级联的硬约束"必须是**同一份口径**，
    // 否则会出现"引擎认可的方案被级联排到保护时间里"这类双重标准。
    //
    // **保护时间不进 `fixedIntervals`**（1.8.0，规范 §9.1）。它在数据里是与固定日程
    // 同形的日历事项（`CalendarEventKind.protected`），但排程语义完全不同：
    // 固定日程是"这段时间被占了"，保护时间是"这段时间不许安排"。混进固定日程的后果不是
    // 排错位置，而是**它会被当成固定日程投入进统计**——用户会看到"固定日程 8 小时/周"
    // 里有一半是"不许安排"的时间。
    //
    // 课表课程结束后留缓冲（用户 2026-10-08 需求）：把课的结束时间往后推
    // `courseTransitionMinutes`，于是那几分钟变成"被占用"，排程器不会把计划块紧贴在
    // 下课那一刻——用户上完课要离开教室，不可能直接接续。
    // 只对 `timetableImport` 来源的事件生效；自己建的会议不受影响（用户明确划的范围）。
    // 保护时间本来就是课表之外的来源，缓冲对它是空操作，但过滤要在前面做——
    // 顺序反了会把保护时间也做成带缓冲的固定占用。
    final fixedIntervalsWithTransition = [
      // 课程过渡按**事件结束日的规则**展开（计划 Task 2 Step 3）：
      // 一条课在周五 18:00 结束，它的缓冲应当用周五的 `courseTransitionMinutes`，
      // 而不是窗口首日（可能是周一）的那一份。
      //
      // **用 `endUtc` 而不是 `startUtc` 取那一天**：缓冲是"下课之后"的占用，
      // 约束它的是下课那一刻所在的那一天。跨午夜的课尤其明显——21:00 开始、次日
      // 01:00 结束，能决定它要不要留缓冲的是**次日**的规则。
      for (final occurrence in applyCourseTransitionByLocalDate(
        fixedOccurrences,
        transitionMinutesFor: (occurrence) =>
            _policyRulesOn(
              dailyPolicies,
              _localDateOf(occurrence.range.endUtc),
            )?.courseTransitionMinutes ??
            resolvedRules.courseTransitionMinutes,
      ))
        BusyInterval(id: occurrence.eventId, range: occurrence.range),
    ];
    // 规则型保护时间与睡眠都**按当天规则**展开（计划 Task 2 Step 3）：
    // "周末保护时间不同""周末睡眠不同"从此各自生效。
    final protectedFromRules = <BusyInterval>[
      for (final date in windowDates)
        ...protectedTimes.expand(
          rules: dailyPolicies[date]!.resolvedRules,
          startUtc: zones.localMidnightToUtc(date, timeZoneId),
          endUtc: zones.localMidnightToUtc(_nextLocalDate(date), timeZoneId),
          timeZoneId: timeZoneId,
        ),
    ];
    final sleepIntervals = <BusyInterval>[
      for (final date in windowDates)
        ...protectedTimes.sleep(
          rules: dailyPolicies[date]!.resolvedRules,
          startUtc: zones.localMidnightToUtc(date, timeZoneId),
          endUtc: zones.localMidnightToUtc(_nextLocalDate(date), timeZoneId),
          timeZoneId: timeZoneId,
        ),
    ];
    final protectedIntervalsAll = [
      // 规则来源的保护时间（午餐／晚餐／固定休息）……
      ...protectedFromRules,
      // ……加上用户在日历里自己建的一次性或按周重复的保护时间。
      //
      // **一次且仅一次**：`fixedOccurrences` 与 `protectedOccurrences` 是同一次
      // `occurrencesBetween` 按 `kind` 分出来的两份，互为补集，因此同一条记录不可能
      // 既进 fixed 又进 protected（规范 §8 审查问题 4）。
      for (final occurrence in protectedOccurrences)
        BusyInterval(id: occurrence.eventId, range: occurrence.range),
      // ……加上**睡眠**（用户第 65 轮复核第 3 条）。
      //
      // **它此前只存在于 `AvailabilityBuilder` 内部**：容量计算扣掉睡眠，
      // 但 `protectedIntervals` 里没有它，于是
      //   · `PlanValidator` 不会把"块压在睡眠上"报成冲突；
      //   · 调整路径的硬障碍集合里也没有睡眠。
      // 现在装配层按**逐日规则**展开一次，同一份结果同时进
      // `ScheduleProblem.protectedIntervals`（供校验与诊断）与
      // `AvailabilityInput.sleepIntervals`（供容量），容量与校验只有一个口径。
      ...sleepIntervals,
    ];

    // ── 调整路径：级联到位（裁定第 4 点；设计 §5.4）────────────────────────────
    //
    // 规范 §11.4 末段："先在当天做向后级联；当天放不下时才考虑后续日期。"
    // `localRepairCascade` 做的正是这件事：把目标块推到不早于下界，**只让开必要的块**，
    // 而不是重排一整天。
    //
    // **为什么必须在装配层算、并把结果当锁定块交给引擎**：引擎的放置是**任务级**的
    // （按任务剩余时长重新分块），它**没有"这一块就是上次那一块"的概念**。
    // 因此"目标块留在原位、只把它往后推"只能在装配层表达：算好位置之后以
    // `lockedBlocks` 交给引擎，引擎原样收下。
    //
    // **必须同时把它从 `existingBlocks` 里排除**，否则同一块会同时是"锁定在 A"
    // 与"可移动的 B"，引擎可能为它再排一条 —— 那就是"同一件工作排两次"。
    //
    // 级联当天不可行时**不假装成功**：不产出级联块，改由引擎按普通路径排
    // （可能落到后续日期），结果如实报给用户。
    //
    // 位置在 `schedulableIds`／`skippedBlockIds` 之后：三个都用得到。
    PlannedBlock? adjustedTarget;
    // 被本次调整**挤开**的块（位置变了）：它们也要以新位置带进计划，
    // 否则引擎会为它们的任务重新排位置（见下方注释）。
    final displaced = <PlannedBlock>[];
    final displacedIds = <String>{};
    final pendingAdjustment = adjustment;
    if (pendingAdjustment != null) {
      final bound = pendingAdjustment.notBeforeUtc;
      final target = confirmedBlocks
          .where((block) => block.id == pendingAdjustment.targetBlockId)
          .firstOrNull;
      if (target != null) {
        // **在多份合法方案里挑一份**（裁定"Task 13 的决定"第 2 点；设计 §5.5）：
        // `repairBestPlan` 生成有限、确定的候选锚点集合，逐个跑级联，
        // 再按规范 §11.4 的九级顺序比较（含第 6、7 级的坏空档）。
        //
        // 只用 `localRepairCascade` 的"最早可放"是贪心：它只看"我不撞谁"，
        // 不看"我这样放会在周围留下什么"——本批次实测过它会留下更大的缺口。
        //
        // **两处生产接线在复核时被发现是错的**（见 `defer_day_scope_test.dart`）：
        //
        // 1. 边界此前传的是**整个规划窗口**（默认 7 天），于是规范 §11.4 末段的
        //    "**先在当天做向后级联**"没有被执行——级联可以直接把目标块放到几天之后。
        //    现在走 `repairBestPlanDayScoped`：先按**目标块原位置所在的本地自然日**跑，
        //    当天不可行才放宽到窗口终点。
        // 2. `immovable` 此前传的是**空列表**。`localRepairCascade` 的 `firstFit` 只在
        //    `occupied` 里找冲突，而**固定日程与保护时间不在 `blocks` 里**，
        //    因此它们完全不参与避让——候选项可以直接落进固定日程，
        //    直到引擎的硬约束把它判掉（用户看到的是"预览里那块被拒了"）。
        //    现在把两类区间都作为**不可占用**传进去。
        final outcome = repairBestPlanDayScoped(
          targetBlockId: target.id,
          notBeforeUtc: bound,
          // **可移动输入**：只放"引擎/级联可以动"的块（用户第 65 轮复核第 1、4 条，
          // 1.8.0 冻结决策 §1.3 再收紧一次）。
          //
          // 修复前只排除了 `skippedBlockIds` 与 `pinnedByBlockId`，
          // **没有排除 `block.locked`**，也**没有排除已经过去的块**。
          // 而 `localRepairCascade` 只把 `immovable` 参数里的块当作不可移动 ——
          // 于是锁定块与过去的块都会被当成可移动，为了给目标让路而被搬走。
          //
          // 锁定块的语义就是"用户说了别动"；过去的块是**已经发生的事实**。
          // 两者都进入下面的硬占用集合，而不是可移动输入。
          //
          // **进行中的块也一并排除**（本轮新增）：它同样"已经开始了"，只是还没结束。
          // 判据因此是"**开始时刻不早于窗口起点**"，而不是"结束时刻晚于现在"：
          // 后者会把 `09:15–09:45`（进行中）当成可移动块，于是用户看到自己正在上的一节课
          // 被挪到下午（本轮红灯实测：`Expected 01:15Z / Actual 05:45Z`）。
          // 而**已经结束**的块连占用都不该算 —— 它在下界之前，不可能影响任何未来候选。
          blocks: [
            for (final block in confirmedBlocks)
              if (schedulableIds.contains(block.taskId) &&
                  !skippedBlockIds.contains(block.id) &&
                  !pinnedByBlockId.containsKey(block.id) &&
                  !block.locked &&
                  !block.startUtc.isBefore(nowUtc))
                block,
          ],
          // **统一的硬占用区间**（用户第 65 轮复核第 3 条）：
          // 级联不得把任何计划块放进去。此前只传了"日历里的固定日程 + 自定义保护时间"，
          // 漏掉了四类：
          //   1. 规则来源的保护时间（午餐／晚餐／固定休息）；
          //   2. 课程结束后的缓冲时间（`applyCourseTransition` 之后的固定日程）；
          //   3. **锁定块**（它们不是障碍，而是"不许动"的现有安排）；
          //   4. 已经过去的块。
          //
          // 前两类已经算在 `protectedIntervals` / 带缓冲的 `fixedIntervals` 里，
          // 因此这里直接复用**同一个来源**，避免第二套口径漂移。
          //
          // **第 4 类现在只保留"进行中"**（1.8.0 冻结决策 §1.3）：已经**结束**的块位于
          // 下界之前，不可能与任何未来候选重叠，把它塞进这个列表只会让障碍集合里
          // 多一条用不上的区间。因此判据从"在 now 之前结束"收紧为"跨过窗口起点"。
          immovable: [
            for (final interval in fixedIntervalsWithTransition)
              PlannedBlock(
                id: 'fixed:${interval.id}',
                taskId: '',
                range: interval.range,
                locked: true,
              ),
            for (final interval in protectedIntervalsAll)
              PlannedBlock(
                id: 'protected:${interval.id}',
                taskId: '',
                range: interval.range,
                locked: true,
              ),
            // 锁定块与**进行中**的块：位置冻结，作为占用参与避让。
            for (final block in confirmedBlocks)
              if (schedulableIds.contains(block.taskId) &&
                  !skippedBlockIds.contains(block.id) &&
                  (block.locked ||
                      (block.startUtc.isBefore(nowUtc) &&
                          block.endUtc.isAfter(nowUtc))))
                block,
          ],
          // "当天"＝目标块**调整前**所在的那个本地自然日（不是"今天"：
          // 用户对 10 月 14 日的块执行延后时，当天就是 14 日）。
          targetStartUtc: target.startUtc,
          timeZoneId: timeZoneId,
          zones: zones,
          planningEndUtc: endUtc,
          tasks: schedulable,
          reference: referenceBlocks,
          protectedRanges: [
            for (final occurrence in protectedOccurrences) occurrence.range,
          ],
          breakMinutes: resolvedRules.breakMinutes,
        );
        if (outcome.feasible) {
          final placed = outcome.blocks
              .where((block) => block.id == target.id)
              .firstOrNull;
          final confirmedStartById = {
            for (final block in confirmedBlocks) block.id: block.startUtc,
          };
          if (placed != null && !placed.startUtc.isBefore(bound)) {
            adjustedTarget = placed;
            // **被挤开的那一块也要带到位**（最后一处边界）。
            //
            // 目标块的新位置可能压到另一个已确认块上，级联会把它往后让开。
            // 若只把目标块带进 `lockedBlocks`，被让开的那一块就**不会被带进来**——
            // 引擎会为它的任务重新排一个位置（可能排到别处），
            // 用户看到的是"我延后了一块，另一块却跑掉了"。
            //
            // 因此凡是**位置发生了变化**的块都一并带进来，各就各位。
            // 判据用"位置变了"而不是"在 `movedBlockIds` 里"：
            // 后者由方案比较得出，而这里要的是"这块不在原位了"这个事实。
            for (final block in outcome.blocks) {
              if (block.id == target.id) continue;
              final original = confirmedStartById[block.id];
              if (original == null || original == block.startUtc) continue;
              displaced.add(block);
              displacedIds.add(block.id);
            }
          }
        }
      }
    }

    // ── 块的角色划分：**一个 ID 只能有一个角色**（用户第 67 轮独立核验）──────
    //
    // 缺陷：`lockedBlocks` 先按 `block.locked` 加入锁定块，随后"未被本次调整碰到
    // ⇒ 原位冻结"那一段**没有排除 `locked`**，于是同一个锁定块被加了两次；
    // 而 `existingBlocks` 也仍然收着它（既冻结又可移动）。
    // 实测坏输出：`b-locked@09:00` 在最终提案里出现两次。
    //
    // 现在把"哪些块由本次调整接管"**先算出来**，三处消费同一份结果：
    //   ① 锁定（`block.locked`）—— 用户说了别动；
    //   ② 钉住（`pinnedByBlockId`）—— 手动拖动后选择"不锁定"；
    //   ③ 调整目标（`adjustedTarget`）—— 本次延后的主角；
    //   ④ 被挤开（`displaced`）—— 给目标让路的块；
    //   ⑤ 原位冻结（`frozenIds`）—— 未被本次调整碰到的确认块。
    //
    // **只有调整成功时才冻结**（用户第 67 轮第 4 条）：`adjustedTarget == null`
    // 表示级联当天不可行（回退路径），此时**不能**把目标块也冻结在原位，
    // 否则延后彻底失效——用户点了延后却什么都没变。
    // **分类交给纯函数**（用户第 70 轮）：把"一个块只能有一个角色"这条规则
    // 集中到 `classifyConfirmedBlocks`，由它的单元测试负责证明分类正确，
    // 端到端用例负责证明**这里确实用了它**。
    //
    // 此前这段逻辑散在几个 `if` 里，于是"锁定块未排除"这类重叠只能靠人眼发现 ——
    // 第 67 轮的重复缺陷正是这么漏出去的。
    final partition = classifyConfirmedBlocks(
      confirmed: confirmedBlocks,
      schedulableTaskIds: schedulableIds,
      skippedBlockIds: skippedBlockIds,
      pinnedBlockIds: {for (final block in pinnedByBlockId.values) block.id},
      adjustedTargetId: adjustedTarget?.id,
      adjustmentRequested: adjustment != null,
      displacedIds: displacedIds,
      // **同一个边界**：规划窗口起点。此前传的是 `nowUtc`，与窗口起点在
      // "向上取整到粒度"之后可能相差几分钟，于是"历史"与"未来"的分界
      // 与校验器用的分界不是同一条（1.8.0 冻结决策 §1.3）。
      planningWindowStartUtc: startUtc,
    );
    final frozenIds = partition.frozenIds;
    // 按 ID 去重（**互斥分区之外的第二道防线**）：即使上游将来重复提供同一块，
    // 也不会让同一个 ID 出现在结果里两次。
    List<PlannedBlock> dedupe(Iterable<PlannedBlock> blocks, Set<String> seen) {
      final out = <PlannedBlock>[];
      for (final block in blocks) {
        if (!seen.add(block.id)) continue;
        out.add(block);
      }
      return out;
    }

    final claimedIds = <String>{};
    final lockedBlocksOut = dedupe([
      ...partition.hardOccupiedIds.map(
        (id) => confirmedBlocks.firstWhere((block) => block.id == id),
      ),
      ...pinnedByBlockId.values,
      ?adjustedTarget,
      ...displaced,
      for (final block in confirmedBlocks)
        if (frozenIds.contains(block.id)) block,
    ], claimedIds);
    final existingBlocksOut = dedupe([
      for (final block in confirmedBlocks)
        if (partition.existingIds.contains(block.id)) block,
    ], claimedIds);

    final problem = ScheduleProblem(
      planningWindow: TimeRange(startUtc: startUtc, endUtc: endUtc),
      timeZoneId: timeZoneId,
      // **任务照旧留在 `tasks` 里**：跳过只放弃块，任务仍是未完成待办、继续参与重排。
      // 剩余时长也不在这里动——已专注的部分由既有的专注重算扣减，不重算。
      tasks: schedulable,
      fixedIntervals: fixedIntervalsWithTransition,
      protectedIntervals: protectedIntervalsAll,
      lockedBlocks: lockedBlocksOut,
      // 已确认但未锁定的块：引擎可以移动，但要付出移动代价（设计 §5.4）。
      existingBlocks: existingBlocksOut,
      rules: resolvedRules,
      // **逐日规则是算法 17 的核心输入**（计划 Task 2 Step 3/4）：窗口涉及的每一天
      // 带走自己那一份完整规则，因此睡眠、保护时间、精力、每日上限、粒度、休息与
      // 课程过渡都不再取窗口首日。`resolvedRules` 只留作旧接口兼容快照与任务默认值来源。
      dailyPolicies: dailyPolicies,
      weeklyLifeQuotaByWeekStart: weeklyLifeQuotaByWeekStart,
      preferences: const PreferenceProfile(),
      inputHash: '',
      pinnedUnlockedBlockIds: pinnedUnlocked,
      referenceBlocks: referenceBlocks,
      // 块级调整上下文（裁定第 3 点）：延后经它进入引擎，而不是折算成任务级下界。
      adjustment: adjustment,
      // 当前确认计划里的块（裁定第 1、4 点）：生成**之后**用它建立来源关联，
      // 好让预览把"同一块换了时间"报成「移动」而不是删除＋新增。
      confirmedBlocks: confirmedBlocks,
      // 准入期就判定为阻断的输入错误（§1.7）：它们不进 `tasks`，但必须走到预览。
      admissionConflicts: admissionConflicts,
    );
    // **装配层用 `TimeZoneDatabase` 证明逐日策略精确覆盖窗口**（计划 Task 2 Step 4）：
    // "覆盖窗口涉及的每一个本地日期"这件事需要时区换算，因此它不能伪装成
    // `ScheduleProblem` 值对象自身的校验（那个类刻意不持有 `TimeZoneDatabase`）。
    _assertDailyPoliciesCoverWindow(
      problem: problem,
      zones: zones,
      timeZoneId: timeZoneId,
    );
    // **软恢复余量按当天的许可容量赋值**（算法 17，计划 §3.7 / Task 3）。
    //
    // 这一步必须在 `problem` 构造**之后**：许可容量 = `min(日硬空闲, 当日上限)`，
    // 而"日硬空闲"要由 `AvailabilityBuilder` 从**同一份**装配好的占用事实算出来。
    // 因此这里先构造问题、再用问题自身的逐日策略跑一次可用时间分析，
    // 由 `buildDayCapacityLedger` 给出许可容量。
    //
    // **它只影响软目标**：恢复余量不进任何硬判定，也不是可用容量的一部分
    // （计划 §3.7 明确"不从可用容量中硬扣除"）。
    final pricedProblem = withSoftReserveTargets(
      problem: problem,
      zones: zones,
    );

    return withCurrentInputHash(pricedProblem, snapshots);
  }

  /// 按**调整自己的基线**装配排程输入（计划 Task 5 Step 4）。
  ///
  /// 三条纪律：
  /// 1. 读的是 adjustment 保存的 `basePlanVersionId`，并且**当前计划必须仍是它**；
  ///    版本已切换时返回 `basePlanChanged`，绝不在新计划上"接着延后"。
  /// 2. 窗口至少覆盖 `adjustmentWindowEnd`；
  /// 3. 只给目标块一个 `notBeforeUtc` 下界，绝不改写任务级 `availableFromUtc`。
  @override
  Future<ScheduleProblem> loadForAdjustment({
    required PlanAdjustmentToken token,
    required DateTime windowEndUtc,
  }) async {
    final repository = adjustments;
    if (repository == null) {
      throw StateError('loadForAdjustment 需要装配 PlanAdjustmentRepository。');
    }
    final adjustment = await repository.byId(token.adjustmentId);
    if (adjustment == null ||
        adjustment.revision != token.revision ||
        adjustment.basePlanVersionId != token.basePlanVersionId) {
      throw const AdjustmentSourceException(
        PlanAdjustmentFailureCode.tokenMismatch,
      );
    }
    final confirmed = await plans.current();
    if (confirmed == null || confirmed.id != adjustment.basePlanVersionId) {
      throw const AdjustmentSourceException(
        PlanAdjustmentFailureCode.basePlanChanged,
      );
    }
    final target = confirmed.blocks
        .where((block) => block.id == adjustment.targetBlockId)
        .firstOrNull;
    if (target == null) {
      throw const AdjustmentSourceException(
        PlanAdjustmentFailureCode.targetMissing,
      );
    }
    return load(
      adjustmentContext: BlockAdjustmentContext(
        targetBlockId: target.id,
        notBeforeUtc: adjustment.notBeforeUtc,
        kind: BlockAdjustmentKind.defer,
      ),
      windowEndUtc: windowEndUtc,
    );
  }

  /// 为 [problem] 的每一天算出**软恢复余量目标**并返回一个新问题
  /// （算法 17，计划 §3.7 / Task 3）。
  ///
  /// ## 为什么是"先构造问题、再定价"
  ///
  /// 恢复余量的目标是 `min(30, floor(许可容量 × 10% / 粒度) × 粒度)`，而**许可容量**
  /// 是 `min(日硬空闲, 当日可移动上限)`——它需要 `AvailabilityBuilder` 从装配好的
  /// 占用事实算出来，而那些事实正是 `problem` 自己携带的。因此顺序只能是：
  /// 构造问题 → 用它算账本 → 把余量写回逐日策略。
  ///
  /// ## 为什么只改 `softReserveTargetMinutes`
  ///
  /// 计划 §3.7 明确恢复余量是**软目标**、不从可用容量里硬扣。因此这里只替换
  /// `DailySchedulingPolicy.softReserveTargetMinutes`，**逐值保留** `resolvedRules`：
  /// 任何一条"顺手也改一下规则"的写法都会让"装配层解析的规则"与"引擎看到的规则"
  /// 变成两份。
  ScheduleProblem withSoftReserveTargets({
    required ScheduleProblem problem,
    required TimeZoneDatabase zones,
  }) {
    final builder = AvailabilityBuilder(zones);
    final availability = builder.analyze(
      AvailabilityInput(
        planningWindow: problem.planningWindow,
        timeZoneId: problem.timeZoneId,
        rules: problem.rules,
        dailyPolicies: problem.dailyPolicies,
        fixedIntervals: [
          for (final interval in problem.fixedIntervals) interval.range,
        ],
        protectedIntervals: [
          for (final interval in problem.protectedIntervals) interval.range,
        ],
        // 睡眠由分析层按**逐日策略**展开，因此这里不重复提供；
        // 装配层把睡眠留在 `protectedIntervals` 里是为了 `PlanValidator`。
        lockedBlocks: [for (final block in problem.lockedBlocks) block.range],
        chargedMovableBlocks: [
          for (final block in problem.lockedBlocks)
            if (problem.pinnedUnlockedBlockIds.contains(block.id)) block.range,
        ],
      ),
    );
    final ledger = buildDayCapacityLedger(
      problem: problem,
      availability: availability,
      baselineBlocks: problem.lockedBlocks,
      zones: zones,
    );

    // **只替换逐日策略里的恢复余量**，其余字段由 `withInputHash` 这一处
    // 逐值搬运（`planning_service.dart` 的说明记着"忘了搬运新字段"这个反复踩到的陷阱）。
    return withInputHash(
      problem,
      problem.inputHash,
      dailyPolicies: {
        for (final entry in problem.dailyPolicies.entries)
          entry.key: DailySchedulingPolicy(
            localDate: entry.key,
            resolvedRules: entry.value.resolvedRules,
            softReserveTargetMinutes: softReserveTargetOf(
              ledger: ledger,
              localDate: entry.key,
              // 粒度来自**这一天自己的**规则，而不是窗口首日。
              granularityMinutes: entry.value.resolvedRules.granularityMinutes,
            ),
          ),
      },
    );
  }

  /// 该日应当先作为软目标保留的恢复余量分钟。
  ///
  /// 公式只有一处实现（`softReserveTargetFor`）；本函数只负责把"当天的许可容量"
  /// 从账本里取出来，并按**当天自己的**粒度向下取整。
  ///
  /// **账本缺日时抛 [StateError]**——缺日意味着装配不变量已经破坏，
  /// 静默返回 0 会把一个装配缺陷伪装成"这一天不需要余量"。
  int softReserveTargetOf({
    required DayCapacityLedger ledger,
    required DateTime localDate,
    required int granularityMinutes,
  }) => softReserveTargetForSnapshot(
    ledger.forDate(localDate),
    granularityMinutes,
  );

  /// 该事件结束时刻所属的**本地日期**（逐日策略的查阅键）。
  DateTime _localDateOf(DateTime instantUtc) {
    final local = zones.toLocal(instantUtc, timeZoneId);
    return DateTime(local.year, local.month, local.day);
  }

  /// 为规划窗口涉及的每一个本地日期解析一份**完整**规则，并算出逐周生活配额
  /// （计划 Task 2 Step 3/4）。
  ///
  /// ## 为什么范围要向前补齐到首个本地周一
  ///
  /// 周生活配额按"每个块所属本地周"计算，而窗口起点常常落在周中（用户下午三点
  /// 生成计划，周一那半周已经在窗口之外）。若只解析窗口内的日期，那一周的周一就没有
  /// 解析结果，`lifeQuotaForLocalWeek` 会抛 [StateError]——**这是有意的**：
  /// 生活类任务的目标不该因为"这一周从周三才开始"而退回一个默认值。
  ///
  /// 补齐只影响 [DailyRulesForWindow.rulesByDate]；对外暴露的
  /// [DailyRulesForWindow.policies] 仍然**只含窗口日期**（计划 §6 末条）。
  Future<DailyRulesForWindow> _dailyPoliciesFor({
    required DateTime startUtc,
    required DateTime endUtc,
    required ScheduleRuleOverride? override,
  }) async {
    final windowDates = _enumerateLocalDates(
      zones,
      startUtc,
      endUtc,
      timeZoneId,
    );
    if (windowDates.isEmpty) {
      throw StateError('规划窗口没有覆盖任何本地日期，无法装配逐日规则');
    }
    final weeklyQuotaStart = _mondayOf(windowDates.first);
    final rulesByDate = await rules.resolveByDateForWindow(
      weeklyQuotaStart,
      windowDates.last,
      override: override,
    );

    final weeklyLifeQuota = <DateTime, int>{};
    for (
      var date = weeklyQuotaStart;
      !date.isAfter(windowDates.last);
      date = _nextLocalDate(date)
    ) {
      if (date.weekday != DateTime.monday) continue;
      weeklyLifeQuota[date] = _requireRulesFor(
        rulesByDate,
        date,
      ).weeklyLifeQuotaMinutes;
    }

    // **恢复余量的输入是当天的许可容量**，而许可容量要等 `AvailabilityAnalysis`
    // 与基线块放到一起才算得出来（`min(硬空闲, 每日上限)`，见 `day_capacity_ledger.dart`）。
    // 装配阶段还没有那份分析，因此先在 [DailyRulesForWindow] 里带上窗口日期，
    // 由 `load()` 用 [withSoftReserveTargets] 逐日填上——**公式只有一处实现**
    // （`softReserveTargetFor`），装配层不自己推一遍（计划 §3.7）。
    final policies = <DateTime, DailySchedulingPolicy>{
      for (final date in windowDates)
        date: DailySchedulingPolicy(
          localDate: date,
          resolvedRules: _requireRulesFor(rulesByDate, date),
          softReserveTargetMinutes: 0,
        ),
    };
    return DailyRulesForWindow(
      windowDates: windowDates,
      rulesByDate: rulesByDate,
      policies: policies,
      weeklyLifeQuota: weeklyLifeQuota,
    );
  }

  /// [date] 当天的规则；该日不在窗口内时返回 `null`（调用方回退到窗口快照）。
  ///
  /// **只用于"事件落在窗口外"这种边界**：窗口内的日期一定在
  /// `dailyPolicies` 里（由 `_assertDailyPoliciesCoverWindow` 证明）。
  /// 事件本身不受窗口限制（`occurrencesBetween` 从当天本地午夜读起），
  /// 因此它的结束日有可能落在窗口最后一天之后。
  PlanningRules? _policyRulesOn(
    Map<DateTime, DailySchedulingPolicy> policies,
    DateTime date,
  ) => policies[date]?.resolvedRules;

  /// 一次反查这批 open task 里哪些是**已生成的周期实例**，返回 `taskId → cycle`。
  ///
  /// **为什么要批量而不是逐任务查**（计划 §2.2）：`openTasks` 的长度随用户任务数增长，
  /// 逐任务调用 `findCycleByTaskId` 是典型的 N+1；更要紧的是，把"哪些 open task 是周期
  /// 实例"这件事散进调用方的循环，就等于允许调用方**只处理其中一部分**——修复前的缺陷
  /// 正是如此：只把"本周实例"从普通输入里换掉，`ensureCycles` 为滚动七天补出来的
  /// **下周实例**因此留在普通输入里，成为本次窗口根本不覆盖的幽灵任务。
  ///
  /// 拿到的映射**覆盖全部实例**：无论它是本周、下周、跨时区边界还是异常遗留，
  /// 都先从普通输入里剥离，再由 [recurringSchedulableTasks] 决定是否加回。
  ///
  /// 没有周期服务（`recurring == null`）时返回空表：那种装配下周期实例本来就是普通任务。
  Future<Map<String, RecurringTaskCycle>> _cyclesByTaskId(
    Iterable<String> openTaskIds,
  ) async {
    final service = recurring;
    if (service == null) return const {};
    final ids = openTaskIds.toSet();
    if (ids.isEmpty) return const {};
    final cycles = await service.repository.findCyclesByTaskIds(ids);
    return {for (final cycle in cycles) cycle.taskId: cycle};
  }

  /// 收集窗口内**参与排程**的周期实例及其本周视角。
  ///
  /// 三个过滤各自都有理由：
  /// - 没有实例的模板跳过（还没到开始日／已归档）；
  /// - 暂停期内的跳过（§3.3：暂停期间不生成，自然也不安排）；
  /// - 剩余为 0 的跳过（已达标）：继续送进去会让引擎为一件已经做完的事占位。
  ///
  /// ## 为什么读之前要先补生成（用户 2026-10-08 实测报告）
  ///
  /// 用户报告："保存周期任务后重新规划，计划里不显示它。"
  ///
  /// 根因是**生成只在启动时跑过一次**（`main.dart` 里那个 `unawaited(ensureCycles)`），
  /// 而这里原先只**读**实例、读到 `null` 就 `continue`。于是**会话中途**新建的周期目标当周
  /// 没有任何实例，被静默跳过，计划里自然不出现——用户必须重启程序才能看到它，而界面上
  /// 没有任何提示说"重启一下"。这属于"操作完成了但结果要重启才生效"，是最难自查的一类缺陷。
  ///
  /// 修法不是"创建模板时立刻生成实例"——`recurring_task_service.dart` 的注释明确说明生成是
  /// 一条**独立且幂等**的路径，刻意不在创建时发生（模板可以先建、下周一才生效）。因此正确
  /// 的处置是**让读路径自己补齐**：在读取之前，先把与排程同形的窗口生成出来。
  ///
  /// **这是安全的，因为生成是幂等的**：`(模板, 周)` 是联合主键，重复调用只会回读先到的那一行。
  /// 代价是每次 `load()` 多一次"这一周有没有实例"的检查——相对一次排程可以忽略，
  /// 而换来的是"任何时刻生成计划都能看到刚建的周期目标"。
  Future<List<RecurringScheduleInput>> _recurringInputs(DateTime nowUtc) async {
    final service = recurring;
    if (service == null) return const [];
    final templates = await service.repository.listTemplates(
      includeArchived: false,
    );
    if (templates.isEmpty) return const [];
    // 与排程窗口同形的滚动七天：跨周不重启也会在下次生成计划时补齐。
    // 结算排在生成之前（`ensureCycles` 内部保证顺序），因此结转读得到上一周的真实状态。
    final run = await service.ensureCycles(
      TimeRange(startUtc: nowUtc, endUtc: nowUtc.add(const Duration(days: 7))),
      nowUtc,
    );
    final inputs = <RecurringScheduleInput>[];
    final templatesById = {
      for (final template in templates) template.id: template,
    };
    for (final cycle in run.cycles) {
      final template = templatesById[cycle.templateId];
      if (template == null || cycle.status.isSettled) continue;
      final period = WeeklyPeriod.startingAt(
        cycle.periodStartLocalDate,
        service.timeZoneId,
        service.zones,
      );
      final progress = await service.progressForCycle(
        template.id,
        period.startLocalDate,
      );
      if (progress.remainingMinutes <= 0) continue;
      final snapshot = await recurringSnapshots?.findCycleSnapshot(
        '${template.id}:${formatLocalDate(period.startLocalDate)}',
      );
      final effectiveTemplate = snapshot == null
          ? template
          : template.copyWith(
              title: snapshot.title,
              targetMinutes: snapshot.targetMinutes,
              priority: snapshot.priority,
              energyLevel: snapshot.energyLevel,
              splitMode: snapshot.splitMode,
              minChunkMinutes: snapshot.minChunkMinutes,
              maxChunkMinutes: snapshot.maxChunkMinutes,
              preferredStartMinute: snapshot.preferredStartMinute,
              preferredEndMinute: snapshot.preferredEndMinute,
              pace: snapshot.pace,
              allowedWeekdaysMask: snapshot.allowedWeekdaysMask,
            );
      final planningStart = [
        nowUtc,
        period.startUtc,
        if (snapshot != null) snapshot.effectiveStartUtc,
        if (template.pausedUntilLocalDate != null)
          service.zones.localMidnightToUtc(
            shiftLocalDate(template.pausedUntilLocalDate!, 1),
            service.timeZoneId,
          ),
      ].reduce((a, b) => a.isAfter(b) ? a : b);
      final deadline = snapshot?.effectiveEndUtc ?? period.endUtc;
      if (!planningStart.isBefore(deadline)) continue;
      inputs.add(
        RecurringScheduleInput(
          template: effectiveTemplate,
          cycle: cycle,
          progress: progress,
          period: period,
          planningStartUtc: planningStart,
          effectiveEndUtc: snapshot?.effectiveEndUtc,
        ),
      );
    }
    // **按模板 id 排序**：结果不得依赖数据库返回顺序（§7.2 最后一条）。这里排一次，
    // 引擎内部的 `_compareTasks` 再排一次，两道都不依赖顺序。
    inputs.sort((a, b) => a.template.id.compareTo(b.template.id));
    return inputs;
  }

  /// 用周期剩余区间的硬约束容量计算 `targetNow`（Task 10）。
  ///
  /// `visibleWindow` 是当前计划窗口与周期剩余区间的交集；`C_after` 是交集之后到周期结束的
  /// 合法容量。当前周通常 `C_after = 0`，因此退回整个剩余量；下周实例只先承担可见部分的份额。
  RecurringScheduleInput _paceInput(
    RecurringScheduleInput input,
    List<TimeRange> busyIntervals,
    DateTime nowUtc,
    DateTime planningEndUtc,
    int maxMinutesPerDay,
  ) {
    final cycleStart = input.planningStartUtc;
    final cycleEnd = input.deadlineUtc;
    if (!cycleEnd.isAfter(cycleStart)) return input;
    final visibleStart = cycleStart.isAfter(nowUtc) ? cycleStart : nowUtc;
    final visibleEnd = cycleEnd.isBefore(planningEndUtc)
        ? cycleEnd
        : planningEndUtc;
    if (!visibleEnd.isAfter(visibleStart)) return input;
    final curve = curveForPace(input.template.pace);
    final decision = recurringPaceForCycle(
      remainingMinutes: input.progress.remainingMinutes,
      cycleRange: TimeRange(startUtc: cycleStart, endUtc: cycleEnd),
      visibleWindow: TimeRange(startUtc: visibleStart, endUtc: visibleEnd),
      busyIntervals: busyIntervals,
      minChunkMinutes: input.template.minChunkMinutes,
      curve: curve,
      zones: zones,
      timeZoneId: timeZoneId,
      maxMinutesPerDay: maxMinutesPerDay,
    );
    return input.withTargetNow(decision.targetNowMinutes);
  }
}

/// 周期目标实例的排程输入（M6，路线图 §3.4 / §11 Task 8）。
///
/// **它把"这一周该做多少"翻译成一件普通任务，而不是另写一个排程器**：周期实例在生成时
/// 就已经是一件普通任务（见 `RecurringTaskService._taskFor`），这里补的是三件只有排程层
/// 才知道的事：
///
/// ① **截止时间＝这一周的结束**（选了 `early` 就提前）。引擎自带的
///    `PressureCalculator` 会按"本周剩余容量 ÷ 到截止为止的总容量"算出本周该推进多少，
///    因此"均匀分布不会把 180 分钟全堆到周日"（§7.2）**不需要新算法**，只需要把正确的
///    截止时间交进去。
/// ② **允许星期**（`selectedWeekdays`）：拆成"每一天一个窗口"，每个窗口的截止时间就是
///    那一天的结束。**没有新的约束类型**——引擎本来就用 `dueAtUtc` 与 `availableFromUtc`
///    夹住候选，因此这一条只是把"仅周三"表达成"周三 00:00 到周四 00:00 之间、且周四
///    00:00 前必须做完"。
/// ③ **只送还差的部分**（已完成 80 / 目标 180 ⇒ 只送 100，§7.2 第二条）。
///
/// **绝不触碰保护时间**：这里只产出任务与截止时间；保护时间由 `protectedTimes.expand`
/// 独立产出，两者在 `ScheduleProblem` 里各占一个字段。容量不够时引擎返回
/// `unscheduled` 与 `insufficientCapacity` 冲突，缺口由 `CapacityShortfall` 汇报。
final class RecurringScheduleInput {
  const RecurringScheduleInput({
    required this.template,
    required this.cycle,
    required this.progress,
    required this.period,
    required this.planningStartUtc,
    this.effectiveEndUtc,
    this.targetNowMinutes,
  });

  final RecurringTaskTemplate template;
  final RecurringTaskCycle cycle;
  final RecurringProgress progress;
  final WeeklyPeriod period;
  final DateTime planningStartUtc;
  final DateTime? effectiveEndUtc;

  /// 按整周容量算出的“现在应完成”的累计分钟；为空时退回整个剩余量。
  final int? targetNowMinutes;

  RecurringScheduleInput withTargetNow(int? value) => RecurringScheduleInput(
    template: template,
    cycle: cycle,
    progress: progress,
    period: period,
    planningStartUtc: planningStartUtc,
    effectiveEndUtc: effectiveEndUtc,
    targetNowMinutes: value,
  );

  DateTime get deadlineUtc => effectiveEndUtc ?? period.endUtc;
}

/// 把一个周期实例展开成排程输入（见 [RecurringScheduleInput] 的说明）。
///
/// 单独抽成顶层函数是为了能**脱离数据库**测试：§11 Task 8 的三条验收（均匀分布、不依赖
/// 返回顺序、精确缺口）都可以直接在纯函数层面钉住，而真实库只用来验证接线。
List<SchedulableTask> recurringSchedulableTasks({
  required RecurringScheduleInput input,
  required TimeZoneDatabase zones,
}) {
  final remaining = input.progress.remainingMinutes;
  if (remaining <= 0) return const [];
  // 已跳过的这一周**不产生任何排程输入**：跳过是"这周不想做"，继续安排会与用户的动作相悖。
  if (input.cycle.status == RecurringCycleStatus.skipped) return const [];
  final targetNow = input.targetNowMinutes;
  final required = targetNow == null
      ? remaining
      : (targetNow - input.progress.recordedMinutes).clamp(0, remaining);
  if (required <= 0) return const [];
  final template = input.template;

  SchedulableTask base({
    required int requiredMinutes,
    required DateTime? dueAtUtc,
    required DateTime? availableFromUtc,
    int allowedWeekdaysMask = recurringAllWeekdaysMask,
    TaskDistributionPolicy distributionPolicy =
        TaskDistributionPolicy.unconstrained,
  }) => SchedulableTask(
    id: input.cycle.taskId,
    requiredMinutes: requiredMinutes,
    splitMode: template.splitMode,
    minChunkMinutes: template.minChunkMinutes,
    maxChunkMinutes: template.maxChunkMinutes,
    dueAtUtc: dueAtUtc,
    availableFromUtc: availableFromUtc,
    priority: template.priority,
    energyLevel: template.energyLevel,
    preferredWindow: template.preferredWindow,
    allowedWeekdaysMask: allowedWeekdaysMask,
    distributionPolicy: distributionPolicy,
    preferLater: template.pace == RecurringPace.deadlineWeighted,
  );

  // ── 节奏 → 排程策略（1.7.1 计划 Task 5 Step 1/2）─────────────────────────────
  //
  // `even` 与 `selectedWeekdays` 都映射为 `TaskDistributionPolicy.even`：前者的"均匀"是
  // 跨全部允许星期，后者的"均匀"是**先按星期掩码过滤日期、再在被选日期间均分**
  // （计划 §3.4）。两者都由均分器按容量摊。
  //
  // **不再计算 `maxMinutesPerLocalDay`**。此前 `_dailyQuota()` 用"剩余分钟 ÷ 剩余可用星期数"
  // 算一个统一上限，再由引擎在"第一轮守配额、第二轮全局放开"里使用——第二轮是全局解禁，
  // 它把一天堆到 125 分钟（计划 §2.1）。现在每日预算由均分器按**真实容量**算出，且事后重分
  // 只发生在还有余量的日期之间。
  //
  // `early` 与 `deadlineWeighted` 保持 `unconstrained`：它们表达的是"什么时候做完"，
  // 不是"每天做多少"。
  switch (template.pace) {
    case RecurringPace.even:
      return [
        base(
          requiredMinutes: required,
          dueAtUtc: input.deadlineUtc,
          availableFromUtc: null,
          distributionPolicy: TaskDistributionPolicy.even,
        ),
      ];
    case RecurringPace.deadlineWeighted:
      return [
        base(
          requiredMinutes: required,
          dueAtUtc: input.deadlineUtc,
          availableFromUtc: null,
        ),
      ];
    case RecurringPace.early:
      // **尽早完成**：把截止时间提前到"本周开始 + 2 天"（不早于窗口终点时才提前），
      // 于是同一个 `PressureCalculator` 会算出更高的近期推进量。窗口不足两天时保持原样。
      final earlyDue = input.planningStartUtc.add(const Duration(days: 2));
      return [
        base(
          requiredMinutes: required,
          dueAtUtc: earlyDue.isBefore(input.deadlineUtc)
              ? earlyDue
              : input.deadlineUtc,
          availableFromUtc: null,
        ),
      ];
    case RecurringPace.selectedWeekdays:
      final weekdays = template.allowedWeekdays;
      final mask = weekdayMaskOf(weekdays);
      return [
        base(
          requiredMinutes: required,
          dueAtUtc: input.deadlineUtc,
          availableFromUtc: input.planningStartUtc,
          allowedWeekdaysMask: mask,
          distributionPolicy: TaskDistributionPolicy.even,
        ),
      ];
  }
}

/// 把 [original] 的区间搬到 [targetLocalDate] 的同一天，**保留原来的本地钟点与时长**。
///
/// 返回 `null` 表示搬不过去（目标日期非法），此时调用方应当**跳过这条意图**而不是钉一个
/// 猜测出来的时间——钉错位置比不钉更难发现。
TimeRange? _sameLocalClockOn(
  DateTime targetLocalDate,
  TimeRange original,
  TimeZoneDatabase zones,
  String timeZoneId,
) {
  final localStart = zones.toLocal(original.startUtc, timeZoneId);
  final startMinute = localStart.hour * 60 + localStart.minute;
  final day = DateTime(
    targetLocalDate.year,
    targetLocalDate.month,
    targetLocalDate.day,
  );
  if (day.month != targetLocalDate.month || day.day != targetLocalDate.day) {
    return null;
  }
  final startUtc = zones.localDateTimeToUtc(day, startMinute, timeZoneId);
  return TimeRange(
    startUtc: startUtc,
    endUtc: startUtc.add(Duration(minutes: original.durationMinutes)),
  );
}

/// [RepositoryScheduleProblemSource._dailyPoliciesFor] 的结果。
///
/// 单独一个类型而不是一个 Record：四个字段里有三个是"同一次解析的不同切片"，
/// 用一个有名字的类型能让"哪些是窗口内的、哪些是补齐出来的"在类型层面可读。
///
/// - [windowDates]：窗口覆盖的本地日期，升序；
/// - [rulesByDate]：**补齐到首个周一**之后的逐日解析结果（范围大于 [windowDates]）；
/// - [policies]：**只含窗口日期**的逐日策略；
/// - [weeklyLifeQuota]：窗口涉及的每个本地周一的生活配额。
final class DailyRulesForWindow {
  DailyRulesForWindow({
    required List<DateTime> windowDates,
    required Map<DateTime, PlanningRules> rulesByDate,
    required Map<DateTime, DailySchedulingPolicy> policies,
    required Map<DateTime, int> weeklyLifeQuota,
  }) : windowDates = List.unmodifiable(windowDates),
       rulesByDate = Map.unmodifiable(rulesByDate),
       policies = Map.unmodifiable(policies),
       weeklyLifeQuota = Map.unmodifiable(weeklyLifeQuota);

  final List<DateTime> windowDates;
  final Map<DateTime, PlanningRules> rulesByDate;
  final Map<DateTime, DailySchedulingPolicy> policies;
  final Map<DateTime, int> weeklyLifeQuota;
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 下一个**本地自然日**（按日历进位，不按绝对 24 小时）。
DateTime _nextLocalDate(DateTime date) =>
    DateTime(date.year, date.month, date.day + 1);

/// [date] 所在本地周的周一。
DateTime _mondayOf(DateTime date) =>
    DateTime(date.year, date.month, date.day - (date.weekday - 1));

/// 逐日解析结果里必须存在 [date] 这一天，否则装配不变量已经破坏。
PlanningRules _requireRulesFor(
  Map<DateTime, PlanningRules> rulesByDate,
  DateTime date,
) {
  final rules = rulesByDate[date];
  if (rules == null) {
    throw StateError(
      '逐日规则缺少本地日期 ${date.year}-${date.month}-${date.day} 的解析结果；'
      '装配层必须为窗口涉及的每一个本地日期解析规则，不得回退到窗口首日',
    );
  }
  return rules;
}

/// 枚举**规划窗口覆盖到的本地日期**，按升序。
///
/// **不能用"UTC 每 24 小时递增"**（计划 Task 2 Step 4）：窗口落在 DST 切换日时，
/// UTC 推进 24 小时会得到重复的本地日或跳过一天。正确的做法是先取窗口起点与
/// 终点（减一微秒，让"终点是本地午夜"这种半开区间的形状被正确归到最后一天）的
/// 本地日期，再按日历日逐个推进。
List<DateTime> _enumerateLocalDates(
  TimeZoneDatabase zones,
  DateTime startUtc,
  DateTime endUtc,
  String timeZoneId,
) {
  final first = _dateOnly(zones.toLocal(startUtc, timeZoneId));
  final last = _dateOnly(
    zones.toLocal(endUtc.subtract(const Duration(microseconds: 1)), timeZoneId),
  );
  final dates = <DateTime>[];
  for (var date = first; !date.isAfter(last); date = _nextLocalDate(date)) {
    dates.add(date);
  }
  return dates;
}

/// 证明逐日策略的键集合与"窗口涉及的本地日期"**逐值相等**（计划 Task 2 Step 4）。
///
/// 多一天与少一天都是装配缺陷：
/// - 少一天 ⇒ 那一天会悄悄回退到窗口首日规则（本计划要根除的缺陷本身）；
/// - 多一天 ⇒ 有人在装配时枚举出了窗口之外的日期，而它可能被候选生成拿去做判断。
void _assertDailyPoliciesCoverWindow({
  required ScheduleProblem problem,
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) {
  final expected = _enumerateLocalDates(
    zones,
    problem.planningWindow.startUtc,
    problem.planningWindow.endUtc,
    timeZoneId,
  );
  final actual = problem.dailyPolicies.keys.toList()..sort();
  if (expected.length != actual.length) {
    throw StateError(
      '逐日策略的日期数与规划窗口不一致：窗口 ${expected.length} 天'
      '（${expected.first} … ${expected.last}），策略 ${actual.length} 天',
    );
  }
  for (var index = 0; index < expected.length; index++) {
    if (expected[index] != actual[index]) {
      throw StateError(
        '逐日策略的日期集合与规划窗口不一致：第 $index 天应当是 '
        '${expected[index]}，实际是 ${actual[index]}',
      );
    }
  }
}

/// 把 [instantUtc] 向上取整到排程粒度。
///
/// **向上而不是就近**：起点代表"不得早于现在"。就近取整会把一个 10:03 的时刻变成 10:05
/// （可以）但也可能变成 10:00（不可以——那又把 3 分钟过去时段放回了窗口）。
///
/// **粒度由调用方传入，且必须来自 `problem.rules.granularityMinutes`**
/// （1.8.0，2026-10-12 故障）：这里此前默认 5 分钟，于是用户把排程粒度配成 10 分钟时，
/// 窗口起点落在 5 分钟网格上、引擎落在 10 分钟网格上——"现在"在两处各算了一遍。
/// 规则是**唯一事实源**，因此不再有默认值：漏传会成为编译错误，而不是静默退回 5 分钟。
DateTime _ceilToGranularity(
  DateTime instantUtc, {
  required int granularityMinutes,
}) {
  assert(granularityMinutes > 0);
  final step = Duration(minutes: granularityMinutes).inMicroseconds;
  final micros = instantUtc.toUtc().microsecondsSinceEpoch;
  final rounded = ((micros + step - 1) ~/ step) * step;
  return DateTime.fromMicrosecondsSinceEpoch(rounded, isUtc: true);
}
