import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/schedule_colors.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/scheduling/protected_time_expander.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 生产用的今日页与周视图数据源：把固定日程、保护时间和已确认计划块读成
/// `ScheduleViewItem`。
///
/// 此前这两个页面注入的是 `EmptyScheduleViewSource`，恒返回空列表，因此今日页
/// 与周视图在真实运行中永远不显示任何安排。
///
/// 已知限制：
/// - 只在订阅时读取一次。任务流是实时的，但固定日程与已确认计划只提供 `Future`
///   接口，因此数据变化后需要重新订阅才能看到；要做到实时刷新需要仓储层提供
///   变更流。
/// - `ScheduleItemKind.life` 尚无法产生：`PlannerTask` 没有生活事项标记（见 R1、R2
///   关于标签与项目缺失的登记），生活配额目前只在统计服务里按领域名推断。
final class RepositoryScheduleViewSource implements ScheduleViewSource {
  RepositoryScheduleViewSource({
    required this.tasks,
    required this.calendar,
    required this.plans,
    required this.rules,
    required this.colors,
    required this.zones,
    required this.timeZoneId,
    required this.history,
    Clock? clock,
  }) : protectedTimes = ProtectedTimeExpander(zones),
       _clock = clock ?? const SystemClock();

  final TaskRepository tasks;
  final CalendarRepository calendar;
  final PlanRepository plans;
  final PlanningRuleResolver rules;
  final ScheduleColorService colors;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final ProtectedTimeExpander protectedTimes;

  /// 历史计划块（含已被取代的版本）。过去几天当时排了什么只在那里。
  final PlanBlockHistory history;

  /// 判定固定日程"时间是否已经过去"用。可注入是为了让测试能固定"现在"，
  /// 而不是靠 `DateTime.now()`——那种测试会在跨日、跨时区时随机变红。
  final Clock _clock;

  @override
  Stream<List<ScheduleViewItem>> watch(
    DateTime startUtc,
    DateTime endUtc,
  ) async* {
    yield await _load(startUtc, endUtc);
  }

