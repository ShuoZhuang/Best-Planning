import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/plan_differ.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final zones = TimeZoneDatabase();
  final engine = DeterministicScheduleEngine(zones);

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
      final gap = researchBlocks[index]
          .startUtc
          .difference(researchBlocks[index - 1].endUtc)
          .inMinutes;
      expect(gap, greaterThanOrEqualTo(problem.rules.breakMinutes));
    }
  });

  test('相同任务的两段专注之间保留 breakMinutes 休息', () {
    final day = DateTime.utc(2026, 10, 5);
    final problem = ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: day.add(const Duration(hours: 9)),
        endUtc: day.add(const Duration(hours: 18)),
      ),
      timeZoneId: 'UTC',
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
      rules: PlanningRules(
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
      ),
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
      preferences: problem.preferences,
      inputHash: problem.inputHash,
    );
    expect(_signature(engine.generate(reversed)), expected);
  });

  test('任意两个任务块之间保留休息，不区分任务类型', () {
    final day = DateTime.utc(2026, 10, 5);

    ScheduleProblem build(List<SchedulableTask> tasks) => ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: day.add(const Duration(hours: 9)),
        endUtc: day.add(const Duration(hours: 18)),
      ),
      timeZoneId: 'UTC',
      tasks: tasks,
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: PlanningRules(
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
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'rest-gap-cross-task',
    );

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

    ScheduleProblem build(SchedulableTask task) => ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: day,
        endUtc: day.add(const Duration(days: 7)),
      ),
      timeZoneId: 'UTC',
      tasks: [task],
      fixedIntervals: const [],
      protectedIntervals: const [],
      lockedBlocks: const [],
      rules: PlanningRules(
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
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'far-deadline-target',
    );

    // 均匀推进量（28 分钟）低于最小时长（30 分钟），原先因此一个片段也放不下。
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
    expect(splittable.metrics.scheduledMinutes, 30);
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
    final problem = ScheduleProblem(
      // 跨越两天：第二天存在"同一本地日内没有相邻任务"的位置。
      planningWindow: TimeRange(
        startUtc: day.add(const Duration(hours: 9)),
        endUtc: day.add(const Duration(days: 1, hours: 18)),
      ),
      timeZoneId: 'UTC',
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
      rules: PlanningRules(
        // 精力区间为空，使两个候选的精力匹配没有差别。
        energyWindows: const [],
        sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
        minimumSleepMinutes: 420,
        defaultFocusMinutes: 50,
        breakMinutes: 10,
        dailyMovableTaskLimitMinutes: 600,
        weeklyLifeQuotaMinutes: 0,
      ),
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

    ScheduleProblem build({required bool withExisting}) => ScheduleProblem(
      planningWindow: TimeRange(
        startUtc: day.add(const Duration(hours: 9)),
        endUtc: day.add(const Duration(hours: 12)),
      ),
      timeZoneId: 'UTC',
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
      rules: PlanningRules(
        energyWindows: const [],
        sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
        minimumSleepMinutes: 420,
        defaultFocusMinutes: 50,
        breakMinutes: 10,
        dailyMovableTaskLimitMinutes: 600,
        weeklyLifeQuotaMinutes: 0,
      ),
      preferences: const PreferenceProfile(),
      inputHash: 'moving-cost-ab',
    );

    DateTime placement(ScheduleProblem problem) =>
        engine.generate(problem).blocks.single.startUtc;

    // 不提供已确认块时，两个候选同分，按开始时间决胜 → 最早位置。
    expect(placement(build(withExisting: false)), day.add(const Duration(hours: 9)));
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
    final fixture =
        jsonDecode(
              File(
                'test/fixtures/scheduling/golden_week.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
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

  return ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: DateTime.parse(fixture['planningStartUtc']! as String),
      endUtc: DateTime.parse(fixture['planningEndUtc']! as String),
    ),
    timeZoneId: fixture['timeZoneId']! as String,
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
    preferences: const PreferenceProfile(),
    inputHash: 'golden-week-v1',
  );
}

String _signature(dynamic proposal) => jsonEncode({
  'id': proposal.proposalId,
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
