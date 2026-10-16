// 「七日日历里明明还有空档，生成计划却把任务全部报成可用时间不足」的端到端回归门槛。
//
// 实施计划：`docs/superpowers/plans/2026-10-13-visible-free-time-false-shortage-repair.md`
//   Task 1（用真实故障形状建立红灯与阶段证据）、Task 2/3/5（准入、周期隔离、零安排根因）。
//
// ## 本文件钉住的三件事
//
// 1. **未来周期实例不得作为普通任务进入本次规划**。`ensureCycles` 是按**滚动七天窗口**
//    生成实例的，而滚动七天从"现在"起算、通常跨越两个本地周（周日下午起算必然跨周）。
//    于是数据库里同时存在本周与下周两个实例；而 `RepositoryScheduleProblemSource.load()`
//    只把**本周**那一份的 task id 从普通输入里换掉——下周那份留在 `openTasks` 的
//    普通映射里，成为一条"没有任何合法时段却又带着目标分钟"的幽灵任务。
//
//    这条缺陷解释了用户看到的「同名周期目标出现两条，各还缺 210 分钟」：
//    两条的**标题相同、task id 不同**，因此"按标题去重"是错的处置——正确处置是
//    **上游把它排除**（见计划 §7「不用标题去重周期实例；标题不是身份」）。
//
// 2. **窗口之外的任务不得制造本次缺口**。判据是 `availableFromUtc >= planningWindow.endUtc`
//    ⇒ 静默排除；而 `dueAtUtc <= planningWindow.startUtc` 是**另一类**事实
//    （截止已过），它必须进入问题报告，不能静默消失。
//
// 3. **有合法候选就必须真的排进去**。三层证据必须一致：
//    日历空闲 → 候选数 → 已排分钟。任何一层从非零变成零都是缺陷，而不是"容量不足"。
//
// ## 为什么必须走真实装配链
//
// 手写 `ScheduleProblem` 会绕过**唯一可能出错的那一段**（`load()` 的装配顺序）。
// 因此这里调用真实的 `RecurringTaskService.ensureCycles → RepositoryScheduleProblemSource.load
// → DeterministicScheduleEngine.generate`，库用内存 Drift。
//
// ## 匿名化
//
// 夹具只使用相对时刻与匿名 id（`ordinary-a`／`cycle-current`／`cycle-next`）。
// 没有真实 UUID、没有用户标题、没有用户数据库内容（Global Constraints）。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../support/daily_policies.dart';

const String _zoneId = 'Asia/Shanghai';

final TimeZoneDatabase _zones = TimeZoneDatabase();

/// 固定时钟：东八区 **2026-10-08 12:00（周四）**。
///
/// 选周四中午的理由是它与用户故障时刻同形：滚动七天窗口从此刻起算会一直落到
/// **下周三**，因此 `_periodsCovering` 必然覆盖**两个**本地周（本周 10-05 与下周 10-12），
/// 于是 `ensureCycles` 会为同一个模板生成两个实例——正是泄漏的土壤。
final DateTime _now = DateTime.utc(2026, 10, 8, 4);

/// 本次规划窗口（与装配层同形）：从"现在"到"本地今天 + 7 天的本地午夜"。
/// 7 天后是 2026-10-15（周四），本地 00:00。
final DateTime _windowEnd = _zones.localMidnightToUtc(
  DateTime(2026, 10, 15),
  _zoneId,
);

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'anonymous-${++_n}';
}

final class _NoLifeAreas implements LifeAreaLookup {
  const _NoLifeAreas();
  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}