  Future<List<ScheduleViewItem>> _load(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    final items = <ScheduleViewItem>[];
    final window = TimeRange(startUtc: startUtc, endUtc: endUtc);
    final colorCatalog = await colors.loadCatalog();
    final nowUtc = _clock.nowUtc();

    for (final occurrence in await calendar.occurrencesBetween(
      startUtc,
      endUtc,
    )) {
      final category = colorCatalog.forAreaOrSpecial(
        areaId: occurrence.areaId,
        fallback: ScheduleSpecialCategory.unassignedFixed,
      );
      items.add(
        ScheduleViewItem(
          id: scheduleFixedItemId(occurrence.eventId),
          title: occurrence.title,
          kind: ScheduleItemKind.fixed,
          range: occurrence.range,
          categoryKey: category.key,
          categoryLabel: category.label,
          categoryColorArgb: category.colorArgb,
          categorySortOrder: category.sortOrder,
          areaId: occurrence.areaId,
          // 固定日程没有"勾选"这个动作，它的完成是**时间过去**：结束了就是结束了。
          // 保护时间不参与——它不是待办，"午餐时间已经过去"不需要被标记。
          isCompleted: !occurrence.range.endUtc.isAfter(nowUtc),
        ),
      );
    }

    final localDate = _dateOnly(zones.toLocal(startUtc, timeZoneId));
    final resolved = await rules.resolveForWindow(localDate);
    for (final interval in protectedTimes.expand(
      rules: resolved,
      startUtc: startUtc,
      endUtc: endUtc,
      timeZoneId: timeZoneId,
    )) {
      final category = colorCatalog.special(
        ScheduleSpecialCategory.protectedTime,
      );
      items.add(
        ScheduleViewItem(
          id: interval.id,
          title: _protectedLabel(interval.id),
          kind: ScheduleItemKind.protectedTime,
          range: interval.range,
          categoryKey: category.key,
          categoryLabel: category.label,
          categoryColorArgb: category.colorArgb,
          categorySortOrder: category.sortOrder,
        ),
      );
    }

    final confirmed = await plans.current();

    // **历史块要一起读**：`plans.current()` 只给最新一版计划，而重排会生成新版本——过去几天
    // 当时排了什么只留在旧版本里。只读最新版就是"重排一次、历史全没"，用户 2026-10-07 报的
    // "昨天已经完成的计划在我调整计划后就都不见了"正是这个。
    final historical = await history.blocksInWindow(startUtc, endUtc);
    // ignore: avoid_print
    // **哪些任务已经结束**（M9 收口后修）：只查**历史块里出现过的**任务，不拉全表——
    // 窗口 8 天、历史版本若干个，涉及的 id 通常是个位数。
    final terminalTaskIds = <String>{};
    for (final taskId in {for (final entry in historical) entry.block.taskId}) {
      final task = await tasks.getById(taskId);
      if (task != null && task.status.isClosed) terminalTaskIds.add(taskId);
      // ignore: avoid_print
    }
    // 复用上面那份"现在"（固定日程的完成判定已经取过一次），不再重复取——两次调用之间跨过
    // 一秒就会让同一个窗口里的判定互相打架。
    final currentBlocks = confirmed?.blocks ?? const <PlannedBlock>[];
    // **当前版给哪些任务安排过位置**（M9 收口后修）：判"这个任务的旧位置是否已被取代"要看
    // **整份当前版**，而不是只看某一天——一个任务可能被当前版挪到了别的一天。
    final scheduledTaskIds = <String>{
      for (final block in currentBlocks) block.taskId,
    };

    // **一个本地日只由一版计划决定**，而不是把各版本求并集。
    //
    // 这是 2026-10-07 那次"已完成待办重复"的真正修法。第一版把各版本的块并起来，于是：
    //   · `算法作业` 今天在当前版是 10:00、在旧版是 07:30 → 两版并起来就是**今天两次**；
    //   · `大物预习课` 昨天在两版里各有 50+90 分钟 → 并起来就是**昨天三四次**。
    // 而从这条数据也能看出：**一版计划是对那段时间的完整声明**，跨版本求并集在语义上就是错的。
    //
    // 规则（按本地日逐个决定）：
    // 1. 当天有当前确认版本的块 → **只用当前版**（它是最新声明）。今天与未来都走这一支，
    //    因此"把任务改到别的时间"不会再同时显示新旧两个位置。
    // 2. 当天没有当前版的块、且这一天**已经完整过去** → 用"当天结束时在用的那一版"
    //    （`createdAt <= 当天结束` 里最新的那一版）——这就是"当时排了什么"的还原。
    // 3. 其余情况留空：今天/未来若当前版没有安排，说明那天本来就没排，不该从历史里捞回来。
    final kept = <PlannedBlock>[];
    final keptIds = <String>{};
    for (final day in _localDays(startUtc, endUtc)) {
      final dayRange = TimeRange(startUtc: day.startUtc, endUtc: day.endUtc);
      final fromCurrent = [
        for (final block in currentBlocks)
          if (block.range.overlaps(dayRange)) block,
      ];
      final chosen = fromCurrent.isNotEmpty
          ? fromCurrent
          : _historyInForce(historical, dayRange, day.endUtc, nowUtc);
      // **已结束的任务，那块时间仍然要看得见**（M9 收口后修，用户实测报告）。
      //
      // 用户原话："我今天完成的算法作业为什么在今日和日历界面不见了"。
      //
      // 机制（用他的真实数据核对过）：勾选完成 → `TaskService.changeStatus` 发
      // `DomainChangeKind.taskCompleted` → 重排；已完成的任务**不再参与排程**，
      // 因此**新版本计划里不再有它的块**（他库里的 `算法作业` 只在 03:51 与 01:49 两版里，
      // 而当前版是 21:18 生成的）。而上面的规则 1 说"当天有当前版的块就**只用当前版**"——
      // 今天正好有别的任务的块，于是那条已经做完的记录**整天消失**。
      // 规则 2 的 `_historyInForce` 只覆盖"**整天已经完整过去**"的日子，救不了今天。
      //
      // 修法：当天在当前版之外，**再补上"已结束的任务"在过去时间里的那些块**。
      // 边界刻意收得很紧，避免重新引入"同一件事显示两次"（见上面 135~147 行的教训）：
      //   · 只收**状态是终态**（已完成／已取消／已跳过）的任务；
      //   · 只收**整段已经过去**的块（`endUtc <= now`）——未来的时间不存在"做完了"；
      //   · 同一任务只保留**最新版本**里的那一块；
      //   · 与当前版**按块 id 去重**。
      //
      // **为什么不改成"把已完成任务的块留在当前版里"**：那是重排器的语义（已完成不参与排程），
      // 改它会动摇"计划只包含还要做的事"这条口径。这是**视图**该补的历史显示。
      // ignore: avoid_print
      final chosenBlocks = <PlannedBlock>[
        ...chosen,
        ..._pastTerminalBlocks(
          historical: historical,
          dayRange: dayRange,
          nowUtc: nowUtc,
          terminalTaskIds: terminalTaskIds,
          scheduledTaskIds: scheduledTaskIds,
          alreadyIncluded: {for (final block in chosen) block.id},
        ),
      ];
      for (final block in chosenBlocks) {
        if (keptIds.add(block.id)) kept.add(block);
      }
    }
    final historicalPast = [
      for (final block in kept)
        if (!currentBlocks.any((current) => current.id == block.id)) block,
    ];

    if (confirmed != null || historicalPast.isNotEmpty) {
      final openTasks = await tasks.watchOpenTasks().first;
      final titles = {for (final task in openTasks) task.id: task.title};
      final areaIds = {for (final task in openTasks) task.id: task.areaId};
      final completedIds = <String>{};

      // **计划块可能指向已经完成（或被取消）的任务**：它们不在 `watchOpenTasks` 里，上面两张表就
      // 查不到，标题会回退成字面量「已安排任务」、领域退化成「无领域任务」——用户看到的是"勾完之后
      // 卡片变成了另一个分类"，颜色也跟着变（2026-10-06 实测反馈）。历史块更是**几乎全都**指向
      // 已经过去的任务，所以补查的范围必须同时覆盖两者。
      //
      // 这里对查不到的 id **逐个补查一次**：计划块是"当时排了什么"的事实记录，它的标题与归属
      // 不该因为任务结束而消失。只补查缺的那几个，所以正常情况下一次都不会走到。
      final referenced = <String>{
        for (final block in confirmed?.blocks ?? const <PlannedBlock>[])
          block.taskId,
        for (final block in historicalPast) block.taskId,
      };
      for (final taskId in referenced) {
        if (titles.containsKey(taskId)) continue;
        final task = await tasks.getById(taskId);
        if (task == null) continue; // 真正被永久清除的任务：保留兜底文案
        titles[taskId] = task.title;
        areaIds[taskId] = task.areaId;
        if (task.status == TaskStatus.completed) completedIds.add(taskId);
      }

      void addBlock(PlannedBlock block) {
        final areaId = areaIds[block.taskId];
        final category = colorCatalog.forAreaOrSpecial(
          areaId: areaId,
          fallback: ScheduleSpecialCategory.unassignedTask,
        );
        items.add(
          ScheduleViewItem(
            id: 'block:${block.id}',
            title: titles[block.taskId] ?? '已安排任务',
            kind: ScheduleItemKind.task,
            range: block.range,
            categoryKey: category.key,
            categoryLabel: category.label,
            categoryColorArgb: category.colorArgb,
            categorySortOrder: category.sortOrder,
            explanation: block.explanationCode,
            areaId: areaId,
            // M4（路线图 §8）：今日页要就地开始专注／完成／查看详情，因此必须能从条目
            // 找到任务。这里本来就有 `block.taskId`，直接带出去，省得页面去拆 `id` 前缀。
            taskId: block.taskId,
            isCompleted: completedIds.contains(block.taskId),
          ),
        );
      }

      for (final block in confirmed?.blocks ?? const <PlannedBlock>[]) {
        if (!block.range.overlaps(window)) continue;
        addBlock(block);
      }
      for (final block in historicalPast) {
        addBlock(block);
      }
    }

    items.sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
    return List.unmodifiable(
      items.where((item) => item.range.overlaps(window)),
    );
  }

