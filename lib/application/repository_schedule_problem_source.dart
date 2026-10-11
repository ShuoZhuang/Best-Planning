import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/pending_moves.dart';
import 'package:personal_planner/application/pending_skips.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/course_transition.dart';
import 'package:personal_planner/scheduling/protected_time_expander.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

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
final class RepositoryScheduleProblemSource implements ScheduleProblemSource {
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

  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async {
    final nowUtc = clock.nowUtc();
    final startLocalDate = _dateOnly(zones.toLocal(nowUtc, timeZoneId));
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
    final dayStartUtc = zones.localMidnightToUtc(startLocalDate, timeZoneId);
    final startUtc = _ceilToGranularity(
      nowUtc.isAfter(dayStartUtc) ? nowUtc : dayStartUtc,
    );
    final endUtc = zones.localMidnightToUtc(
      startLocalDate.add(Duration(days: days)),
      timeZoneId,
    );

    final resolvedRules = await rules.resolveForWindow(
      startLocalDate,
      override: override,
    );
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

    // 1.8.0（规范 §11）：先算出"哪些任务被延后、下界在哪"，**再**构造排程输入。
    //
    // 顺序是必须的：任务级输入里的 `availableFromUtc` 只在构造那一刻取值，
    // 之后再改这个 map 也不会回头影响已经建好的 `SchedulableTask`。
    final deferredTaskStarts = <String, DateTime>{};
    final confirmedBlocksForDefer = confirmed?.blocks ?? const <PlannedBlock>[];
    final deferDrafts = pendingMoves;
    if (deferDrafts != null && deferDrafts.adjustment != null) {
      final openTaskIds = {for (final task in openTasks) task.id};
      for (final block in confirmedBlocksForDefer) {
        // **只延后"排程器认得"的块**：已经被跳过、被拖动或以别的方式移出输入的块
        // 不该因为一条延后请求而被重新拉回来。
        if (!openTaskIds.contains(block.taskId)) continue;
        final notBefore = deferDrafts.notBeforeForBlock(block.id, zones);
        if (notBefore == null) continue;
        // 同一个任务有多个块被延后时取**最晚**的下界：任何一块都不能早于自己的下界，
        // 而"可用起点"只有一个，取最晚的那个才是"所有块都满足"的充分条件。
        final existing = deferredTaskStarts[block.taskId];
        if (existing == null || notBefore.isAfter(existing)) {
          deferredTaskStarts[block.taskId] = notBefore;
        }
      }
    }

    final schedulable = <SchedulableTask>[
      for (final task in openTasks)
        SchedulableTask(
          id: task.id,
          requiredMinutes: task.schedulingRemainingMinutes,
          splitMode: task.splitMode,
          minChunkMinutes: task.minChunkMinutes,
          maxChunkMinutes: task.maxChunkMinutes,
          dueAtUtc: task.dueAtUtc,
          // 延后的下界**并进**任务原有的最早开始时间：两者都成立才允许开工，
          // 因此取较晚的那个。任务自己设的 `availableFromUtc` 因此不会被延后抹掉。
          availableFromUtc: _laterOf(
            task.availableFromUtc,
            deferredTaskStarts[task.id],
          ),
          priority: task.priority,
          energyLevel: task.energyLevel,
          // 生活配额因子此前恒为 0，因为这里从未设置该字段。
          isLifeTask: lifeTaskIds.contains(task.id),
          preferredWindow: task.preferredWindow,
        ),
    ];
    final schedulableIds = {for (final task in schedulable) task.id};

    // ── 周期目标进排程（M6，§3.4 / §11 Task 8）────────────────────────────────
    //
    // **周期实例本身就是一件普通任务**，因此它已经在 `openTasks` 里；这里要做的是把它
    // 那份"普通任务"的排程输入**换成周期视角的那一份**：截止时间＝本周末（或按节奏提前）、
    // 只送还差的部分、`selectedWeekdays` 拆成按天窗口。没有新约束类型、没有第二个排程器。
    //
    // **过滤掉而不是重复添加**：同一个 id 出现两次会让引擎把同一份剩余时长安排两遍。
    final recurringInputs = await _recurringInputs(nowUtc);
    if (recurringInputs.isNotEmpty) {
      final recurringTaskIds = {
        for (final input in recurringInputs) input.cycle.taskId,
      };
      schedulable.removeWhere((task) => recurringTaskIds.contains(task.id));
      for (final input in recurringInputs) {
        final expanded = recurringSchedulableTasks(input: input, zones: zones);
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
        // **被延后的块不进"精确锁定"这条路**（规范 §11.2）。
        //
        // 修复前的行为：今日页把分钟换算成 `RequestedMove.atInstant`，于是延后与拖动走同一
        // 条路径，这里给它 `locked: true` 钉在**精确目标时刻**。目标点一旦被固定日程、保护
        // 时间或另一个锁定块占用，方案直接失败（规范 §2.5）——它不会去找目标之后最近的合法
        // 时段。现在延后只抬高任务的可用起点（上面那段），这一块留在可移动块里由引擎在
        // 下界之后重新放置。级联策略（少动、当天优先）属于 Task 12。
        if (deferredTaskStarts.containsKey(block.taskId)) continue;
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

    final problem = ScheduleProblem(
      planningWindow: TimeRange(startUtc: startUtc, endUtc: endUtc),
      timeZoneId: timeZoneId,
      // **任务照旧留在 `tasks` 里**：跳过只放弃块，任务仍是未完成待办、继续参与重排。
      // 剩余时长也不在这里动——已专注的部分由既有的专注重算扣减，不重算。
      tasks: schedulable,
      fixedIntervals: [
        // **保护时间不进 `fixedIntervals`**（1.8.0，规范 §9.1）。它在数据里是与固定日程
        // 同形的日历事项（`CalendarEventKind.protected`），但排程语义完全不同：
        // 固定日程是"这段时间被占了"，保护时间是"这段时间不许安排"。混进固定日程的后果不是
        // 排错位置，而是**它会被当成固定日程投入进统计**——用户会看到"固定日程 8 小时/周"
        // 里有一半是"不许安排"的时间。
        //
        // 课表课程结束后留缓冲（用户 2026-10-08 需求）：把课的结束时间往后推
        // `courseTransitionMinutes`，于是那几分钟变成"被占用"，排程器不会把计划块紧贴在
        // 下课那一刻——用户上完课要离开教室，不可能直接接续。
        //
        // 只对 `timetableImport` 来源的事件生效；自己建的会议不受影响（用户明确划的范围）。
        // 判定与边界见 `lib/scheduling/course_transition.dart` 与它的 9 条用例。
        // 保护时间本来就是课表之外的来源，缓冲对它是空操作，但过滤要在前面做——
        // 顺序反了会把保护时间也做成带缓冲的固定占用。
        for (final occurrence in applyCourseTransition(
          fixedOccurrences,
          transitionMinutes: resolvedRules.courseTransitionMinutes,
        ))
          BusyInterval(id: occurrence.eventId, range: occurrence.range),
      ],
      protectedIntervals: [
        // 规则来源的保护时间（午餐／晚餐／固定休息）……
        ...protectedTimes.expand(
          rules: resolvedRules,
          startUtc: startUtc,
          endUtc: endUtc,
          timeZoneId: timeZoneId,
        ),
        // ……加上用户在日历里自己建的一次性或按周重复的保护时间。
        //
        // **一次且仅一次**：`fixedOccurrences` 与 `protectedOccurrences` 是同一次
        // `occurrencesBetween` 按 `kind` 分出来的两份，互为补集，因此同一条记录不可能
        // 既进 fixed 又进 protected（规范 §8 审查问题 4）。
        for (final occurrence in protectedOccurrences)
          BusyInterval(id: occurrence.eventId, range: occurrence.range),
      ],
      lockedBlocks: [
        for (final block in confirmedBlocks)
          if (block.locked &&
              schedulableIds.contains(block.taskId) &&
              !skippedBlockIds.contains(block.id) &&
              !pinnedByBlockId.containsKey(block.id))
            block,
        // 被拖动的块替换掉它原来的位置（同一个 id 不能出现两次，否则引擎会排出两条）。
        ...pinnedByBlockId.values,
      ],
      // 已确认但未锁定的块：引擎可以移动，但要付出移动代价（设计 §5.4）。
      existingBlocks: [
        for (final block in confirmedBlocks)
          if (!block.locked &&
              schedulableIds.contains(block.taskId) &&
              !skippedBlockIds.contains(block.id) &&
              !pinnedByBlockId.containsKey(block.id))
            block,
      ],
      rules: resolvedRules,
      preferences: const PreferenceProfile(),
      inputHash: '',
      pinnedUnlockedBlockIds: pinnedUnlocked,
      referenceBlocks: referenceBlocks,
    );

    return withCurrentInputHash(problem, snapshots);
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
    await service.ensureCycles(
      TimeRange(startUtc: nowUtc, endUtc: nowUtc.add(const Duration(days: 7))),
      nowUtc,
    );
    final period = service.periodContaining(nowUtc);
    final inputs = <RecurringScheduleInput>[];
    for (final template in templates) {
      final cycle = await service.repository.findCycle(
        template.id,
        period.startLocalDate,
      );
      if (cycle == null) continue;
      final progress = await service.progressForCycle(
        template.id,
        period.startLocalDate,
      );
      if (progress.remainingMinutes <= 0) continue;
      inputs.add(
        RecurringScheduleInput(
          template: template,
          cycle: cycle,
          progress: progress,
          period: period,
          planningStartUtc: nowUtc.isAfter(period.startUtc)
              ? nowUtc
              : period.startUtc,
        ),
      );
    }
    // **按模板 id 排序**：结果不得依赖数据库返回顺序（§7.2 最后一条）。这里排一次，
    // 引擎内部的 `_compareTasks` 再排一次，两道都不依赖顺序。
    inputs.sort((a, b) => a.template.id.compareTo(b.template.id));
    return inputs;
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
  });

  final RecurringTaskTemplate template;
  final RecurringTaskCycle cycle;
  final RecurringProgress progress;
  final WeeklyPeriod period;
  final DateTime planningStartUtc;
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
          requiredMinutes: remaining,
          dueAtUtc: input.period.endUtc,
          availableFromUtc: null,
          distributionPolicy: TaskDistributionPolicy.even,
        ),
      ];
    case RecurringPace.deadlineWeighted:
      return [
        base(
          requiredMinutes: remaining,
          dueAtUtc: input.period.endUtc,
          availableFromUtc: null,
        ),
      ];
    case RecurringPace.early:
      // **尽早完成**：把截止时间提前到"本周开始 + 2 天"（不早于窗口终点时才提前），
      // 于是同一个 `PressureCalculator` 会算出更高的近期推进量。窗口不足两天时保持原样。
      final earlyDue = input.period.startUtc.add(const Duration(days: 2));
      return [
        base(
          requiredMinutes: remaining,
          dueAtUtc: earlyDue.isBefore(input.period.endUtc)
              ? earlyDue
              : input.period.endUtc,
          availableFromUtc: null,
        ),
      ];
    case RecurringPace.selectedWeekdays:
      final weekdays = template.allowedWeekdays;
      final mask = weekdayMaskOf(weekdays);
      return [
        base(
          requiredMinutes: remaining,
          dueAtUtc: input.period.endUtc,
          availableFromUtc: input.period.startUtc,
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

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 把 [instantUtc] 向上取整到排程粒度。
///
/// **向上而不是就近**：起点代表"不得早于现在"。就近取整会把一个 10:03 的时刻变成 10:05
/// （可以）但也可能变成 10:00（不可以——那又把 3 分钟过去时段放回了窗口）。
///
/// 粒度默认 5 分钟，与 `CandidateGenerator.granularityMinutes` 的默认值一致；引擎只在那个
/// 网格上放置片段，因此起点也必须落在同一个网格上。刻意**不**从引擎读这个值：那会把
/// "排程粒度"变成 `ScheduleProblem` 的一部分，而这只是窗口起点的一个取整约定。
DateTime _ceilToGranularity(DateTime instantUtc, {int granularityMinutes = 5}) {
  assert(granularityMinutes > 0);
  final step = Duration(minutes: granularityMinutes).inMicroseconds;
  final micros = instantUtc.toUtc().microsecondsSinceEpoch;
  final rounded = ((micros + step - 1) ~/ step) * step;
  return DateTime.fromMicrosecondsSinceEpoch(rounded, isUtc: true);
}

/// 两个可空下界里**较晚**的那一个（都为 `null` 时返回 `null`）。
///
/// 用于把"任务自己设的最早开始时间"与"延后给出的下界"合起来：两者都必须成立，
/// 因此取较晚的那个——而不是覆盖，否则一次延后会把用户原本设的可用起点抹掉。
DateTime? _laterOf(DateTime? a, DateTime? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.isAfter(b) ? a : b;
}
