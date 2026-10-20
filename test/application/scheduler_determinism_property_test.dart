// 计划 Task 11：**属性与确定性**测试。
//
// `scale_smoke_test.dart` 已经在压力数据上钉住了几条不变量（锁定块不动、无重叠、
// 不挤占课程、不超目标、缺口带结构化原因）。这个文件补上它没有覆盖的两类：
//
// 1. **确定性**：同一份输入，无论运行多少次、任务与块的输入顺序如何，
//    排出的块序列必须**逐值相同**。算法 17 引入了轮换键（`SHA-256(taskId)`
//    前 8 字节）与跨日预算，它们都是"看起来像随机"的机制——正是最容易被写成
//    `hashCode` 或 `Random` 的地方，而那样会让"相同输入逐值相同"这条承诺失效。
// 2. **跨日预算的属性**：预算之和不得超过当天账本的剩余容量，
//    也不得超过任务目标。这是 `TaskDayBudget` 的契约
//    （见 `docs/testing/day-allocation-engine-contract.md` §3.3）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/day_allocation.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/schedule_proposal_codec.dart';

import '../support/daily_policies.dart';

final _zones = TimeZoneDatabase();
// 夹具用 **UTC**：窗口起点必须落在每日策略生成的同一天上。
// 用 `Asia/Shanghai` 的本地零点当窗口起点会落到 UTC 的**前一天**，
// 于是 `policyForLocalDate` 找不到那一天的策略而抛 `StateError`——
// 那是夹具的边界问题，与确定性无关。
const _zoneId = 'UTC';

/// 窗口：2026-10-05（周一）起两周。
final _windowStartUtc = DateTime.utc(2026, 10, 5);
final _windowEndUtc = DateTime.utc(2026, 10, 19);

PlanningRules _rules() => PlanningRules(
  energyWindows: const [],
  sleepRange: LocalTimeRange(startMinute: 1380, endMinute: 420),
  minimumSleepMinutes: 420,
  defaultFocusMinutes: 50,
  breakMinutes: 10,
  dailyMovableTaskLimitMinutes: 600,
  weeklyLifeQuotaMinutes: 0,
);

/// 中等规模夹具：任务数、截止、优先级、单日配额、可拆分性都刻意**各不相同**，
/// 好让排序与轮换真的被走到（全都一样的话，任何退化实现都能"通过"）。
List<SchedulableTask> _tasks() => [
  for (var index = 0; index < 24; index++)
    SchedulableTask(
      id: 'task-$index',
      requiredMinutes: 45 + (index % 5) * 15, // 45…105
      splitMode: index % 7 == 0
          ? TaskSplitMode.continuous
          : TaskSplitMode.splittable,
      minChunkMinutes: index % 7 == 0 ? 45 : 30,
      maxChunkMinutes: index % 7 == 0 ? 45 : 90,
      priority: TaskPriority.values[index % TaskPriority.values.length],
      dueAtUtc: index % 3 == 0
          ? _windowStartUtc.add(Duration(days: 4 + index % 9))
          : null,
      maxMinutesPerLocalDay: index % 4 == 0 ? 60 : null,
      distributionPolicy: index % 5 == 0
          ? TaskDistributionPolicy.even
          : TaskDistributionPolicy.unconstrained,
    ),
];

List<BusyInterval> _courses() => [
  for (var day = 0; day < 14; day++)
    for (final hour in [8, 14])
      BusyInterval(
        id: 'course-$day-$hour',
        range: TimeRange(
          startUtc: _windowStartUtc.add(Duration(days: day, hours: hour)),
          endUtc: _windowStartUtc.add(Duration(days: day, hours: hour + 2)),
        ),
      ),
];

List<PlannedBlock> _lockedBlocks() => [
  for (var day = 0; day < 14; day++)
    PlannedBlock(
      id: 'locked-$day',
      taskId: 'task-${day % 24}',
      range: TimeRange(
        startUtc: _windowStartUtc.add(Duration(days: day, hours: 19)),
        endUtc: _windowStartUtc.add(Duration(days: day, hours: 20)),
      ),
      locked: true,
    ),
];

ScheduleProblem _problem({
  List<SchedulableTask>? tasks,
  List<PlannedBlock>? locked,
}) {
  final rules = _rules();
  final resolvedTasks = tasks ?? _tasks();
  final resolvedLocked = locked ?? _lockedBlocks();
  return ScheduleProblem(
    planningWindow: TimeRange(startUtc: _windowStartUtc, endUtc: _windowEndUtc),
    timeZoneId: _zoneId,
    tasks: resolvedTasks,
    fixedIntervals: _courses(),
    protectedIntervals: const [],
    lockedBlocks: resolvedLocked,
    rules: rules,
    dailyPolicies: dailyPoliciesForWindow(
      zones: _zones,
      window: TimeRange(startUtc: _windowStartUtc, endUtc: _windowEndUtc),
      rules: rules,
      timeZoneId: _zoneId,
    ),
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _zones,
      window: TimeRange(startUtc: _windowStartUtc, endUtc: _windowEndUtc),
      rules: rules,
      timeZoneId: _zoneId,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'determinism',
  );
}