  /// 窗口覆盖的**本地日**（按本机时区的零点切）。
  ///
  /// 用本地日而不是 UTC 日：日界一旦错开，跨零点的一晚会同时落到两天里，"一天只取一版"的判定
  /// 就会把同一段安排算两次。
  List<({DateTime startUtc, DateTime endUtc})> _localDays(
    DateTime startUtc,
    DateTime endUtc,
  ) {
    final days = <({DateTime startUtc, DateTime endUtc})>[];
    // 用 `DateTime` 而不是 `TZDateTime` 收着：`toLocal` 给的是 TZDateTime，而下面递推出来的
    // 是普通本地日期，两者只是"年月日"的载体，混用类型只会招来一次无谓的转换。
    DateTime localDate = zones.toLocal(startUtc, timeZoneId);
    var dayStart = zones.localMidnightToUtc(localDate, timeZoneId);
    // 上限只是防御性的：正常窗口 8 天，异常输入不该让这里变成死循环。
    for (var guard = 0; guard < 400 && dayStart.isBefore(endUtc); guard++) {
      final nextLocal = DateTime(
        localDate.year,
        localDate.month,
        localDate.day + 1,
      );
      final dayEnd = zones.localMidnightToUtc(nextLocal, timeZoneId);
      days.add((startUtc: dayStart, endUtc: dayEnd));
      localDate = nextLocal;
      dayStart = dayEnd;
    }
    return days;
  }

