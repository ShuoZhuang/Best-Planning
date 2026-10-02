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
      [item.code.name, item.taskId, item.shortageMinutes],
  ],
});
