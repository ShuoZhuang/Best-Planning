import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/plan_differ.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

void main() {
  final zones = TimeZoneDatabase();
  final engine = DeterministicScheduleEngine(zones);

  /// 本文件所有 `ScheduleProblem` 都只需要"一份规则铺满整个窗口"的逐日策略
  /// （夹具钉的是排程行为，不是规则解析）。
  Map<DateTime, DailySchedulingPolicy> policiesFor(
    TimeRange window,
    String zoneId,
    PlanningRules rules,
  ) => dailyPoliciesForWindow(
    zones: zones,
    window: window,
    rules: rules,
    timeZoneId: zoneId,
  );

  Map<DateTime, int> quotasFor(
    TimeRange window,
    String zoneId,
    PlanningRules rules,
  ) => weeklyLifeQuotasForWindow(
    zones: zones,
    window: window,
    rules: rules,
    timeZoneId: zoneId,
  );

  test('golden week keeps breaks between chunks and reports the shortfall', () {
    final fixture = jsonDecode(
      File('test/fixtures/scheduling/golden_week.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final problem = _problemFromFixture(fixture);

    final proposal = engine.generate(problem);
    final expected = fixture['expected']! as Map<String, Object?>;
    final expectedBlocks = (expected['blocks']! as List<Object?>)
        .cast<Map<String, Object?>>();

    expect(proposal.algorithmVersion, expected['algorithmVersion']);
    // research 需要的 360 分钟恰好等于周二唯一的空闲窗口（12:00–18:00）。
    // 保留 10 分钟片段间休息后不可能排满全部时长，因此必须如实报告缺口，
    // 而不是回到"四段 90 分钟首尾相连"的无休息排法（FR-SCHED-05、产品原则 4.1）。
    expect(proposal.metrics.isFullyFeasible, expected['fullyFeasible']);
    expect(
      proposal.unscheduled
          .map(
            (item) => {
              'taskId': item.taskId,
              'shortageMinutes': item.shortageMinutes,
            },
          )
          .toList(),
      expected['unscheduled'],
    );
    expect(
      proposal.blocks
          .map(
            (block) => {
              'taskId': block.taskId,
              'start': block.startUtc.toIso8601String(),
              'end': block.endUtc.toIso8601String(),
              'explanationCode': block.explanationCode,
            },
          )
          .toList(),
      expectedBlocks,
    );
    expect(
      proposal.explanations.map((item) => item.code),
      containsAll(['deadline_and_progress', 'life_quota_gap']),
    );

    final researchBlocks =
        proposal.blocks.where((block) => block.taskId == 'research').toList()
          ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
    expect(researchBlocks.length, greaterThan(1));
    for (var index = 1; index < researchBlocks.length; index++) {
      final gap = researchBlocks[index].startUtc
          .difference(researchBlocks[index - 1].endUtc)
          .inMinutes;
      expect(gap, greaterThanOrEqualTo(problem.rules.breakMinutes));
    }
  });

  test('相同任务的两段专注之间保留 breakMinutes 休息', () {
    final day = DateTime.utc(2026, 10, 5);
    final window = TimeRange(
      startUtc: day.add(const Duration(hours: 9)),
      endUtc: day.add(const Duration(hours: 18)),
    );
    const zoneId = 'UTC';
    final rules = PlanningRules(
      energyWindows: [
        EnergyWindow(
          range: LocalTimeRange(startMinute: 540, endMinute: 720),
          level: EnergyLevel.high,
        ),
      ],
      sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
      minimumSleepMinutes: 420,
      defaultFocusMinutes: 50,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
    );
    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: const [
        SchedulableTask(
          id: 'deep-work',
          requiredMinutes: 120,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 60,
          maxChunkMinutes: 60,
        ),
      ],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: rules,
      dailyPolicies: policiesFor(window, zoneId, rules),
      weeklyLifeQuotaByWeekStart: quotasFor(window, zoneId, rules),
      preferences: const PreferenceProfile(),
      inputHash: 'rest-gap-v1',
    );

    final blocks = [...engine.generate(problem).blocks]
      ..sort((a, b) => a.startUtc.compareTo(b.startUtc));

    expect(blocks.length, 2);
    expect(
      blocks[1].startUtc.difference(blocks[0].endUtc).inMinutes,
      greaterThanOrEqualTo(problem.rules.breakMinutes),
    );
  });

  test('same input and reversed input order produce identical output', () {
    final fixture = jsonDecode(
      File('test/fixtures/scheduling/golden_week.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final problem = _problemFromFixture(fixture);
    final expected = _signature(engine.generate(problem));

    for (var run = 0; run < 100; run++) {
      expect(_signature(engine.generate(problem)), expected);
    }

    final reversed = ScheduleProblem(
      planningWindow: problem.planningWindow,
      timeZoneId: problem.timeZoneId,
      tasks: problem.tasks.reversed.toList(),
      fixedIntervals: problem.fixedIntervals.reversed.toList(),
      protectedIntervals: problem.protectedIntervals.reversed.toList(),
      lockedBlocks: problem.lockedBlocks.reversed.toList(),
      rules: problem.rules,
      dailyPolicies: policiesFor(
        problem.planningWindow,
        problem.timeZoneId,
        problem.rules,
      ),
      weeklyLifeQuotaByWeekStart: quotasFor(
        problem.planningWindow,
        problem.timeZoneId,
        problem.rules,
      ),
      preferences: problem.preferences,
      inputHash: problem.inputHash,
    );
    expect(_signature(engine.generate(reversed)), expected);
  });

  test('任意两个任务块之间保留休息，不区分任务类型', () {
    final day = DateTime.utc(2026, 10, 5);

    ScheduleProblem build(List<SchedulableTask> tasks) {
      final window = TimeRange(
        startUtc: day.add(const Duration(hours: 9)),
        endUtc: day.add(const Duration(hours: 18)),
      );
      const zoneId = 'UTC';
      final rules = PlanningRules(
        energyWindows: [
          EnergyWindow(
            range: LocalTimeRange(startMinute: 540, endMinute: 720),
            level: EnergyLevel.high,
          ),
        ],
        sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
        minimumSleepMinutes: 420,
        defaultFocusMinutes: 50,
        breakMinutes: 10,
        dailyMovableTaskLimitMinutes: 600,
        weeklyLifeQuotaMinutes: 0,
      );
      return ScheduleProblem(
        planningWindow: window,
        timeZoneId: zoneId,
        tasks: tasks,
        fixedIntervals: const [],
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: policiesFor(window, zoneId, rules),
        weeklyLifeQuotaByWeekStart: quotasFor(window, zoneId, rules),
        preferences: const PreferenceProfile(),
        inputHash: 'rest-gap-cross-task',
      );
    }

    SchedulableTask single(String id, {bool life = false}) => SchedulableTask(
      id: id,
      requiredMinutes: 60,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 60,
      maxChunkMinutes: 60,
      priority: TaskPriority.high,
      isLifeTask: life,
    );

    List<int> gaps(List<SchedulableTask> tasks) {
      final blocks = [...engine.generate(build(tasks)).blocks]
        ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
      return [
        for (var index = 1; index < blocks.length; index++)
          blocks[index].startUtc.difference(blocks[index - 1].endUtc).inMinutes,
      ];
    }

    // 两个不同的任务之间同样需要休息。
    expect(gaps([single('work-a'), single('work-b')]), [10]);
    // 连续多个任务之间都要休息。
    expect(gaps([single('work-a'), single('work-b'), single('work-c')]), [
      10,
      10,
    ]);
    // 不再按任务类型区分：生活任务之间、以及生活任务与普通任务之间都要休息。
    expect(gaps([single('work-a'), single('fun', life: true)]), [10]);
    expect(gaps([single('fun-a', life: true), single('fun-b', life: true)]), [
      10,
    ]);
  });

  test('远期任务会排入可排的最小量，而不是整周 0 分钟', () {
    final day = DateTime.utc(2026, 10, 5);

    ScheduleProblem build(SchedulableTask task) {
      final window = TimeRange(
        startUtc: day,
        endUtc: day.add(const Duration(days: 7)),
      );
      const zoneId = 'UTC';
      final rules = PlanningRules(
        energyWindows: [
          EnergyWindow(
            range: LocalTimeRange(startMinute: 540, endMinute: 720),
            level: EnergyLevel.high,
          ),
        ],
        sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
        minimumSleepMinutes: 420,
        defaultFocusMinutes: 50,
        breakMinutes: 10,
        dailyMovableTaskLimitMinutes: 600,
        weeklyLifeQuotaMinutes: 0,
      );
      return ScheduleProblem(
        planningWindow: window,
        timeZoneId: zoneId,
        tasks: [task],
        fixedIntervals: const [],
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: policiesFor(window, zoneId, rules),
        weeklyLifeQuotaByWeekStart: quotasFor(window, zoneId, rules),
        preferences: const PreferenceProfile(),
        inputHash: 'far-deadline-target',
      );
    }

    // 均匀推进量低于最小时长时，目标会被抬到"确实可排的最小量"。
    //
    // **期望值是 120 而不是 30**（算法 17 修正）：修复前 `capacityForRange` 只在
    // 已经算好的 `analysis.slots` 里筛，于是"窗口之外的那 23 天"被当成有容量
    // （实测 `capacityAfterHorizonBeforeDue = 22080`），一个 120 分钟、截止在 30 天后的
    // 任务因此算出 `pacedNow = 28` 并被抬到 30 —— **只排 30 分钟**。
    // 窗口之外没有任何可排时段，把它算进"截止前总容量"会让近期推进量被系统性低估。
    // 裁剪到窗口之后 `after = 0`，同一个任务按"这一周有多少容量"推进，一周内排满 120。
    final splittable = engine.generate(
      build(
        SchedulableTask(
          id: 'far-splittable',
          requiredMinutes: 120,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
          dueAtUtc: day.add(const Duration(days: 30)),
        ),
      ),
    );
    expect(splittable.metrics.scheduledMinutes, 120);
    expect(splittable.unscheduled, isEmpty);

    // 不可拆分任务只有整块一种候选，因此要么整体排入要么排不进。
    final continuous = engine.generate(
      build(
        SchedulableTask(
          id: 'far-continuous',
          requiredMinutes: 120,
          splitMode: TaskSplitMode.continuous,
          minChunkMinutes: 120,
          maxChunkMinutes: 120,
          dueAtUtc: day.add(const Duration(days: 30)),
        ),
      ),
    );
    expect(continuous.metrics.scheduledMinutes, 120);

    // 窗口内到期的任务不受影响。
    final near = engine.generate(
      build(
        SchedulableTask(
          id: 'near',
          requiredMinutes: 120,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
          dueAtUtc: day.add(const Duration(days: 2)),
        ),
      ),
    );
    expect(near.metrics.scheduledMinutes, 120);
  });

  test('类别切换成本生效：避开与其它任务相邻的位置', () {
    final day = DateTime.utc(2026, 10, 5);
    // 跨越两天：第二天存在"同一本地日内没有相邻任务"的位置。
    final window = TimeRange(
      startUtc: day.add(const Duration(hours: 9)),
      endUtc: day.add(const Duration(days: 1, hours: 18)),
    );
    const zoneId = 'UTC';
    final rules = PlanningRules(
      // 精力区间为空，使两个候选的精力匹配没有差别。
      energyWindows: const [],
      sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
      minimumSleepMinutes: 420,
      defaultFocusMinutes: 50,
      breakMinutes: 10,
      dailyMovableTaskLimitMinutes: 600,
      weeklyLifeQuotaMinutes: 0,
    );
    final problem = ScheduleProblem(
      planningWindow: window,
      timeZoneId: zoneId,
      tasks: const [
        SchedulableTask(
          id: 'work',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 60,
          maxChunkMinutes: 60,
          priority: TaskPriority.high,
          energyLevel: TaskEnergyLevel.high,
        ),
      ],
      fixedIntervals: const [],
      protectedIntervals: const [],
      // 另一任务的已锁定块，使第一天的候选都与"其它任务"相邻。
      lockedBlocks: [
        PlannedBlock(
          id: 'locked-other',
          taskId: 'other',
          range: TimeRange(
            startUtc: day.add(const Duration(hours: 11)),
            endUtc: day.add(const Duration(hours: 12)),
          ),
          locked: true,
        ),
      ],
      rules: rules,
      dailyPolicies: policiesFor(window, zoneId, rules),
      weeklyLifeQuotaByWeekStart: quotasFor(window, zoneId, rules),
      preferences: const PreferenceProfile(),
      inputHash: 'switch-cost-discriminator',
    );

    final work = engine
        .generate(problem)
        .blocks
        .where((block) => block.taskId == 'work')
        .toList();

    // 两个候选的覆盖度与精力匹配完全相同，只有切换成本能区分它们；
    // 若该因子未生效，会按开始时间决胜而落在第一天。
    expect(work, hasLength(1));
    expect(
      work.single.startUtc.isBefore(day.add(const Duration(days: 1))),
      isFalse,
      reason: '应避开与其它任务相邻的第一天',
    );
  });

  test('移动成本生效：倾向复现已确认但未锁定的位置', () {
    final day = DateTime.utc(2026, 10, 5);
    // 已确认但未锁定的块放在较晚时段，使"复现它"与"按开始时间择优"给出不同答案。
    final existing = PlannedBlock(
      id: 'existing-block',
      taskId: 'work',
      range: TimeRange(
        startUtc: day.add(const Duration(hours: 10)),
        endUtc: day.add(const Duration(hours: 11)),
      ),
    );

    ScheduleProblem build({required bool withExisting}) {
      final window = TimeRange(
        startUtc: day.add(const Duration(hours: 9)),
        endUtc: day.add(const Duration(hours: 12)),
      );
      const zoneId = 'UTC';
      final rules = PlanningRules(
        energyWindows: const [],
        sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
        minimumSleepMinutes: 420,
        defaultFocusMinutes: 50,
        breakMinutes: 10,
        dailyMovableTaskLimitMinutes: 600,
        weeklyLifeQuotaMinutes: 0,
      );
      return ScheduleProblem(
        planningWindow: window,
        timeZoneId: zoneId,
        tasks: const [
          SchedulableTask(
            id: 'work',
            requiredMinutes: 60,
            splitMode: TaskSplitMode.splittable,
            minChunkMinutes: 60,
            maxChunkMinutes: 60,
            priority: TaskPriority.high,
            energyLevel: TaskEnergyLevel.high,
          ),
        ],
        fixedIntervals: const [],
        protectedIntervals: const [],
        lockedBlocks: const [],
        existingBlocks: withExisting ? [existing] : const [],
        rules: rules,
        dailyPolicies: policiesFor(window, zoneId, rules),
        weeklyLifeQuotaByWeekStart: quotasFor(window, zoneId, rules),
        preferences: const PreferenceProfile(),
        inputHash: 'moving-cost-ab',
      );
    }

    DateTime placement(ScheduleProblem problem) =>
        engine.generate(problem).blocks.single.startUtc;

    // 不提供已确认块时，两个候选同分，按开始时间决胜 → 最早位置。
    expect(
      placement(build(withExisting: false)),
      day.add(const Duration(hours: 9)),
    );
    // 提供之后，占用已确认块的位置不计移动代价，因此原样复现 → 10:00。
    expect(
      placement(build(withExisting: true)),
      day.add(const Duration(hours: 10)),
      reason: '移动成本应使引擎复现已确认的位置而不是漂移到更早时段',
    );
  });

  test('PlanDiffer identifies added, moved and removed blocks', () {
    final day = DateTime.utc(2026, 10, 5);
    final current = [
      PlannedBlock(
        id: 'kept',
        taskId: 'task-a',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 9)),
          endUtc: day.add(const Duration(hours: 10)),
        ),
      ),
      PlannedBlock(
        id: 'removed',
        taskId: 'task-b',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 11)),
          endUtc: day.add(const Duration(hours: 12)),
        ),
      ),
    ];
    final proposed = [
      PlannedBlock(
        id: 'kept',
        taskId: 'task-a',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 10)),
          endUtc: day.add(const Duration(hours: 11)),
        ),
      ),
      PlannedBlock(
        id: 'added',
        taskId: 'task-c',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 12)),
          endUtc: day.add(const Duration(hours: 13)),
        ),
      ),
    ];

    final diff = const PlanDiffer().diff(current, proposed);

    expect(diff.changes.map((item) => item.type), [
      PlanChangeType.moved,
      PlanChangeType.removed,
      PlanChangeType.added,
    ]);
  });

  // T4：golden fixture 固定 `"timeZoneId": "UTC"`，因此精确 golden 只在 UTC 下跑过。
  // 这里用**同一份 fixture**、只把时区换成 America/New_York（观测夏令时），并断言
  // **不依赖精确输出**的不变量。为什么不直接加第二个精确 golden：本 fixture 内嵌
  // `expected.blocks`，新时区的期望值只能由引擎自己生成，那样的 golden 会永远通过——
  // 它只能钉住未来回归，不能验证当前行为。
  //
  // **这条用例的限界（变异验证得出，不是推测）**：把 `availability_builder` 里
  // "本地钟点 → UTC"的换算改成忽略时区（即当作 UTC 用），本用例**依然通过**。原因是这份
  // fixture 容量宽裕（7 天 × 每日 8 小时余量），引擎把块放进"两种解释都允许"的区间就够了，
  // 两种语义下都满足不变量。因此它**不能**证明时区换算正确，只是一条非 UTC 下的冒烟检查。
  // 要真正判别，需要一个**在两种解释下自由时段不同且容量紧张**的场景——那要新造 fixture，
  // 属"先界定场景再写"，已登记为 T4 的剩余部分。
  test('golden week 换到非 UTC 时区后，不变量仍然成立', () {
    final fixture = jsonDecode(
      File('test/fixtures/scheduling/golden_week.json').readAsStringSync(),
    ) as Map<String, Object?>;
    // 只改时区：规则里的睡眠与精力是**本地钟点**（20:00–08:00 等），因此在纽约它们对应的
    // UTC 区间与在 UTC 下相差 4 小时。若引擎把本地钟点当 UTC 用，下面的睡眠断言会失败。
    final problem = _problemFromFixture({
      ...fixture,
      'timeZoneId': 'America/New_York',
    });

    final proposal = engine.generate(problem);

    // ① 块之间互不重叠，且都落在规划窗口内。
    final ordered = [...proposal.blocks]
      ..sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
    for (var index = 0; index < ordered.length; index++) {
      final block = ordered[index];
      expect(
        block.range.startUtc.isBefore(problem.planningWindow.endUtc),
        isTrue,
        reason: '块 ${block.id} 落在窗口之外',
      );
      expect(block.range.endUtc.isAfter(block.range.startUtc), isTrue);
      if (index > 0) {
        expect(
          ordered[index - 1].range.endUtc.isAfter(block.range.startUtc),
          isFalse,
          reason: '块 ${ordered[index - 1].id} 与 ${block.id} 重叠',
        );
      }
    }

    // ② 睡眠按**当地钟点**成立：20:00–08:00（跨零点）在纽约对应 00:00Z–12:00Z，
    //    因此没有块可以落进那个区间。
    final localStart = zones.toLocal(
      problem.planningWindow.startUtc,
      problem.timeZoneId,
    );
    for (var dayOffset = -1; dayOffset <= 8; dayOffset++) {
      final day = DateTime(
        localStart.year,
        localStart.month,
        localStart.day,
      ).add(Duration(days: dayOffset));
      final sleepStart = zones.localDateTimeToUtc(
        day,
        problem.rules.sleepRange.startMinute,
        problem.timeZoneId,
      );
      final sleepEnd = zones.localDateTimeToUtc(
        day.add(const Duration(days: 1)),
        problem.rules.sleepRange.endMinute,
        problem.timeZoneId,
      );
      for (final block in proposal.blocks) {
        expect(
          block.range.startUtc.isBefore(sleepEnd) &&
              block.range.endUtc.isAfter(sleepStart),
          isFalse,
          reason:
              '块 ${block.id} 落入当地睡眠区间 '
              '${sleepStart.toIso8601String()}–${sleepEnd.toIso8601String()}',
        );
      }
    }

    // ③ 每个任务：已排时长 + 未排缺口 = 需求时长（缺口必须如实报告，不能悄悄吞掉）。
    for (final task in problem.tasks) {
      final scheduled = proposal.blocks
          .where((block) => block.taskId == task.id)
          .fold<int>(0, (sum, block) => sum + block.range.durationMinutes);
      final shortage = proposal.unscheduled
          .where((item) => item.taskId == task.id)
          .fold<int>(0, (sum, item) => sum + item.shortageMinutes);
      expect(
        scheduled + shortage,
        task.requiredMinutes,
        reason: '任务 ${task.id} 的已排与缺口之和不等于需求时长',
      );
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 计划 `2026-10-16-capacity-aware-hierarchical-scheduler-repair.md` Task 1 Step 3：
  // **普通任务（`unconstrained`）的日期选择必须考虑日负载**。
  //
  // 算法 16 的候选评分不含任何跨日负载项，"选哪一天"完全由最早开始时间打破平局，
  // 于是天然向窗口前部聚集（计划 §1.2 第 4 条）。用户看到的是「工作日越来越挤、
  // 周末整周空着」，而不是「容量不够」。
  // ─────────────────────────────────────────────────────────────────────────────
  group('普通任务的跨日负载（Task 1 Step 3）', () {
    const zoneId = 'Asia/Shanghai';
    const licensedPerDay = 120;
    const weekdayBusy = 50;
    const weekdayGapEndMinute = 8 * 60 + 70;

    DateTime midnight(int day) =>
        zones.localMidnightToUtc(DateTime(2026, 10, day), zoneId);
    DateTime localAt(int day, int minuteOfDay) =>
        zones.localDateTimeToUtc(DateTime(2026, 10, day), minuteOfDay, zoneId);

    ScheduleProblem weekProblem() {
      final window = TimeRange(startUtc: midnight(5), endUtc: midnight(12));
      final rules = PlanningRules(
        energyWindows: const [],
        sleepRange: LocalTimeRange(startMinute: 0, endMinute: 6 * 60),
        minimumSleepMinutes: 60,
        defaultFocusMinutes: 60,
        breakMinutes: 10,
        dailyMovableTaskLimitMinutes: licensedPerDay,
        weeklyLifeQuotaMinutes: 0,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
        granularityMinutes: 5,
      );
      return ScheduleProblem(
        planningWindow: window,
        timeZoneId: zoneId,
        tasks: [
          SchedulableTask(
            id: 'ordinary-a',
            requiredMinutes: 150,
            splitMode: TaskSplitMode.splittable,
            minChunkMinutes: 30,
            maxChunkMinutes: 90,
            dueAtUtc: midnight(12),
          ),
        ],
        // 工作日：空档 08:00–09:10（70 分钟），其余被固定日程占住；
        // 周末整天空着。用 10 分钟片段间休息，因此 70 分钟只放得下两个 30 分钟片段。
        fixedIntervals: [
          for (var day = 5; day <= 9; day++)
            BusyInterval(
              id: 'occupied-$day',
              range: TimeRange(
                startUtc: localAt(day, weekdayGapEndMinute),
                endUtc: localAt(day, weekdayGapEndMinute + weekdayBusy),
              ),
            ),
        ],
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: policiesFor(window, zoneId, rules),
        weeklyLifeQuotaByWeekStart: quotasFor(window, zoneId, rules),
        preferences: const PreferenceProfile(),
        inputHash: 'capacity-aware-week-engine-v1',
      );
    }

    test('工作日负载高、周末空闲时，块必须落到周末', () {
      final problem = weekProblem();
      final proposal = engine.generate(problem);

      final byDay = <int, int>{for (var day = 5; day <= 11; day++) day: 0};
      for (final block in proposal.blocks) {
        final local = zones.toLocal(block.startUtc, zoneId);
        if (local.month != 10) continue;
        final current = byDay[local.day];
        if (current == null) continue;
        byDay[local.day] = current + block.durationMinutes;
      }

      expect(
        byDay.values.fold<int>(0, (sum, value) => sum + value),
        150,
        reason: '周末每天 120 分钟合法容量，目标必须完整排下；实际 $byDay',
      );
      expect(
        byDay[10]! + byDay[11]!,
        greaterThan(0),
        reason:
            '周末负载 0%、工作日负载约 42%；至少一个块必须落到周末。'
            '修复前工作日会被堆满而周末保持为 0（实际 $byDay）',
      );
      for (final day in [5, 6, 7, 8, 9]) {
        expect(
          byDay[day]!,
          lessThanOrEqualTo(60),
          reason:
              '工作日空档 70 分钟只放得下两块，单日新增不得超过 60 分钟；'
              '第 $day 日加到 ${byDay[day]}（实际 $byDay）',
        );
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 计划 §2.3 / Task 6：**诊断数据必须随提案走到预览**。
  //
  // Task 5 把"为什么排不下"重写成最终诊断，但引擎算完就把它丢掉了：预览层只能再次猜原因，
  // 或者干脆不给证据——用户盯着日历上的空白，页面却说不出它为什么空着（§1.2 U4）。
  //
  // 这一组钉住两件事：
  //   ① 引擎产出的提案带着**那件有缺口任务的** excludedGaps（与 `unscheduled` 对得上）；
  //   ② 三个 `with*` 包装方法原样传递它（`PlanningService` 生成后就会包一层规则覆盖／
  //      延后要求，丢掉诊断等于预览永远看不到证据）。
  // ─────────────────────────────────────────────────────────────────────────────
  group('最终诊断随提案走', () {
    /// 一件排不进任何片段的连续任务：窗口只有 30 分钟，它要求一次做完 60 分钟。
    ScheduleProblem shortWindowProblem() {
      final day = DateTime.utc(2026, 10, 5);
      final window = TimeRange(
        startUtc: day.add(const Duration(hours: 9)),
        endUtc: day.add(const Duration(hours: 9, minutes: 30)),
      );
      const zoneId = 'UTC';
      final rules = PlanningRules(
        energyWindows: const [],
        sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
        minimumSleepMinutes: 420,
        defaultFocusMinutes: 50,
        breakMinutes: 0,
        dailyMovableTaskLimitMinutes: 600,
        weeklyLifeQuotaMinutes: 0,
      );
      return ScheduleProblem(
        planningWindow: window,
        timeZoneId: zoneId,
        tasks: const [
          SchedulableTask(
            id: 'too-long',
            requiredMinutes: 60,
            splitMode: TaskSplitMode.continuous,
            minChunkMinutes: 60,
            maxChunkMinutes: 60,
          ),
        ],
        fixedIntervals: const [],
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: policiesFor(window, zoneId, rules),
        weeklyLifeQuotaByWeekStart: quotasFor(window, zoneId, rules),
        preferences: const PreferenceProfile(),
        inputHash: 'diagnostics-travel-with-proposal',
      );
    }

    test('引擎产出的提案带着该任务的 excludedGaps', () {
      final problem = shortWindowProblem();
      final proposal = engine.generate(problem);

      expect(proposal.unscheduled, hasLength(1));
      final shortage = proposal.unscheduled.single;
      final diagnostics = proposal.placementDiagnostics[shortage.taskId];

      expect(diagnostics, isNotNull, reason: '诊断必须在提案里，否则预览无从展示证据');
      expect(
        diagnostics!.remainingMinutes,
        shortage.shortageMinutes,
        reason: '诊断的剩余量必须等于同一条缺口的缺口分钟',
      );
      expect(
        diagnostics.excludedGaps,
        isNotEmpty,
        reason: '"这一段为什么用不上"必须有证据：否则预览只能说一句无法行动的话',
      );
      // 证据里的区间必须落在**可见的**规划窗口内：让用户去找一段根本不在本次范围内的空档，
      // 比不给证据更糟。
      for (final gap in diagnostics.excludedGaps) {
        expect(
          gap.range.startUtc.isBefore(problem.planningWindow.endUtc),
          isTrue,
          reason: '空档 ${gap.range.startUtc.toIso8601String()} 落在规划窗口之外',
        );
        expect(
          gap.range.endUtc.isAfter(problem.planningWindow.startUtc),
          isTrue,
        );
      }
      // 引擎只诊断**有缺口**的任务，因此映射的键集与缺口集一致。
      expect(proposal.placementDiagnostics.keys.toSet(), {
        for (final item in proposal.unscheduled) item.taskId,
      });
    });

    test('with* 包装原样传递诊断（规则覆盖／延后要求／来源关联都没有丢）', () {
      final generated = engine.generate(shortWindowProblem());
      final gapCount =
          generated.placementDiagnostics.values.single.excludedGaps.length;

      // **先附上一个真实的延后要求再包装**。此前的写法是 `withAdjustmentRequirement(null)`，
      // 于是"某一层把它丢了"根本观察不到——`withLinkedBlocks` 漏传这个字段时，
      // 这条用例照样是绿的。夹具必须带着它才有判据。
      final proposal = generated.withAdjustmentRequirement(
        AdjustmentRequirement(
          targetBlockId: 'block-1',
          notBeforeUtc: DateTime.utc(2026, 10, 5, 10),
          requiredMinutes: 60,
          originalStartUtc: DateTime.utc(2026, 10, 5, 9),
        ),
      );

      final overridden = proposal.withRuleOverride(null);
      final adjustment = proposal.withAdjustmentRequirement(null);
      final linked = proposal.withLinkedBlocks(proposal.blocks);

      // `withAdjustmentRequirement(null)` 是唯一**故意**换掉该字段的那一个，单独断言。
      expect(
        adjustment.adjustmentRequirement,
        isNull,
        reason: '它是"改写这个字段"的那一个包装，传 null 就该得到 null',
      );

      for (final wrapper in [overridden, adjustment, linked]) {
        expect(
          wrapper.placementDiagnostics.keys,
          proposal.placementDiagnostics.keys,
        );
        expect(
          wrapper.placementDiagnostics.values.single.excludedGaps,
          hasLength(gapCount),
          reason: '包装只换一层外壳，不该丢掉"为什么排不下"的证据',
        );
      }

      for (final wrapper in [overridden, linked]) {
        expect(
          wrapper.adjustmentRequirement,
          proposal.adjustmentRequirement,
          reason:
              '包装只换一层外壳：**延后要求必须原样带过去**。'
              '`withLinkedBlocks` 曾经漏传它（其余两个 `with*` 都传了），'
              '丢掉之后应用前那次"这次延后到底兑现了没有"的校验会以为用户没有提过要求',
        );
      }
    });
  });
}

ScheduleProblem _problemFromFixture(Map<String, Object?> fixture) {
  final rulesJson = fixture['rules']! as Map<String, Object?>;
  final energyJson = (rulesJson['energyWindows']! as List<Object?>)
      .cast<Map<String, Object?>>();
  final rules = PlanningRules(
    energyWindows: [
      for (final item in energyJson)
        EnergyWindow(
          range: LocalTimeRange(
            startMinute: item['startMinute']! as int,
            endMinute: item['endMinute']! as int,
          ),
          level: EnergyLevel.values.byName(item['level']! as String),
        ),
    ],
    sleepRange: LocalTimeRange(
      startMinute: rulesJson['sleepStartMinute']! as int,
      endMinute: rulesJson['sleepEndMinute']! as int,
    ),
    minimumSleepMinutes: 420,
    defaultFocusMinutes: 50,
    breakMinutes: 10,
    dailyMovableTaskLimitMinutes: rulesJson['dailyLimitMinutes']! as int,
    weeklyLifeQuotaMinutes: rulesJson['weeklyLifeQuotaMinutes']! as int,
  );

  List<BusyInterval> intervals(String key) => [
    for (final item
        in (fixture[key]! as List<Object?>).cast<Map<String, Object?>>())
      BusyInterval(
        id: item['id']! as String,
        range: TimeRange(
          startUtc: DateTime.parse(item['start']! as String),
          endUtc: DateTime.parse(item['end']! as String),
        ),
      ),
  ];

  final window = TimeRange(
    startUtc: DateTime.parse(fixture['planningStartUtc']! as String),
    endUtc: DateTime.parse(fixture['planningEndUtc']! as String),
  );
  final zoneId = fixture['timeZoneId']! as String;
  return ScheduleProblem(
    planningWindow: window,
    timeZoneId: zoneId,
    tasks: [
      for (final item
          in (fixture['tasks']! as List<Object?>).cast<Map<String, Object?>>())
        SchedulableTask(
          id: item['id']! as String,
          requiredMinutes: item['minutes']! as int,
          splitMode: TaskSplitMode.values.byName(item['splitMode']! as String),
          minChunkMinutes: item['minChunk']! as int,
          maxChunkMinutes: item['maxChunk']! as int,
          dueAtUtc: item['due'] == null
              ? null
              : DateTime.parse(item['due']! as String),
          priority: TaskPriority.values.byName(item['priority']! as String),
          energyLevel: TaskEnergyLevel.values.byName(item['energy']! as String),
          isLifeTask: item['life']! as bool,
        ),
    ],
    fixedIntervals: intervals('fixed'),
    protectedIntervals: intervals('protected'),
    lockedBlocks: const [],
    rules: rules,
    dailyPolicies: dailyPoliciesForWindow(
      zones: _fixtureZones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    ),
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _fixtureZones,
      window: window,
      rules: rules,
      timeZoneId: zoneId,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'golden-week-v1',
  );
}

/// 夹具装载器用的时区库（顶层函数里没有 `main()` 的局部 `zones`）。
final TimeZoneDatabase _fixtureZones = TimeZoneDatabase();

String _signature(dynamic proposal) => jsonEncode({
  // **刻意不含 `proposalId`**（DFR-013）：实例 ID 每次生成都不同，判"结果是否
  // 相同"必须比较块/缺口/冲突这些语义内容；把实例 ID 写进签名会让确定性测试
  // 与"每次生成都唯一"直接矛盾。
  'id': '<instance>',
  'blocks': [
    for (final block in proposal.blocks)
      [
        block.id,
        block.taskId,
        block.startUtc.toIso8601String(),
        block.endUtc.toIso8601String(),
        block.explanationCode,
      ],
  ],
  'unscheduled': [
    for (final item in proposal.unscheduled)
      [item.taskId, item.shortageMinutes],
  ],
  'conflicts': [
    for (final item in proposal.conflicts)
      // 不要用 `item.code.name`：`item` 是 dynamic，动态派发看不到 Enum 的
      // `name` 扩展，会在存在冲突时抛 NoSuchMethodError。
      ['${item.code}', item.taskId, item.shortageMinutes],
  ],
});
