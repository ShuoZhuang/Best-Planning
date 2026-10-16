// Task 12A（用户 2026-10-08 追加的发布阻断项）Steps 1、2 的失败测试。
//
// **要修的是什么**：候选生成里 `minimum = roundUp(minChunk)`、`maximum = roundDown(min(maxChunk,
// requiredMinutes))`。一个 15 分钟的可拆分任务配上默认片段 30–90 分钟时，minimum=30 > maximum=15，
// `duration <= maximum` 直接不成立 ⇒ **一个候选都不生成** ⇒ 任务同时出现在"新增"与"未安排"里。
// 实测：`required=15 min=30 max=90 → scheduled=0 shortage=15`。
//
// 规则（用户写进路线图 §3.3 与 Task 12A 的 Interfaces）：
// `effectiveMinChunk = min(configuredMinChunk, remainingMinutes)` —— **最后一段允许短于模板最小
// 片段**，但不得小于排程粒度之外的实际剩余量。非最终片段继续遵守最小片段。
//
// 这条规则不能只写在候选生成里：`requiredMinutes` 会随着每周进度变化（180 → 100 → 15），
// 所以"最后一段"是**每次排程时**才知道的事，而不是保存任务时能定死的属性。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/candidate_generator.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../support/daily_policies.dart';

final _zones = TimeZoneDatabase();