  /// 某一天"当时在用的那一版计划"里，落在那一天的块。
  ///
  /// - 只在**这一天已经完整过去**（`dayEndUtc <= nowUtc`）时才回历史找：还没过去的日子以当前
  ///   确认为准，否则"把任务改到别的时间"会又从旧版把原来的位置捞回来。
  /// - "当时在用的那一版"取 `versionCreatedAtUtc <= dayEndUtc` 中**最新**的一版，且这一版必须
  ///   在那一天真的排了块——否则会选到一个只覆盖之后几天的新版本，导致这一天变空。
  /// **已结束的任务在"过去时间"里的那些块**（M9 收口后修）。
  ///
  /// 见调用处的长说明。规则收得很紧：
  /// · 只收状态为终态的任务（由 [terminalTaskIds] 给出）；
  /// · **当前版已经给这个任务安排过位置 → 一律不补**（[scheduledTaskIds]）——
  ///   旧版那个位置已被取代，再补就是"同一件事显示两次"；
  /// · 只收**整段已经过去**的块（`endUtc <= nowUtc`）——未来的时间不存在"做完了"；
  /// · **一版计划是对那段时间的完整声明**，因此补的是"当时在用的那一版"里的**整组块**，
  ///   而不是每个任务各挑一块。这条与 `_historyInForce` 同一口径。
  List<PlannedBlock> _pastTerminalBlocks({
    required List<HistoricalPlanBlock> historical,
    required TimeRange dayRange,
    required DateTime nowUtc,
    required Set<String> terminalTaskIds,
    required Set<String> scheduledTaskIds,
    required Set<String> alreadyIncluded,
  }) {
    if (terminalTaskIds.isEmpty) return const [];
    // ① 先为每个"要补的任务"挑出**当时在用的那一版**。
    final versionByTask = <String, HistoricalPlanBlock>{};
    for (final entry in historical) {
      if (!terminalTaskIds.contains(entry.block.taskId)) continue;
      if (scheduledTaskIds.contains(entry.block.taskId)) continue;
      if (!entry.block.range.overlaps(dayRange)) continue;
      // **整段已经过去**才算"当时做完了"。用 `endUtc` 而不是 `startUtc`：
      // 正在进行中的那一段还没有"做完"，它要么由当前版显示，要么压根不该补。
      if (entry.block.range.endUtc.isAfter(nowUtc)) continue;
      final existing = versionByTask[entry.block.taskId];
      if (existing == null ||
          entry.versionCreatedAtUtc.isAfter(existing.versionCreatedAtUtc)) {
        versionByTask[entry.block.taskId] = entry;
      }
    }
    if (versionByTask.isEmpty) return const [];
    // ② 把那一版在**这一天**的**全部**块拿出来（"完整声明"口径）。
    final chosenVersions = <String, Set<String>>{
      for (final entry in versionByTask.values)
        entry.versionId: {entry.block.taskId},
    };
    final result = <PlannedBlock>[];
    final seen = <String>{};
    for (final entry in historical) {
      final tasks = chosenVersions[entry.versionId];
      if (tasks == null || !tasks.contains(entry.block.taskId)) continue;
      if (!entry.block.range.overlaps(dayRange)) continue;
      if (alreadyIncluded.contains(entry.block.id)) continue;
      if (!seen.add(entry.block.id)) continue;
      result.add(entry.block);
    }
    return result;
  }

  List<PlannedBlock> _historyInForce(
    List<HistoricalPlanBlock> historical,
    TimeRange dayRange,
    DateTime dayEndUtc,
    DateTime nowUtc,
  ) {
    if (dayEndUtc.isAfter(nowUtc)) return const [];
    HistoricalPlanBlock? newest;
    for (final entry in historical) {
      if (entry.versionCreatedAtUtc.isAfter(dayEndUtc)) continue;
      if (!entry.block.range.overlaps(dayRange)) continue;
      if (newest == null ||
          entry.versionCreatedAtUtc.isAfter(newest.versionCreatedAtUtc)) {
        newest = entry;
      }
    }
    if (newest == null) return const [];
    return [
      for (final entry in historical)
        if (entry.versionId == newest.versionId &&
            entry.block.range.overlaps(dayRange))
          entry.block,
    ];
  }
}

/// 保护时间区间的 id 形如 `protected:<kind>:<yyyy-MM-dd>:<minute>`。
String _protectedLabel(String intervalId) {
  final parts = intervalId.split(':');
  if (parts.length < 2) return '保护时间';
  return switch (parts[1]) {
    'lunch' => '午餐时间',
    'dinner' => '晚餐时间',
    'fixedRest' => '固定休息',
    _ => '保护时间',
  };
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
