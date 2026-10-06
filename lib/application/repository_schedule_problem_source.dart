import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/pending_moves.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
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

  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async {
    final nowUtc = clock.nowUtc();
    final startLocalDate = _dateOnly(zones.toLocal(nowUtc, timeZoneId));
    final startUtc = zones.localMidnightToUtc(startLocalDate, timeZoneId);
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
    final occurrences = await calendar.occurrencesBetween(startUtc, endUtc);
    final confirmed = await plans.current();

    final schedulable = <SchedulableTask>[
      for (final task in openTasks)
        SchedulableTask(
          id: task.id,
          requiredMinutes: task.schedulingRemainingMinutes,
          splitMode: task.splitMode,
          minChunkMinutes: task.minChunkMinutes,
          maxChunkMinutes: task.maxChunkMinutes,
          dueAtUtc: task.dueAtUtc,
          availableFromUtc: task.availableFromUtc,
          priority: task.priority,
          energyLevel: task.energyLevel,
          // 生活配额因子此前恒为 0，因为这里从未设置该字段。
          isLifeTask: lifeTaskIds.contains(task.id),
          preferredWindow: task.preferredWindow,
        ),
    ];
    final schedulableIds = {for (final task in schedulable) task.id};

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
        final move = drafts.forBlock(block.id);
        if (move == null) continue;
        final target = _sameLocalClockOn(
          move.localDate,
          block.range,
          zones,
          timeZoneId,
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

    final problem = ScheduleProblem(
      planningWindow: TimeRange(startUtc: startUtc, endUtc: endUtc),
      timeZoneId: timeZoneId,
      tasks: schedulable,
      fixedIntervals: [
        for (final occurrence in occurrences)
          BusyInterval(id: occurrence.eventId, range: occurrence.range),
      ],
      protectedIntervals: protectedTimes.expand(
        rules: resolvedRules,
        startUtc: startUtc,
        endUtc: endUtc,
        timeZoneId: timeZoneId,
      ),
      lockedBlocks: [
        for (final block in confirmedBlocks)
          if (block.locked &&
              schedulableIds.contains(block.taskId) &&
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
              !pinnedByBlockId.containsKey(block.id))
            block,
      ],
      rules: resolvedRules,
      preferences: const PreferenceProfile(),
      inputHash: '',
      pinnedUnlockedBlockIds: pinnedUnlocked,
    );

    return withCurrentInputHash(problem, snapshots);
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
