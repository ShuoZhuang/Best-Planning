// 计划 `2026-10-13-calendar-preview-and-scheduling-integrity-repair.md` Task 1 Step 2／Step 3
// 的临时红灯。**本文件目前必须失败**：它钉住的是"长任务经过若干片段后形成短余量"的正确行为。
//
// ## 要修的是什么（R3／R4）
//
// `schedule_engine.dart` 在进入 `while (remaining > 0)` **之前只调用一次**
// `chunkGenerator.generate(task, slots)`，而 `CandidateGenerator._candidateDurations()`
// 又用 **`task.requiredMinutes`** 判定"这是不是短余量"：
//
// ```dart
// final isShortRemainder = task.requiredMinutes < task.minChunkMinutes;
// ```
//
// 于是一份 100 分钟的任务在整个放置循环里只看得见 `[30, 35, …]` 这一份**基于初始总量**
// 的候选集。第一轮放下 30 分钟之后，剩余 70 分钟；循环里再取候选仍是 30 分钟起步，
// 最终只能排出 `30 + 30 + 30`，最后那 10 分钟**永远不会**作为候选被生成 ——
// 用户看到的是"容量明明够，却报还缺 10 分钟"。
//
// 计划 §2.1 的冻结决策：候选接口改为
// `generate(task, slots, {required int remainingMinutes})`，引擎每次成功放置后
// **以新的剩余量重新生成**候选。因此本文件里的每一个期望值都是"修复之后"的形状。
//
// ## 为什么断言的是行为而不是实现
//
// 每个用例都同时断言四件事：块时长列表、总时长、`proposal.unscheduled` 与
// `PlanValidator(...).validate(problem, proposal.blocks)` 的结果。四者必须互相自洽 ——
// R4 的本质正是"候选生成与最终校验读的不是同一份规则"。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  final zones = TimeZoneDatabase();
  final engine = DeterministicScheduleEngine(zones);

  /// 一天的起点（2026-10-05 是周一）。
  DateTime at(int dayOffset, int hour, [int minute = 0]) =>
      DateTime.utc(2026, 10, 5 + dayOffset, hour, minute);

  ScheduleProblem problem({
    required List<SchedulableTask> tasks,
    required TimeRange window,
    List<BusyInterval> fixed = const [],
    int dailyMovableTaskLimitMinutes = 600,
    List<EnergyWindow> energyWindows = const [],
  }) => ScheduleProblem(
    planningWindow: window,
    timeZoneId: 'UTC',
    tasks: tasks,
    fixedIntervals: fixed,
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: PlanningRules(
      energyWindows: energyWindows,
      // 睡眠 23:00–07:00：与下表里的空档不重叠，因此它不参与本文件的结论。
      sleepRange: LocalTimeRange(startMinute: 23 * 60, endMinute: 7 * 60),
      minimumSleepMinutes: 420,
      defaultFocusMinutes: 50,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: dailyMovableTaskLimitMinutes,
      weeklyLifeQuotaMinutes: 0,
      granularityMinutes: 5,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'dynamic-short-tail',
  );

  SchedulableTask task({
    required int requiredMinutes,
    int minChunk = 30,
    int maxChunk = 90,
    String id = 'long',
    TaskEnergyLevel energyLevel = TaskEnergyLevel.medium,
  }) => SchedulableTask(
    id: id,
    requiredMinutes: requiredMinutes,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: minChunk,
    maxChunkMinutes: maxChunk,
    energyLevel: energyLevel,
  );

  List<int> durationsOf(ScheduleProposal proposal, [String taskId = 'long']) =>
      proposal.blocks
          .where((block) => block.taskId == taskId)
          .map((block) => block.durationMinutes)
          .toList()
        ..sort();

  int scheduledOf(ScheduleProposal proposal, [String taskId = 'long']) =>
      proposal.blocks
          .where((block) => block.taskId == taskId)
          .fold(0, (sum, block) => sum + block.durationMinutes);

  int shortageOf(ScheduleProposal proposal, [String taskId = 'long']) =>
      proposal.unscheduled
          .where((item) => item.taskId == taskId)
          .fold(0, (sum, item) => sum + item.shortageMinutes);

  /// `PlanValidator` 的结果在**每个**用例里都要一起断言：R4 的形态是
  /// "候选生成接受、最终校验拒绝"，只断言其中一个就抓不到它。
  List<PlanningConflict> invalidOf(
    ScheduleProblem prob,
    ScheduleProposal proposal,
  ) => PlanValidator(zones)
      .validate(prob, proposal.blocks)
      .where((conflict) => conflict.code == ConflictCode.invalidInput)
      .toList();

  // ───────────────────────────────────────────────────────────────────────────
  // 一个固定空档形状：**五个空档**，用于 100／103 两条用例。
  //
  // | 空档 | 分钟 |
  // | --- | ---: |
  // | 00:00–01:00 | 60 |
  // | 02:00–03:00 | 60 |
  // | 05:30–08:00 | 150 |
  // | 15:30–23:00 | 450 |
  // | 23:30–24:00 | 30 |
  //
  // 用固定日程（而不是睡眠／保护时间）"切"出这些空档，是为了让用例的前提一眼可核对：
  // 空档边界就是 `fixedIntervals` 的边界。
  // ───────────────────────────────────────────────────────────────────────────
  List<BusyInterval> gapsFor(int dayOffset) => [
    BusyInterval(
      id: 'busy-$dayOffset-1',
      range: TimeRange(startUtc: at(dayOffset, 1), endUtc: at(dayOffset, 2)),
    ),
    BusyInterval(
      id: 'busy-$dayOffset-2',
      range: TimeRange(startUtc: at(dayOffset, 3), endUtc: at(dayOffset, 5, 30)),
    ),
    BusyInterval(
      id: 'busy-$dayOffset-3',
      range: TimeRange(startUtc: at(dayOffset, 8), endUtc: at(dayOffset, 15, 30)),
    ),
    BusyInterval(
      id: 'busy-$dayOffset-4',
      range: TimeRange(
        startUtc: at(dayOffset, 23),
        endUtc: at(dayOffset, 23, 30),
      ),
    ),
  ];

  group('R3/R4：长任务经过多轮放置后形成的短尾必须能排进去', () {
    test('100 / min30 / max30 ⇒ [30,30,30,10]、总时长 100、无缺口、校验通过', () {
      final t = task(requiredMinutes: 100, maxChunk: 30);
      final prob = problem(
        tasks: [t],
        window: TimeRange(startUtc: at(0, 0), endUtc: at(1, 0)),
        fixed: gapsFor(0),
      );
      final proposal = engine.generate(prob);

      expect(
        durationsOf(proposal),
        [10, 30, 30, 30],
        reason:
            '100 分钟、最小片段 30、粒度 5：合法形状只有 30+30+30+10，'
            '最后的 10 分钟是**唯一**的短尾。当前实现在循环外缓存了一份基于'
            '「初始 100 分钟」的候选集，剩余 10 分钟时不再生成 10 分钟候选，'
            '因此只能排出 30+30+30',
      );
      expect(scheduledOf(proposal), 100, reason: '容量充足（五个空档共 750 分钟）');
      expect(
        proposal.unscheduled,
        isEmpty,
        reason: '能排满就不该同时报"未安排"',
      );
      expect(
        invalidOf(prob, proposal),
        isEmpty,
        reason: 'R4：最终的 10 分钟短尾必须被校验器接受（它是全任务唯一的短尾）',
      );
      expect(proposal.metrics.isFullyFeasible, isTrue);
    });

    test('103 / min30 / max30 ⇒ [30,30,30,10]、总时长 100、缺口 3、校验通过', () {
      final t = task(requiredMinutes: 103, maxChunk: 30);
      final prob = problem(
        tasks: [t],
        window: TimeRange(startUtc: at(0, 0), endUtc: at(1, 0)),
        fixed: gapsFor(0),
      );
      final proposal = engine.generate(prob);

      expect(
        durationsOf(proposal),
        [10, 30, 30, 30],
        reason:
            '103 分钟在 5 分钟粒度下能排 100 分钟，形状与 100 分钟那条相同。'
            '当前实现只能排出 30+30+30=90，缺口被报成 13 而不是 3',
      );
      expect(scheduledOf(proposal), 100);
      expect(
        shortageOf(proposal),
        3,
        reason: '103 − 100 = 3：那 3 分钟是真实缺口，要如实报出来，绝不伪造 3 分钟块',
      );
      expect(
        proposal.blocks.every((block) => block.durationMinutes != 3),
        isTrue,
        reason: '3 分钟不足一个粒度 ⇒ 不得伪造片段',
      );
      expect(
        invalidOf(prob, proposal),
        isEmpty,
        reason: 'R4：10 分钟短尾合法，3 分钟缺口是"排不下"，不是"输入无效"',
      );
    });

    test('180 / min30 / max30 ⇒ 容量足够时缺口 0（逐轮重算不会提前停在半截）', () {
      // 七个 30 分钟空档（07:30–08:00 起每小时一次），共 210 分钟。
      final slots = <BusyInterval>[
        for (var index = 0; index < 7; index++)
          BusyInterval(
            id: 'busy-$index',
            range: TimeRange(
              startUtc: at(0, 7 + index, 30),
              endUtc: at(0, 8 + index),
            ),
          ),
      ];
      final t = task(requiredMinutes: 180, maxChunk: 30);
      final prob = problem(
        tasks: [t],
        window: TimeRange(startUtc: at(0, 7), endUtc: at(0, 15)),
        fixed: slots,
      );
      final proposal = engine.generate(prob);

      expect(
        scheduledOf(proposal),
        180,
        reason:
            '七个 30 分钟空档一共 210 分钟，180 分钟任务排得下：30×6。'
            '修复实现的失败形态是"某轮选中的时长让剩余量凑不出新一轮候选"，'
            '于是剩下的分钟永远排不进去',
      );
      // **不断言块的排列顺序**：七个空档等宽，先占哪一个由评分决定，属于实现细节。
      // 要钉的是"每个块都是 30 分钟、正好六个"。
      expect(
        durationsOf(proposal),
        [30, 30, 30, 30, 30, 30],
        reason: '在 30–30 与粒度 5 的约束下，唯一能排满 180 分钟的形状就是六个 30 分钟',
      );
      expect(
        proposal.blocks.where((block) => block.taskId == 'long'),
        hasLength(6),
        reason: '恰好六个块；多一个或少一个都说明剩余量没有被逐轮重算',
      );
      expect(
        proposal.unscheduled,
        isEmpty,
        reason: '容量足够 ⇒ 不得出现未安排',
      );
      expect(
        invalidOf(prob, proposal),
        isEmpty,
        reason: '六个块都在 [30, 30] 内且落在 5 分钟网格上',
      );
      expect(proposal.metrics.isFullyFeasible, isTrue);
    });

    test('180 / min30 / max90 ⇒ 每天一个 60 分钟空档时缺口 0（60+60+30+30）', () {
      // 三天，每天只有一个 60 分钟空档（07:00–08:00），其余全部被固定日程占住。
      final t = task(requiredMinutes: 180);
      final prob = problem(
        tasks: [t],
        window: TimeRange(startUtc: at(0, 7), endUtc: at(3, 7)),
        fixed: [
          for (var day = 0; day < 3; day++)
            BusyInterval(
              id: 'busy-$day',
              range: TimeRange(
                startUtc: at(day, 8),
                endUtc: at(day + 1, 7),
              ),
            ),
        ],
      );
      final proposal = engine.generate(prob);

      // 实测形状：**三个 60 分钟**（正好排满 180 分钟，因此这条用例没有缺口，
      // 不是红灯）。它钉住的是"形状"：合法解里最后的 30 分钟短尾是必需的，
      // 而修复前的候选集不会生成 30 分钟的短尾。
      expect(
        durationsOf(proposal),
        [30, 30, 60, 60],
        reason:
            '三天各一个 60 分钟空档，共 180 分钟容量、需排 180 分钟。'
            '多个合法形状都存在（三个 60 分钟也排得满），但修复的目标是'
            '"每轮按新剩余量重算候选"，因此最后一个 60 分钟需求必须能被'
            '拆成 30 + 30，而不是复用初始候选集里最大的 90/60',
      );
      expect(
        scheduledOf(proposal),
        180,
        reason: '容量正好够 ⇒ 必须排满（当前实现在某些空档形状下停在 120）',
      );
      expect(shortageOf(proposal), 0, reason: '容量足够时不得有缺口');
      expect(proposal.unscheduled, isEmpty);
      expect(
        invalidOf(prob, proposal),
        isEmpty,
        reason: '四个块都在 [30, 90] 内且落在 5 分钟网格上（R4）',
      );
      expect(proposal.metrics.isFullyFeasible, isTrue);
    });

    test('每天只有 30 分钟额度、任务要 210 分钟 ⇒ 缺口必须由真实容量解释', () {
      // 三天，每天一个 240 分钟空档（07:00–11:00），任务自己的
      // `maxMinutesPerLocalDay` 声明每天最多 30 分钟。
      final t = SchedulableTask(
        id: 'long',
        requiredMinutes: 210,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 30,
        maxMinutesPerLocalDay: 30,
      );
      final prob = problem(
        tasks: [t],
        window: TimeRange(startUtc: at(0, 7), endUtc: at(3, 11)),
        fixed: [
          for (var day = 0; day < 3; day++)
            BusyInterval(
              id: 'busy-$day',
              range: TimeRange(startUtc: at(day, 11), endUtc: at(day, 23)),
            ),
        ],
      );
      final proposal = engine.generate(prob);

      // 实测：**七个 30 分钟块**（每天不只一个）。原因是放置循环里的
      // `relaxedDailyQuota` 对非 `even` 策略的任务**整段放开了每日配额**，
      // 于是 `maxMinutesPerLocalDay` 在放置阶段形同不存在（只在最终校验时生效）。
      expect(
        durationsOf(proposal),
        [30, 30, 30],
        reason:
            '任务自己声明"每天最多 30 分钟"，三天就该只排 90 分钟。'
            '当前实现把三个 240 分钟空档排成了 210 分钟（七个 30 分钟块），'
            '每日配额在放置阶段被 `relaxedDailyQuota` 放开了',
      );
      expect(scheduledOf(proposal), 90, reason: '3 天 × 30 分钟');
      expect(shortageOf(proposal), 120, reason: '210 − 90 = 120');
      expect(
        proposal.unscheduled.single.primaryReason.code,
        UnscheduledReasonCode.dailyLimitReached,
        reason:
            '最终块集合被每日上限挡住，主原因必须与最终状态一致；'
            '不得因为循环中途试过别的位置就换成别的说法（R5）',
      );
      expect(
        invalidOf(prob, proposal),
        isEmpty,
        reason: '三个 30 分钟块都合法，缺口不是"输入无效"',
      );
    });

    test('remaining=40 而最长空档只有 20 分钟 ⇒ 不得生成 20 分钟短块', () {
      // 空档只有一个 20 分钟窗口：12:00–14:00 的窗口里 12:00–13:40 被固定日程占住。
      final t = task(requiredMinutes: 40, maxChunk: 40);
      final prob = problem(
        tasks: [t],
        window: TimeRange(startUtc: at(0, 12), endUtc: at(0, 14)),
        fixed: [
          BusyInterval(
            id: 'busy',
            range: TimeRange(startUtc: at(0, 12), endUtc: at(0, 13, 40)),
          ),
        ],
      );
      final proposal = engine.generate(prob);

      expect(
        proposal.blocks.where((block) => block.taskId == 'long'),
        isEmpty,
        reason:
            '这一项的剩余量（40 分钟）**不少于**最小片段（30 分钟），'
            '因此短余量宽免不适用：20 分钟空档既排不出普通片段，也不是"唯一最终短尾"。'
            '当前实现却按 `task.requiredMinutes < minChunk` 的旧口径把它做成 20 分钟块',
      );
      expect(scheduledOf(proposal), 0);
      expect(shortageOf(proposal), 40);
      expect(
        invalidOf(prob, proposal),
        isEmpty,
        reason: '"排不下"是缺口，不是"排程输入无效"——两者处置完全不同',
      );
    });

    test('高精力任务只有普通时段可用时仍能完整安排（精力是软偏好，不是硬过滤）', () {
      // 空档只有 [01:00,02:00) 与 [07:30,08:30)；高精力窗口 [01:00,02:00) 之外
      // 全是低精力时段。任务需要一个 60 分钟的片段。
      final t = task(
        requiredMinutes: 60,
        maxChunk: 60,
        id: 'high',
        energyLevel: TaskEnergyLevel.high,
      );
      final prob = problem(
        tasks: [t],
        window: TimeRange(startUtc: at(0, 0), endUtc: at(1, 0)),
        fixed: [
          BusyInterval(
            id: 'e1',
            range: TimeRange(startUtc: at(0, 0), endUtc: at(0, 1)),
          ),
          BusyInterval(
            id: 'e2',
            range: TimeRange(startUtc: at(0, 2), endUtc: at(0, 7, 30)),
          ),
          BusyInterval(
            id: 'e3',
            range: TimeRange(startUtc: at(0, 8, 30), endUtc: at(0, 23)),
          ),
          BusyInterval(
            id: 'e4',
            range: TimeRange(startUtc: at(0, 23), endUtc: at(1, 0)),
          ),
        ],
        energyWindows: [
          EnergyWindow(
            range: LocalTimeRange(startMinute: 60, endMinute: 120),
            level: EnergyLevel.high,
          ),
          EnergyWindow(
            range: LocalTimeRange(startMinute: 120, endMinute: 540),
            level: EnergyLevel.low,
          ),
        ],
      );
      final proposal = engine.generate(prob);

      expect(
        scheduledOf(proposal, 'high'),
        60,
        reason:
            '计划 §1.3："高精力导致其它时段全部不可用"没有代码证据——精力是软评分。'
            '因此高精力任务落在普通时段也必须排满，而不是被过滤成缺口',
      );
      expect(
        durationsOf(proposal, 'high'),
        [60],
        reason: '60 分钟的片段必须是一次完整安排（唯一 60 分钟空档）',
      );
      expect(
        proposal.unscheduled.where((item) => item.taskId == 'high'),
        isEmpty,
      );
      expect(
        invalidOf(prob, proposal),
        isEmpty,
        reason: '60 分钟在 [30, 60] 内',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Task 1 Step 3：**陈旧拒绝证据**（R5／R6）。
  //
  // `schedule_engine.dart` 的 `rejectionEvidence[taskId]` 按 reason code 跨轮次累计，
  // **成功选择块不会清空旧证据**：
  //
  // ```dart
  // void recordRejection(String taskId, UnscheduledReason reason) {
  //   (rejectionEvidence[taskId] ??= {})[reason.code] = reason;
  // }
  // ```
  //
  // 而放置循环的语义是"**试**一个候选"：判据不成立时先登记一条证据，该候选随后仍可能
  // 被选中（`allowUnschedulableLeftover` 的第二遍就是这么做的）。于是一条**在成功放置
  // 之前**记下的、基于"当时那个剩余量"的拒绝，会一路活到最终结论里，甚至因为
  // `unscheduledReasonPriority` 里的位次更高而**盖过**真正的最终约束。
  // ───────────────────────────────────────────────────────────────────────────
  group('R5/R6：最终主原因必须由最终块集合解释，不得沿用旧轮次的拒绝证据', () {
    test('第一轮的"最小片段"拒绝不得盖过最终真实的"每日上限"', () {
      // 两天窗口、每日可移动上限 100 分钟。任务 240 分钟、片段 30–90。
      //
      // 第一天的空档：07:00–23:00（除 07:30–08:00 被固定日程占住）。
      // 放置过程（当前实现）：
      //   ① 90 分钟落在 08:00；② 再试 60 分钟 ⇒ 剩 90 分钟、60+90 > 100 ⇒ dailyLimitReached；
      //   ③ 改放 30 分钟 ⇒ 当天 120 > 100 也不行 ⇒ 换第二天，90 分钟落在 07:00；
      //   ④ 当天只剩 10 分钟额度 ⇒ 60 分钟、30 分钟候选都会在循环里留下证据。
      // 最终块集合是 90 + 90 = 180，真实缺口 60 分钟，而**真正**让它排不下去的是
      // 每日上限（第二天还有 10 分钟额度、第三天根本不在窗口里）。
      final t = task(requiredMinutes: 240);
      final prob = problem(
        tasks: [t],
        window: TimeRange(startUtc: at(0, 0), endUtc: at(2, 0)),
        fixed: [
          BusyInterval(
            id: 'busy',
            range: TimeRange(startUtc: at(0, 7, 30), endUtc: at(0, 8)),
          ),
        ],
        dailyMovableTaskLimitMinutes: 100,
      );
      final proposal = engine.generate(prob);
      final unscheduled = proposal.unscheduled.single;

      expect(scheduledOf(proposal), 180, reason: '两天各只能放 90 分钟（每日上限 100）');
      expect(unscheduled.shortageMinutes, 60);

      expect(
        unscheduled.primaryReason.code,
        isNot(UnscheduledReasonCode.minimumChunkTooLarge),
        reason:
            '这条证据是**旧轮次**的：它在第一轮试放 60 分钟时被登记'
            '（那一次会留下 30 分钟余量，被"最终余量不足"判据挡下），'
            '但 60 分钟当时并没有被选中，最终块集合里也没有它的位置。'
            '真正解释最终缺口的是每日上限。当前实现按固定优先级挑选，'
            '`minimumChunkTooLarge`（第 4 位）盖过了 `dailyLimitReached`（第 5 位）',
      );
      expect(
        unscheduled.reasons.map((reason) => reason.code),
        isNot(contains(UnscheduledReasonCode.minimumChunkTooLarge)),
        reason:
            '最终证据里不该留着"在成功放置之前、按当时的剩余量算出来"的拒绝。'
            '实测当前实现留下的那条是 `minimumChunkTooLarge(required=65, available=60)`：'
            '它的 65 分钟属于**第一轮的剩余量**，而最终块集合的剩余量是 60 分钟——'
            '两个数字互相矛盾，用户据此无法判断该改什么',
      );
      expect(
        invalidOf(prob, proposal),
        isEmpty,
        reason: 'R6：最终块集合本身必须合法（90 分钟在 [30, 90] 内）',
      );
    });
  });
}