/// 不提供任何固定日程：本文件要证明的是"**在只有规则占用的情况下**（睡眠、午餐、晚餐、
/// 每日上限、片段间休息）仍然出现假缺口"，因此夹具刻意**不**注入额外占用。
///
/// 注入一个"刚好够用"的日历只会让红灯变成"容量确实不够"的另一种解释。
final class _NoCalendar implements CalendarRepository {
  const _NoCalendar();
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];
  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _NoPlans implements PlanRepository {
  const _NoPlans();
  @override
  Future<ConfirmedPlan?> current() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late db.AppDatabase database;
  late DriftTaskRepository taskRepository;
  late RecurringTaskService recurring;
  late RepositoryScheduleProblemSource source;

  /// 普通任务：高精力、目标 180、截止落在规划窗口内（周日 2026-10-11 本地 24:00）。
  const ordinaryId = 'ordinary-a';

  setUp(() {
    database = db.AppDatabase.forTesting(
      NativeDatabase.memory(),
      enforceForeignKeys: false,
    );
    taskRepository = DriftTaskRepository(database.taskDao);
    recurring = RecurringTaskService(
      repository: DriftRecurringTaskRepository(
        database,
        RecurringTaskDao(database),
      ),
      clock: const _FixedClock(),
      idGenerator: _Ids(),
      zones: _zones,
      timeZoneId: _zoneId,
      tasks: taskRepository,
    );
    source = RepositoryScheduleProblemSource(
      tasks: taskRepository,
      lifeAreas: const _NoLifeAreas(),
      calendar: const _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: const _NoPlans(),
      clock: const _FixedClock(),
      timeZoneId: _zoneId,
      zones: _zones,
      recurring: recurring,
    );
  });

  tearDown(() => database.close());

  Future<void> saveOrdinaryTask({
    DateTime? availableFromUtc,
    DateTime? dueAtUtc,
  }) => taskRepository.save(
    PlannerTask(
      id: ordinaryId,
      title: 'ordinary-a',
      priority: TaskPriority.high,
      estimatedMinutes: 180,
      remainingMinutes: 180,
      availableFromUtc: availableFromUtc,
      dueAtUtc:
          dueAtUtc ??
          _zones.localMidnightToUtc(DateTime(2026, 10, 12), _zoneId),
      energyLevel: TaskEnergyLevel.high,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
      status: TaskStatus.open,
      createdAtUtc: _now,
      updatedAtUtc: _now,
    ),
  );

  /// 建一个"每周 210 分钟"的周期目标，并返回两个实例的 task id。
  Future<({String currentCycle, String nextCycle})> createWeeklyGoal() async {
    final template = await recurring.createTemplate(
      title: 'cycle-a',
      targetMinutes: 210,
      priority: TaskPriority.medium,
      energyLevel: TaskEnergyLevel.medium,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 30,
      maxChunkMinutes: 90,
      startsOnLocalDate: DateTime(2026, 10, 5), // 本周一
      nowUtc: _now,
    );
    return (
      currentCycle: 'recurring:${template.id}:2026-10-05',
      nextCycle: 'recurring:${template.id}:2026-10-12',
    );
  }

  /// 模拟**生产启动序列**：应用启动时先跑一次 `ensureCycles`（`main.dart` 的
  /// `unawaited(recurringTasks.ensureCycles(...))`），随后用户才点"生成计划"。
  ///
  /// **这一步是夹具的必要成分，不是作弊**：它把"实例已经生成好"这个生产稳态摆到
  /// 排程输入之前。不这样做的话，第一次 `load()` 内部的 `watchOpenTasks()` 可能读到
  /// 生成前的快照，泄漏会被这个**测试特有的竞态**掩盖——而真实运行中实例早就躺在库里。
  Future<void> settleCyclesLikeStartup() => recurring.ensureCycles(
    TimeRange(startUtc: _now, endUtc: _now.add(const Duration(days: 7))),
    _now,
  );

  /// 阶段证据：**失败信息必须能逐层核对**（计划 Task 1 Step 6）。
  ///
  /// 只输出匿名 id、结构化 code 与数字，不输出标题、备注或任何数据库内容。
  String phaseEvidence({
    required ScheduleProblem problem,
    required ScheduleProposal proposal,
    required List<SchedulingCandidate> candidatesFor,
    required String taskId,
    required String admission,
  }) {
    final task = problem.tasks.where((item) => item.id == taskId).firstOrNull;
    final planned = proposal.blocks
        .where((block) => block.taskId == taskId)
        .fold<int>(0, (sum, block) => sum + block.durationMinutes);
    final unscheduled = proposal.unscheduled
        .where((item) => item.taskId == taskId)
        .firstOrNull;
    final window = problem.planningWindow;
    final zoneId = problem.timeZoneId;
    final rules = problem.rules;
    final builder = AvailabilityBuilder(_zones);
    final calendarGap = builder
        .build(
          AvailabilityInput(
            planningWindow: window,
            timeZoneId: zoneId,
            rules: rules,
            dailyPolicies: dailyPoliciesForWindow(
              zones: _zones,
              window: window,
              rules: rules,
              timeZoneId: zoneId,
            ),
            fixedIntervals: problem.fixedIntervals
                .map((item) => item.range)
                .toList(),
            protectedIntervals: problem.protectedIntervals
                .map((item) => item.range)
                .toList(),
            lockedBlocks: problem.lockedBlocks
                .map((item) => item.range)
                .toList(),
          ),
        )
        .fold<int>(0, (sum, slot) => sum + slot.durationMinutes);
    final lines = <String>[
      'window=${problem.planningWindow.startUtc.toIso8601String()}'
          '..${problem.planningWindow.endUtc.toIso8601String()}',
      'task=$taskId',
      'admission=$admission',
      'calendarGapMinutes=$calendarGap',
      'requiredMinutes=${task?.requiredMinutes}',
      'availableFromUtc=${task?.availableFromUtc?.toIso8601String()}',
      'dueAtUtc=${task?.dueAtUtc?.toIso8601String()}',
      'candidateCount=${candidatesFor.length}',
      'selectedMinutes=$planned',
      'shortageMinutes=${unscheduled?.shortageMinutes ?? 0}',
      'reasons=${unscheduled?.reasons.map((reason) => reason.code.name).join(",")}',
      'tasksInProblem=${problem.tasks.map((item) => item.id).join(",")}',
      'unscheduledTaskIds=${proposal.unscheduled.map((item) => item.taskId).join(",")}',
    ];
    return lines.join('\n');
  }

  test('**截止之后的日子不得分走按日预算**（零安排根因的回归门槛）', () async {
    // 这条用例钉的是本次故障的**根因**，而不是它的表象。
    //
    // 复现形状：210 分钟的周期目标、截止在**本周日**（周期目标的"本周末"就是这种形状），
    // 而规划窗口有**七天**。均分器按七日窗口摊量 ⇒ 每天 30 分钟，其中三天（下周一至三）
    // 落在截止之后、永远产不出候选。真正能排的四天每天只拿到 30 分钟，引擎因此
    // 只排进 120 分钟，把剩下的 90 分钟报成 `dailyLimitReached` —— 而周四到周日
    // 每天还有近 10 小时空闲。
    //
    // 修法是**只按截止之前的本地日分配预算**（`_capacityByLocalDate`）。这条断言必须
    // 能因为"某天预算被截止之后的日子吃掉"而失败，否则它只是一条同义反复。
    final goal = await createWeeklyGoal();
    await saveOrdinaryTask();
    await settleCyclesLikeStartup();

    final problem = await source.load();
    final proposal = DeterministicScheduleEngine(_zones).generate(problem);
    final window = problem.planningWindow;
    final zoneId = problem.timeZoneId;
    final rules = problem.rules;
    final slots = AvailabilityBuilder(_zones).build(
      AvailabilityInput(
        planningWindow: window,
        timeZoneId: zoneId,
        rules: rules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: _zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        fixedIntervals: problem.fixedIntervals
            .map((item) => item.range)
            .toList(),
        protectedIntervals: problem.protectedIntervals
            .map((item) => item.range)
            .toList(),
        lockedBlocks: problem.lockedBlocks.map((item) => item.range).toList(),
      ),
    );
    final task = problem.tasks.firstWhere(
      (item) => item.id == goal.currentCycle,
    );
    final candidates = CandidateGenerator(
      granularityMinutes: problem.rules.granularityMinutes,
    ).generate(task, slots, remainingMinutes: task.requiredMinutes);
    final evidence = phaseEvidence(
      problem: problem,
      proposal: proposal,
      candidatesFor: candidates,
      taskId: goal.currentCycle,
      admission: 'n/a',
    );

    expect(task.dueAtUtc, isNotNull, reason: '周期目标的截止＝本周末\n$evidence');
    expect(
      problem.planningWindow.endUtc.isAfter(task.dueAtUtc!),
      isTrue,
      reason:
          '前置条件：规划窗口**越过**了任务截止，因此"截止之后的日子"确实存在于窗口里'
          '\n$evidence',
    );

    int scheduledFor(String taskId) => proposal.blocks
        .where((block) => block.taskId == taskId)
        .fold<int>(0, (sum, block) => sum + block.durationMinutes);

    expect(
      scheduledFor(goal.currentCycle),
      task.requiredMinutes,
      reason:
          '周四到周日每天仍有近 10 小时空闲，210 分钟必须全部排进去；'
          '修复前这里只有 120，差额 90 被报成"达到每日上限"——而那天其实还有容量'
          '\n$evidence',
    );
    expect(
      proposal.unscheduled.where((item) => item.taskId == goal.currentCycle),
      isEmpty,
      reason: '排得下就不该有缺口\n$evidence',
    );
    expect(
      proposal.conflicts,
      isEmpty,
      reason:
          'conflicts=${proposal.conflicts.map((item) => item.code.name).join(",")}'
          '\n$evidence',
    );
  });

  test('**准入期的非法输入是阻断，而不是静默丢弃**（§1.7 第 4 类）', () async {
    // `availableFromUtc >= dueAtUtc` ⇒ 任务自己的时间范围是空的。装配层**不尝试排程**
    // 这件任务（拿一件自相矛盾的任务去排只会产出无法复现的结果），
    // 但"不排它"与"静默丢弃它"是两件事：它必须作为阻断问题走到预览。
    final instant = _zones.localDateTimeToUtc(
      DateTime(2026, 10, 9),
      15 * 60,
      _zoneId,
    );
    await saveOrdinaryTask(availableFromUtc: instant, dueAtUtc: instant);

    final problem = await source.load();
    final proposal = DeterministicScheduleEngine(_zones).generate(problem);

    expect(
      problem.tasks.map((task) => task.id),
      isNot(contains(ordinaryId)),
      reason: '非法输入不进入排程',
    );
    expect(
      proposal.unscheduled.map((item) => item.taskId),
      isNot(contains(ordinaryId)),
      reason: '它从未进入 `problem.tasks`，因此不该产生缺口——否则会是"缺口＋冲突"说两遍',
    );
    final conflict = proposal.conflicts
        .where((item) => item.taskId == ordinaryId)
        .firstOrNull;
    expect(conflict, isNotNull, reason: '必须如实告诉用户哪一件任务的数据有问题');
    expect(conflict!.code, ConflictCode.invalidInput);
    expect(
      planningConflictMessage(conflict, taskTitle: 'ordinary-a'),
      contains('最早开始时间'),
      reason: '不能退回笼统的"排程输入无效"——用户据此才知道要改什么',
    );
  });

  test('**未来周期实例不得泄漏成普通任务**（真实故障形状）', () async {
    final goal = await createWeeklyGoal();
    await saveOrdinaryTask();
    await settleCyclesLikeStartup();

    // 前置条件：`ensureCycles` 按**滚动七天**生成实例，因此库里同时存在本周与下周两个
    // 实例；而本次规划窗口（本地今天 + 7 天）虽然时间上跨进了下周的周起点，却**只**
    // 把本周那个实例作为周期目标加回来。夹具先钉住"两个实例都真实存在"，
    // 后面那条断言才排除"其实只有一个实例"这种解释。
    final problem = await source.load();
    final ids = problem.tasks.map((task) => task.id).toList();
    final cyclesInDatabase = await recurring.repository.listCyclesInRange(
      DateTime(2026, 10, 5),
      DateTime(2026, 10, 12),
    );
    expect(
      cyclesInDatabase.map((cycle) => cycle.taskId),
      containsAll([goal.currentCycle, goal.nextCycle]),
      reason: '前置条件：滚动窗口把本周与下周两个实例都生成出来了',
    );
    expect(
      _windowEnd.isAfter(problem.planningWindow.startUtc),
      isTrue,
      reason: '窗口终点＝本地今天 + 7 天的午夜（夹具常量与生产装配同口径）',
    );

    expect(ids, contains(goal.currentCycle), reason: '本周实例必须进入本次规划');
    expect(
      ids,
      isNot(contains(goal.nextCycle)),
      reason:
          '下周实例的滚动窗口已被 `ensureCycles` 生成，但**本次规划只加回本周周期实例**；'
          '它不得作为普通任务进入排程。泄漏时用户看到的是同名周期目标出现两条、'
          '各还缺同一份分钟数。\n'
          '实际输入：$ids',
    );
    expect(
      ids.where((id) => id == ordinaryId),
      hasLength(1),
      reason: '普通任务最多一条；重复会让同一份剩余时长被安排两遍',
    );
  });

  test('**有合法空档就必须真的排进去**（日历空闲 → 候选 → 已排分钟）', () async {
    final goal = await createWeeklyGoal();
    await saveOrdinaryTask();
    await settleCyclesLikeStartup();

    final problem = await source.load();
    final proposal = DeterministicScheduleEngine(_zones).generate(problem);

    final ordinaryTask = problem.tasks
        .where((task) => task.id == ordinaryId)
        .firstOrNull;
    final cycleTask = problem.tasks
        .where((task) => task.id == goal.currentCycle)
        .firstOrNull;

    final generator = CandidateGenerator(
      granularityMinutes: problem.rules.granularityMinutes,
    );
    final window = problem.planningWindow;
    final zoneId = problem.timeZoneId;
    final rules = problem.rules;
    final slots = AvailabilityBuilder(_zones).build(
      AvailabilityInput(
        planningWindow: window,
        timeZoneId: zoneId,
        rules: rules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: _zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        fixedIntervals: problem.fixedIntervals
            .map((item) => item.range)
            .toList(),
        protectedIntervals: problem.protectedIntervals
            .map((item) => item.range)
            .toList(),
        lockedBlocks: problem.lockedBlocks.map((item) => item.range).toList(),
      ),
    );
    final ordinaryCandidates = ordinaryTask == null
        ? const <SchedulingCandidate>[]
        : generator.generate(
            ordinaryTask,
            slots,
            remainingMinutes: ordinaryTask.requiredMinutes,
          );
    final cycleCandidates = cycleTask == null
        ? const <SchedulingCandidate>[]
        : generator.generate(
            cycleTask,
            slots,
            remainingMinutes: cycleTask.requiredMinutes,
          );

    final calendarGap = slots.fold<int>(
      0,
      (sum, slot) => sum + slot.durationMinutes,
    );
    final evidence =
        'calendarGapMinutes=$calendarGap\n'
        'slots=${slots.length}\n'
        '${phaseEvidence(problem: problem, proposal: proposal, candidatesFor: ordinaryCandidates, taskId: ordinaryId, admission: "n/a")}\n'
        '${phaseEvidence(problem: problem, proposal: proposal, candidatesFor: cycleCandidates, taskId: goal.currentCycle, admission: "n/a")}';

    expect(calendarGap, greaterThanOrEqualTo(390), reason: evidence);
    expect(ordinaryCandidates, isNotEmpty, reason: evidence);
    expect(cycleCandidates, isNotEmpty, reason: evidence);

    int scheduledFor(String taskId) => proposal.blocks
        .where((block) => block.taskId == taskId)
        .fold<int>(0, (sum, block) => sum + block.durationMinutes);

    expect(scheduledFor(ordinaryId), greaterThan(0), reason: evidence);
    expect(scheduledFor(goal.currentCycle), greaterThan(0), reason: evidence);
    expect(
      proposal.unscheduled.map((item) => item.taskId),
      isNot(contains(goal.nextCycle)),
      reason: '下周实例不得出现在本次缺口预览里\n$evidence',
    );
    expect(
      proposal.conflicts,
      isEmpty,
      reason:
          '修复后的提案必须继续通过最终校验（计划 §Review Focus 末条）\n'
          'conflicts=${proposal.conflicts.map((item) => item.code.name).join(",")}\n'
          '$evidence',
    );
  });
}