void main() {
  const generator = CandidateGenerator();
  final start = DateTime.utc(2026, 10, 2, 9);

  List<AvailabilitySlot> slots(int hours) => [
    AvailabilitySlot(
      range: TimeRange(
        startUtc: start,
        endUtc: start.add(Duration(hours: hours)),
      ),
      localDate: DateTime(2026, 10, 2),
    ),
  ];

  SchedulableTask task({
    required int requiredMinutes,
    int minChunk = 30,
    int maxChunk = 90,
    TaskSplitMode splitMode = TaskSplitMode.splittable,
  }) => SchedulableTask(
    id: 'short',
    requiredMinutes: requiredMinutes,
    splitMode: splitMode,
    minChunkMinutes: minChunk,
    maxChunkMinutes: maxChunk,
  );

  group('Step 1／2：最终余量短于最小片段时仍要能安排', () {
    test('15 分钟任务、片段 30–90 ⇒ **必须**产出候选（现在一个都没有）', () {
      final candidates = generator.generate(
        task(requiredMinutes: 15),
        slots(2),
        remainingMinutes: 15,
      );

      expect(
        candidates,
        isNotEmpty,
        reason:
            '15 分钟是全部剩余量，它自己就是"最后一段"。此时最小片段 30 分钟是一条'
            '无法满足的约束，正确的处置是让这一段短于最小片段，而不是一个候选都不给',
      );
      expect(
        candidates.map((item) => item.durationMinutes).toSet(),
        contains(15),
        reason: '唯一合理的时长就是那 15 分钟本身',
      );
    });

    test('15 分钟任务不产出**长于**剩余量的候选（不能为了凑最小片段而超排）', () {
      final candidates = generator.generate(
        task(requiredMinutes: 15),
        slots(2),
        remainingMinutes: 15,
      );

      expect(
        candidates.every((item) => item.durationMinutes <= 15),
        isTrue,
        reason: '允许短于最小片段，但绝不允许长于剩余量——那是排多了',
      );
    });

    test('10 分钟剩余、粒度 5 分钟 ⇒ 取粒度下的 10 分钟', () {
      final candidates = generator.generate(
        task(requiredMinutes: 10),
        slots(2),
        remainingMinutes: 10,
      );

      expect(candidates.map((item) => item.durationMinutes).toSet(), {10});
    });

    test('剩余量不是粒度整数倍时向下取整，不越过剩余量', () {
      // 12 分钟、粒度 5：向下取 10（向上取 15 会超过剩余量）。
      final candidates = generator.generate(
        task(requiredMinutes: 12),
        slots(2),
        remainingMinutes: 12,
      );

      expect(candidates.map((item) => item.durationMinutes).toSet(), {
        10,
      }, reason: '余量 12 分钟时唯一合法的候选是 10 分钟；15 分钟会超排');
    });

    test('剩余量不足一个粒度 ⇒ 没有可安排的片段（如实返回空，而不是硬塞）', () {
      final candidates = generator.generate(
        task(requiredMinutes: 3),
        slots(2),
        remainingMinutes: 3,
      );

      expect(
        candidates,
        isEmpty,
        reason:
            '3 分钟小于 5 分钟粒度，排不进任何合法片段。这是真实的容量不足，'
            '应当由缺口机制如实汇报，而不是伪造一个片段',
      );
    });

    test('剩余量已经排掉一部分时（45 总量、剩 30）只产出 30 的候选', () {
      // `remainingMinutes` 是**本次排程的剩余量**，不是任务总量：45 分钟的任务
      // 已经排掉 15 之后，这一轮的上限就是 30。
      final candidates = generator.generate(
        task(requiredMinutes: 45),
        slots(2),
        remainingMinutes: 30,
      );

      expect(candidates.map((item) => item.durationMinutes).toSet(), {30});
    });

    test('剩余量为 0 ⇒ 空候选（引擎在扣减到 0 之后不会再问）', () {
      final candidates = generator.generate(
        task(requiredMinutes: 45),
        slots(2),
        remainingMinutes: 0,
      );

      expect(candidates, isEmpty);
    });

    test('非法的剩余量（负数、超过 requiredMinutes）抛 ArgumentError', () {
      // **没有默认值就必须有准入门禁**：负数会让 `_roundUp` 产出诡异的负时长候选，
      // 而超过 `requiredMinutes` 会让引擎排出超过任务的分钟数。
      expect(
        () => generator.generate(
          task(requiredMinutes: 45),
          slots(2),
          remainingMinutes: -5,
        ),
        throwsArgumentError,
      );
      expect(
        () => generator.generate(
          task(requiredMinutes: 45),
          slots(2),
          remainingMinutes: 50,
        ),
        throwsArgumentError,
      );
    });
  });

  group('非最终片段继续遵守最小片段（不能把宽免当成普遍放宽）', () {
    test('100 分钟、片段 30–90 ⇒ 不产出小于 30 的普通片段', () {
      final candidates = generator.generate(
        task(requiredMinutes: 100),
        slots(4),
        remainingMinutes: 100,
      );

      expect(
        candidates.every((item) => item.durationMinutes >= 30),
        isTrue,
        reason:
            '100 分钟还剩得下 30 分钟以上的片段，因此最小片段必须照旧生效；'
            '放宽只针对"连最小片段都凑不出"的最后一段',
      );
    });

    test('45 分钟、片段 30–90 ⇒ 30 到 45 之间每个粒度步长都是合法候选', () {
      final candidates = generator.generate(
        task(requiredMinutes: 45),
        slots(2),
        remainingMinutes: 45,
      );

      // **这里我原本写成 {30, 45}，是错的**：候选时长是在 `[min, max]` 上按 5 分钟步长
      // 枚举出来的，30/35/40/45 都合法。要断言的是"下限仍是 30"，不是把枚举结果背下来
      // ——后者会在枚举方式变化时给出看不懂的失败。
      expect(candidates.map((item) => item.durationMinutes).toSet(), {
        30,
        35,
        40,
        45,
      });
      expect(
        candidates.every((item) => item.durationMinutes >= 30),
        isTrue,
        reason: '45 分钟凑得出 30 分钟以上的片段，因此下限照旧生效',
      );
    });

    test('连续任务不受这条规则影响：仍是整段或零', () {
      final candidates = generator.generate(
        task(
          requiredMinutes: 15,
          splitMode: TaskSplitMode.continuous,
          minChunk: 30,
          maxChunk: 90,
        ),
        slots(2),
        remainingMinutes: 15,
      );

      expect(
        candidates.map((item) => item.durationMinutes).toSet(),
        {15},
        reason:
            '连续任务本来就不看片段上下限（它的语义是"一次做完"），'
            '15 分钟是粒度整数倍，因此整段可排',
      );
    });
  });

  group('端到端：引擎必须真的把它排进去', () {
    /// 一整周的窗口，无固定日程、无保护时间——容量充足，唯一的阻碍只可能是片段规则。
    ScheduleProblem problem(SchedulableTask t) {
      final window = TimeRange(
        startUtc: DateTime.utc(2026, 10, 5),
        endUtc: DateTime.utc(2026, 10, 12),
      );
      final zoneId = 'UTC';
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
        tasks: [t],
        fixedIntervals: const [],
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: _zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
          zones: _zones,
          window: window,
          rules: rules,
          timeZoneId: zoneId,
        ),
        preferences: const PreferenceProfile(),
        inputHash: 'short-remainder',
      );
    }

    test('15 分钟任务在容量充足的一周里**排得进去**，且不同时出现在未安排里', () {
      final engine = DeterministicScheduleEngine(TimeZoneDatabase());
      final t = task(requiredMinutes: 15);
      final proposal = engine.generate(problem(t));

      final scheduled = proposal.blocks
          .where((block) => block.taskId == t.id)
          .fold<int>(0, (sum, block) => sum + block.durationMinutes);
      final shortage = proposal.unscheduled
          .where((item) => item.taskId == t.id)
          .fold<int>(0, (sum, item) => sum + item.shortageMinutes);

      expect(scheduled, 15, reason: '容量充足却没排进去，正是那个发布阻断现象');
      expect(shortage, 0, reason: '同一个块不能同时被归为"已新增"和"未安排"');
    });

    // ── 1.8.0（2026-10-12 故障；冻结决策 §1.4）：**最终校验必须与候选生成同口径** ────
    //
    // 上面那条只证明了"引擎排得进去"。截图里的故障形态比它更糟：
    // **引擎排得进去、最终校验却必然拒绝**（R4）。
    // 因此这一段把"生成结果"与"提案里的 conflicts"绑在一起断言 ——
    // 候选生成合法而校验器不认，正是契约分裂的定义。
    List<PlanningConflict> invalidOf(ScheduleProposal p) =>
        p.conflicts.where((c) => c.code == ConflictCode.invalidInput).toList();

    test('15 分钟任务：最终校验**接受**那个 15 分钟块，提案无 invalid', () {
      final engine = DeterministicScheduleEngine(TimeZoneDatabase());
      final t = task(requiredMinutes: 15);
      final proposal = engine.generate(problem(t));

      expect(proposal.blocks, hasLength(1));
      expect(
        invalidOf(proposal),
        isEmpty,
        reason:
            '修复前 `PlanValidator` 无条件拒绝 `duration < minChunkMinutes`，'
            '于是引擎刚排好的块在确认阶段被自己判成非法 —— 用户点了确认只会看到'
            '"计划未通过校验，未应用"',
      );
      expect(
        proposal.metrics.isFullyFeasible,
        isTrue,
        reason: '能排下、校验也通过 ⇒ 这是一份完整可行的提案',
      );
    });

    test('12 分钟、粒度 5：排 10 分钟、缺 2 分钟，10 分钟块本身不产生 invalid', () {
      final engine = DeterministicScheduleEngine(TimeZoneDatabase());
      final t = task(requiredMinutes: 12);
      final proposal = engine.generate(problem(t));

      final scheduled = proposal.blocks
          .where((b) => b.taskId == t.id)
          .fold<int>(0, (sum, b) => sum + b.durationMinutes);
      expect(scheduled, 10, reason: '12 分钟的剩余量在 5 分钟粒度下最多排 10 分钟');
      expect(
        proposal.unscheduled.single.shortageMinutes,
        2,
        reason: '剩下那 2 分钟是**真实缺口**，要如实报出来，而不是伪造一个片段',
      );
      expect(
        invalidOf(proposal),
        isEmpty,
        reason: '10 分钟是唯一的合法候选，不该因此产生"片段短于允许值"',
      );
    });

    test('3 分钟：不生成块、缺 3 分钟、也不产生 invalid', () {
      final engine = DeterministicScheduleEngine(TimeZoneDatabase());
      final t = task(requiredMinutes: 3);
      final proposal = engine.generate(problem(t));

      expect(
        proposal.blocks.where((b) => b.taskId == t.id),
        isEmpty,
        reason: '3 分钟不足一个 5 分钟粒度 ⇒ 如实不排，不伪造片段',
      );
      expect(proposal.unscheduled.single.shortageMinutes, 3);
      expect(
        invalidOf(proposal),
        isEmpty,
        reason: '"排不下"是缺口，不是"排程输入无效"——两者的处置完全不同',
      );
    });

    test('100 分钟：宽免不得变成普遍放宽（最多一个短尾，且恰为剩下的那份余量）', () {
      final engine = DeterministicScheduleEngine(TimeZoneDatabase());
      final t = task(requiredMinutes: 100);
      final proposal = engine.generate(problem(t));

      expect(proposal.blocks, isNotEmpty);
      // **1.8.0 冻结决策 §2.2 的判据**：低于最小片段的块**最多一个**，而且它必须**恰好**
      // 等于"常规块排完之后剩下的那份余量"（粒度下的剩余量）。这一条比原先的
      // "任何块都不得小于 30" 更准确地表达同一个意图：
      //   · 原先的写法把"最后那一段合法的短尾"也一并禁掉，于是 100 分钟的任务
      //     永远排不满（R3/R4：`30+30+30+10` 被自己判成非法）；
      //   · 现在的写法仍然拦得住"普遍放宽"——两个短块、或者一个任意长度的短块都不合法。
      final shortBlocks = proposal.blocks
          .where((block) => block.durationMinutes < t.minChunkMinutes)
          .toList();
      expect(
        shortBlocks.length,
        lessThanOrEqualTo(1),
        reason: '宽免只针对**唯一**的最终短尾；出现两个就说明它变成了普遍放宽',
      );
      final regularTotal = proposal.blocks
          .where((block) => block.durationMinutes >= t.minChunkMinutes)
          .fold<int>(0, (sum, block) => sum + block.durationMinutes);
      final tailBudget = shortRemainderAllowance(
        requiredMinutes: t.requiredMinutes - regularTotal,
        granularityMinutes: 5,
      );
      for (final block in shortBlocks) {
        expect(
          block.durationMinutes,
          tailBudget,
          reason:
              '短尾必须是"常规块排完之后剩下的那份余量"（$tailBudget 分钟），'
              '不是任意一个小于最小片段的长度',
        );
      }
      expect(
        proposal.blocks.every(
          (block) => block.durationMinutes <= t.maxChunkMinutes,
        ),
        isTrue,
        reason: '宽免只放宽下限，上限照旧生效',
      );
      expect(invalidOf(proposal), isEmpty);
    });

    test('15 分钟**连续**任务：一个 15 分钟块合法，不因 min 30 产生 invalid', () {
      final engine = DeterministicScheduleEngine(TimeZoneDatabase());
      final t = task(requiredMinutes: 15, splitMode: TaskSplitMode.continuous);
      final proposal = engine.generate(problem(t));

      final blocks = proposal.blocks.where((b) => b.taskId == t.id).toList();
      expect(blocks, hasLength(1), reason: '连续任务只允许一个完整块');
      expect(blocks.single.durationMinutes, 15);
      expect(
        invalidOf(proposal),
        isEmpty,
        reason: 'R5：连续任务不该被可拆分任务的 min/max 片段检查误伤',
      );
    });

    test('连续任务的**两个块**仍然产生 `continuousBlockUnavailable`', () {
      final engine = DeterministicScheduleEngine(TimeZoneDatabase());
      final t = task(requiredMinutes: 30, splitMode: TaskSplitMode.continuous);
      final proposal = engine.generate(problem(t));

      // 直接把引擎的输出改成两块，模拟"外部构造的非法提案"：
      // 校验器必须仍然拦得住它，否则上面那条宽免会被误读成"连续任务随便拆"。
      final block = proposal.blocks.single;
      final split = [
        PlannedBlock(
          id: '${block.id}:a',
          taskId: block.taskId,
          range: TimeRange(
            startUtc: block.startUtc,
            endUtc: block.startUtc.add(const Duration(minutes: 15)),
          ),
        ),
        PlannedBlock(
          id: '${block.id}:b',
          taskId: block.taskId,
          range: TimeRange(
            startUtc: block.startUtc.add(const Duration(minutes: 15)),
            endUtc: block.endUtc,
          ),
        ),
      ];
      final conflicts = PlanValidator(TimeZoneDatabase())
          .validate(problem(t), split);

      expect(
        conflicts.where(
          (c) => c.code == ConflictCode.continuousBlockUnavailable,
        ),
        isNotEmpty,
        reason: '连续任务的语义是"一次做完"，拆成两块必须被拦下',
      );
    });
  });
}