/// 把提案压成可直接逐值比较的字符串序列。
///
/// 比 `expect(proposal, other)` 更可靠：它显式列出我们**承诺**稳定的每一项
/// （块的 id、任务、起止、锁定标志），不依赖 `ScheduleProposal` 是否实现了
/// 深比较——后者变了会让测试悄悄失去意义。
List<String> _signature(ScheduleProposal proposal) {
  final rows = [
    for (final block in proposal.blocks)
      '${block.taskId}|${block.id}|${block.startUtc.toIso8601String()}|'
          '${block.endUtc.toIso8601String()}|${block.locked}',
  ]..sort();
  final gaps = [
    for (final item in proposal.unscheduled)
      '${item.taskId}|${item.shortageMinutes}|${item.primaryReason.code}',
  ]..sort();
  return [...rows, '--', ...gaps];
}

void main() {
  group('确定性（计划 Task 11 / ALG-20）', () {
    test('**同一份输入连续排程 5 次，块序列逐值相同**', () {
      final engine = DeterministicScheduleEngine(_zones);
      final first = _signature(engine.generate(_problem()));
      expect(first.any((row) => row != '--'), isTrue, reason: '夹具必须真的排出东西');

      for (var run = 0; run < 5; run++) {
        expect(
          _signature(engine.generate(_problem())),
          first,
          reason: '第 ${run + 2} 次排程与第 1 次不同 ⇒ 存在 `hashCode`／随机数依赖',
        );
      }
    });

    test('**同一个引擎实例复用也保持确定性**', () {
      // 复用实例才能暴露"引擎内部留了可变状态"这类缺陷——每次新建实例会掩盖它。
      final engine = DeterministicScheduleEngine(_zones);
      final problem = _problem();
      final first = _signature(engine.generate(problem));
      for (var run = 0; run < 3; run++) {
        expect(_signature(engine.generate(problem)), first);
      }
    });

    test('**任务输入顺序改变不影响结果**', () {
      // 顺序无关是"排序键是完整全序"的证据：任何"同分后按输入顺序"的实现
      // 都会在这里露出来。
      final forward = _signature(
        DeterministicScheduleEngine(_zones).generate(_problem()),
      );
      final reversed = _signature(
        DeterministicScheduleEngine(_zones)
            .generate(_problem(tasks: _tasks().reversed.toList())),
      );
      expect(reversed, forward, reason: '任务顺序改变导致结果不同');
    });

    test('**锁定块输入顺序改变不影响结果**', () {
      final forward = _signature(
        DeterministicScheduleEngine(_zones).generate(_problem()),
      );
      final reversed = _signature(
        DeterministicScheduleEngine(_zones)
            .generate(_problem(locked: _lockedBlocks().reversed.toList())),
      );
      expect(reversed, forward, reason: '锁定块顺序改变导致结果不同');
    });

    test('输入哈希相同的两次生成：实例 ID 不同、内容指纹相同（DFR-013）', () {
      const codec = ScheduleProposalCodec();
      final engine = DeterministicScheduleEngine(_zones);
      final first = engine.generate(_problem());
      final second = engine.generate(_problem());

      expect(second.inputHash, first.inputHash);
      // `proposalId` 是**实例身份**：每次生成必须不同，否则第二次确认会与
      // 第一次撞同一个计划版本主键，或让"同一令牌重放"失去区分力。
      expect(second.proposalId, isNot(first.proposalId));
      // 判"内容是否相同"只能用语义指纹，不能用实例 ID。
      expect(codec.sha256OfCanonical(second), codec.sha256OfCanonical(first));
    });
  });

  group('跨日预算的属性（计划 Task 11 / 契约 §3.3）', () {
    late DayAllocationPlan plan;
    late DayCapacityLedger ledger;
    late List<SchedulableTask> tasks;

    setUp(() {
      tasks = _tasks();
      final problem = _problem();
      final availability = AvailabilityBuilder(_zones).analyze(
        AvailabilityInput(
          planningWindow: problem.planningWindow,
          timeZoneId: problem.timeZoneId,
          rules: problem.rules,
          dailyPolicies: problem.dailyPolicies,
        ),
      );
      ledger = buildDayCapacityLedger(
        problem: problem,
        availability: availability,
        baselineBlocks: problem.lockedBlocks,
        zones: _zones,
      );
      plan = allocateTaskDays(
        DayAllocationInput(
          tasks: tasks,
          ledger: ledger,
          alreadyPlannedByTask: {
            for (final task in tasks)
              task.id: {
                for (final block in problem.lockedBlocks)
                  if (block.taskId == task.id)
                    DateTime(
                      block.startUtc.year,
                      block.startUtc.month,
                      block.startUtc.day,
                    ): block.durationMinutes,
              },
          },
          timeZoneId: problem.timeZoneId,
          cycleStartByTask: const {},
          granularityMinutes: problem.rules.granularityMinutes,
        ),
      );
    });

    test('**每个任务的预算不超过它自己的目标**', () {
      for (final task in tasks) {
        final budget = plan.budgetFor(task.id);
        if (budget == null) continue;
        expect(
          budget.allocatedMinutes,
          lessThanOrEqualTo(task.requiredMinutes),
          reason:
              '${task.id} 分配了 ${budget.allocatedMinutes} 分钟，'
              '超过目标 ${task.requiredMinutes}',
        );
      }
    });

    test('**每天所有任务的预算之和不超过该日账本剩余容量**', () {
      final allocatedByDate = <DateTime, int>{};
      for (final task in tasks) {
        final budget = plan.budgetFor(task.id);
        if (budget == null) continue;
        for (final entry in budget.minutesByLocalDate.entries) {
          allocatedByDate.update(
            entry.key,
            (value) => value + entry.value,
            ifAbsent: () => entry.value,
          );
        }
      }
      for (final entry in allocatedByDate.entries) {
        expect(
          entry.value,
          lessThanOrEqualTo(ledger.forDate(entry.key).remainingMinutes),
          reason:
              '${entry.key} 分配了 ${entry.value} 分钟，'
              '超过当天剩余 ${ledger.forDate(entry.key).remainingMinutes}',
        );
      }
    });

    test('**每天的预算都是粒度的整数倍**（否则引擎排不出恰好那么多）', () {
      final granularity = _rules().granularityMinutes;
      for (final task in tasks) {
        final budget = plan.budgetFor(task.id);
        if (budget == null) continue;
        for (final entry in budget.minutesByLocalDate.entries) {
          expect(
            entry.value % granularity,
            0,
            reason:
                '${task.id} 在 ${entry.key} 的预算 ${entry.value} '
                '不是粒度 $granularity 的整数倍',
          );
        }
      }
    });

    test('**预算内部自洽**：分配量 = 每日预算之和，且缺口非负', () {
      // 判据取自**分配器自己的目标**（`requiredMinutes − 已排`），而不是
      // `task.requiredMinutes`：引擎路径传的是 `_targetFor(...)` 的结果，
      // 两者对已开工或受截止压力影响的任务本来就可能不同。
      // 契约只承诺"分配量 + 缺口 = 本次目标"，因此这里钉的是**内部自洽**：
      //
      //   · `allocatedMinutes` 必须等于逐日预算之和（否则账目对不上）；
      //   · 缺口不得为负（负数意味着多排了）。
      for (final task in tasks) {
        final budget = plan.budgetFor(task.id);
        if (budget == null) continue;
        final perDaySum = budget.minutesByLocalDate.values.fold<int>(
          0,
          (sum, value) => sum + value,
        );
        expect(
          budget.allocatedMinutes,
          perDaySum,
          reason:
              '${task.id}：分配量 ${budget.allocatedMinutes} '
              '≠ 逐日预算之和 $perDaySum',
        );
        expect(
          budget.shortageMinutes,
          greaterThanOrEqualTo(0),
          reason: '${task.id} 的缺口为负（多排了）',
        );
      }
    });

    test('**分配结果本身是确定的**：同一输入两次分配逐值相同', () {
      final again = allocateTaskDays(
        DayAllocationInput(
          tasks: _tasks(),
          ledger: ledger,
          alreadyPlannedByTask: const {},
          timeZoneId: _zoneId,
          cycleStartByTask: const {},
          granularityMinutes: _rules().granularityMinutes,
        ),
      );
      final twice = allocateTaskDays(
        DayAllocationInput(
          tasks: _tasks(),
          ledger: ledger,
          alreadyPlannedByTask: const {},
          timeZoneId: _zoneId,
          cycleStartByTask: const {},
          granularityMinutes: _rules().granularityMinutes,
        ),
      );
      for (final task in _tasks()) {
        expect(
          twice.budgetFor(task.id)?.minutesByLocalDate,
          again.budgetFor(task.id)?.minutesByLocalDate,
          reason: '${task.id} 的预算不稳定',
        );
      }
    });
  });
}
