import 'dart:async';

import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/application/schedule_view_invalidation.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/protected_time_labels.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
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
/// - `ScheduleItemKind.life` 尚无法产生：`PlannerTask` 没有生活事项标记（见 R1、R2
///   关于标签与项目缺失的登记），生活配额目前只在统计服务里按领域名推断。
///
/// **刷新（计划 §2.6）**：[watch] 不再是"读一次就结束"的 `async*`。它订阅
/// `tasks.watchAllTasks()`（任务标题／领域／完成状态）与可选的
/// [ScheduleViewInvalidation]（各写入服务的成功失效信号），任一到达就重新执行**完整**的
/// `_load`。此前它只 `yield await _load(...)` 一次，于是固定日程或确认计划写入后
/// **同一个订阅者收不到第二份列表**，页面必须重新订阅才看得到（R9）。
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
    this.recurring,
    this.invalidation,
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

  /// 周期目标（M6）。为空时卡片照常渲染，只是没有那一行进度徽标——
  /// 与"这不是周期目标的条目"是同一种显示结果。
  final RecurringTaskService? recurring;

  /// 各写入服务的成功失效信号（计划 §2.6）。
  ///
  /// **可选**：既有测试与集成夹具不传它，行为就是"只由 `tasks.watchAllTasks()` 驱动"
  /// （订阅后立即加载一次，任务变化时重载），因此向后兼容。生产组合根**必须**传，
  /// 否则固定日程、计划、规划规则、配色与领域的写入都不会触发刷新。
  final ScheduleViewInvalidation? invalidation;

  /// 历史计划块（含已被取代的版本）。过去几天当时排了什么只在那里。
  final PlanBlockHistory history;

  /// 判定"这一天是否已经完整过去"、"这块是否整段已经过去"用（历史版本还原与
  /// 终态任务补充都读它）。可注入是为了让测试能固定"现在"，
  /// 而不是靠 `DateTime.now()`——那种测试会在跨日、跨时区时随机变红。
  ///
  /// **它不再参与固定日程的"完成"判定**（计划 §1.1 R11）：完成语义只属于
  /// `TaskStatus.completed`。
  final Clock _clock;

  /// 订阅一个窗口的日程条目；**订阅期间随仓储与失效信号自动重载**（计划 §2.6）。
  ///
  /// 契约定死如下（逐条对应 §2.6，不接受"差不多"的实现）：
  ///
  /// 1. 订阅后**立即加载一次**；
  /// 2. 同时监听 `tasks.watchAllTasks()` 与 [invalidation] 的 revisions；
  /// 3. 任一信号到达后重新执行**完整**的 `_load(startUtc, endUtc)`
  ///    （不是把某个局部列表拼进半份结果）；
  /// 4. 同一时刻的多个信号合并为**至多一次在途加载 ＋ 一次待处理加载**；
  /// 5. 用**单调 generation** 丢弃晚到的旧结果——旧结果不得覆盖新结果；
  /// 6. 最后一个监听者取消后释放内部订阅与 controller；
  /// 7. 加载失败通过 stream error 交给页面，**流不关闭**，下一次信号仍能恢复。
  ///
  /// **不得用定时轮询数据库实现**：轮询既让"改完立刻看不见"退化成"最多晚一个周期"，
  /// 又在没有任何变化时持续读库。这里的每一次重载都由一个具体事件驱动。
  ///
  /// 每个订阅者拿到**独立的一份加载循环与独立的 controller**：今日页、近期日历与日视图
  /// 各自 `watch()` 一次，因此一个页面取消订阅不会掐掉另一个页面的刷新源。
  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) {
    late final StreamController<List<ScheduleViewItem>> controller;
    StreamSubscription<List<PlannerTask>>? taskChanges;
    StreamSubscription<int>? revisions;
    // **代际在"请求一次重载"时递增**，不是在加载完成时（§2.6 第 5 条）。
    //
    // 顺序很关键：一次加载若发现自己请求时的代际已经过期，就把结果整个丢掉
    // （不 emit、不报错）。于是"慢的第一次加载"根本不会把过期值推给页面，
    // 而"晚到的旧结果覆盖新结果"在结构上不可能发生——不需要额外的比较或时间戳。
    var generation = 0;
    var loading = false;
    var rerunRequested = false;
    var closed = false;

    Future<void> load() async {
      loading = true;
      final mine = generation;
      try {
        final items = await _load(startUtc, endUtc);
        // 已取消：controller 已经关闭，再 `add` 会抛 `StateError`。
        if (closed || mine != generation) return;
        controller.add(items);
      } on Object catch (error, stackTrace) {
        // **过期加载的失败也要丢掉**：否则页面会先收到一条属于旧请求的错误，
        // 而它对应的那次重载随后成功——用户白看到一次"暂时无法加载"。
        if (closed || mine != generation) return;
        // **不关闭流**（§2.6 第 7 条）：页面拿到 error 后仍能等下一次信号。
        controller.addError(error, stackTrace);
      } finally {
        loading = false;
        // 在途加载期间到达的信号合成为**一次**待处理加载：连续 20 次失效不会并发 20 次读取。
        if (rerunRequested) {
          rerunRequested = false;
          if (!closed) unawaited(load());
        }
      }
    }

    void requestReload() {
      if (closed) return;
      generation += 1;
      // **合并**：在途最多一个。期间的每一个信号都只是把"待处理"这一位立起来，
      // 而它自己的代际已经递增过，因此那份在途结果注定被丢弃。
      if (loading) {
        rerunRequested = true;
        return;
      }
      unawaited(load());
    }

    controller = StreamController<List<ScheduleViewItem>>(
      onListen: () {
        // ① 订阅后立即加载一次。
        requestReload();
        // ② 任务流。**任务展示刷新由仓储自己的流驱动**，不再要求写入方补发 bus 信号
        // （§2.6 的装配规则）：标题、领域、完成状态的变化都在 `watchAllTasks()` 上。
        taskChanges = tasks.watchAllTasks().listen(
          (_) => requestReload(),
          onError: (Object error, StackTrace stackTrace) {
            // 仓储流的错误不能毒死整个 watch：如实报一次，并请求一次重载，
            // 让页面在下一次信号（或这一次的重载）后恢复。
            if (closed) return;
            controller.addError(error, stackTrace);
            requestReload();
          },
        );
        // ③ 失效信号。未装配时（既有测试、未接总线的装配）只剩任务流这一条来源。
        final invalidation = this.invalidation;
        if (invalidation != null) {
          revisions = invalidation.revisions.listen((_) => requestReload());
        }
      },
      onCancel: () async {
        // 最后一个监听者取消后释放内部订阅与 controller（§2.6 第 6 条）。
        // 不释放的话，这个页面的加载循环会跟着应用一直跑下去。
        closed = true;
        final pendingTasks = taskChanges;
        final pendingRevisions = revisions;
        taskChanges = null;
        revisions = null;
        await pendingTasks?.cancel();
        await pendingRevisions?.cancel();
        // 不 await：这里已经在取消路径上，而 `close()` 的完成时机对调用方没有意义。
        unawaited(controller.close());
      },
    );
    return controller.stream;
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
      // **保护时间用统一配色、且不参与"完成"判定**（1.8.0，规范 §9.1）。
      //
      // 它与固定日程在数据里同形，因此差别必须在这里显式表达：
      // · 配色走 `ScheduleSpecialCategory.protectedTime`，与规则来源的保护时间**同色**——
      //   用户看到的是"这段时间受保护"，而不是"这是哪一种保护"；
      // · `isCompleted` 恒为 false：保护时间不是待办，"午餐时间已经过去"不需要被标记。
      final isProtected = occurrence.kind == CalendarEventKind.protected;
      final category = isProtected
          ? colorCatalog.special(ScheduleSpecialCategory.protectedTime)
          : colorCatalog.forAreaOrSpecial(
              areaId: occurrence.areaId,
              fallback: ScheduleSpecialCategory.unassignedFixed,
            );
      items.add(
        ScheduleViewItem(
          id: scheduleFixedItemId(occurrence.eventId),
          title: occurrence.title,
          kind: isProtected
              ? ScheduleItemKind.protectedTime
              : ScheduleItemKind.fixed,
          range: occurrence.range,
          categoryKey: category.key,
          categoryLabel: category.label,
          categoryColorArgb: category.colorArgb,
          categorySortOrder: category.sortOrder,
          // 保护时间没有归属：把它挂到某个领域会让"领域时间分配"多出一份并不存在的占用。
          areaId: isProtected ? null : occurrence.areaId,
          // **固定日程与保护时间都不参与"完成"判定**（计划 §1.1 R11）。
          //
          // 这里此前写的是 `!isProtected && !occurrence.range.endUtc.isAfter(nowUtc)`：
          // 它把"钟点过去了"当成了"用户做完了"，于是固定日程一过结束时间就画出一个
          // 完成勾。两者的处置完全不同——前者无事可做，后者要记录完成——而完成语义
          // 只属于 `TaskStatus.completed`，也就是下面计划块走的那一条（`completedIds`）。
          isCompleted: false,
          // 备注：改写对话框要预填它（负责任的实现必须"能读的字段也能写回"）。
          notes: occurrence.notes,
          // **有没有重复规则**：日视图据此决定要不要显示"仅本次／此次及以后／整个系列"。
          // 一条一次性事项上摆三个同义选项，用户会以为它们不同。
          repeats: occurrence.repeats,
          // 页面读到这一条时的修订号：改写时要带回去做并发校验。
          updatedAtUtc: occurrence.updatedAtUtc,
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
      // **类别直接读字段，不解析 id**（计划 §2.5）。这里曾经有一份
      // `_protectedLabel(interval.id)`：它 `split(':')` 取第二段当 kind，于是
      // 展开层给 id 改个格式就会静默读错，而且它**漏了 breakfast**（早餐被显示成
      // 兜底的「保护时间」）。`protectedKind` 为空只是防御性的兜底——生产路径上
      // 规则展开一定带着类别——此时回落到字面量，绝不回头去猜 id。
      final kind = interval.protectedKind;
      items.add(
        ScheduleViewItem(
          id: interval.id,
          title: kind == null ? '保护时间' : protectedTimeKindLabel(kind),
          kind: ScheduleItemKind.protectedTime,
          range: interval.range,
          categoryKey: category.key,
          categoryLabel: category.label,
          categoryColorArgb: category.colorArgb,
          categorySortOrder: category.sortOrder,
          // **规则来源**：没有锚点，因此不能编辑也不能删除（计划 Task 8 Step 3）。
          fromRules: true,
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

      // M6（§3.3 最后一条）：**周期目标实例的进度徽标**。
      //
      // 只在装配了周期服务时查；查的顺序与上面补查任务一样，逐条按需查（周期目标通常只有
      // 一两个，而"每次刷新都把所有模板 × 所有历史周都读一遍"是另一个量级）。
      final badges = <String, RecurringGoalBadge>{};
      final recurring = this.recurring;
      if (recurring != null) {
        final period = recurring.periodContaining(_clock.nowUtc());
        for (final taskId in referenced) {
          final cycle = await recurring.repository.findCycleByTaskId(taskId);
          // 只给**本周**的实例挂徽标：历史周的进度在周期详情页里看，挂在日程卡片上会让
          // 用户以为"这周只做了 20 分钟"。
          if (cycle == null ||
              cycle.periodStartLocalDate != period.startLocalDate) {
            continue;
          }
          final template = await recurring.repository.findTemplate(
            cycle.templateId,
          );
          if (template == null) continue;
          final progress = await recurring.progressForCycle(
            cycle.templateId,
            cycle.periodStartLocalDate,
          );
          badges[taskId] = RecurringGoalBadge(
            templateId: template.id,
            title: template.title,
            recordedMinutes: progress.recordedMinutes,
            targetMinutes: progress.targetMinutes,
          );
        }
      }
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
            // M6（§3.3 最后一条）：周期目标的卡片要显示这一周的进度，且**安排与完成用不同
            // 文案**。数据在这里查一次，页面只负责画。
            recurringGoal: badges[block.taskId],
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

// 这里曾经有一个 `_protectedLabel(String intervalId)`：它把
// `protected:<kind>:<yyyy-MM-dd>:<minute>` 的第二段当作类别，于是展开层改一次 id 的
// 拼接格式就会静默读错，而且那份 switch **漏了 breakfast**（计划 §2.5）。
// 类别现在由 `BusyInterval.protectedKind` 携带，文案统一取自
// `design/protected_time_labels.dart::protectedTimeKindLabel`。
DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
