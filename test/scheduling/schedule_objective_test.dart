// 方案级字典序目标（算法 17，计划 `2026-10-16-capacity-aware-hierarchical-scheduler-repair.md`
// §3.3 / Task 4 Step 1–4）。
//
// ## 这一组用例要钉住的四件事
//
// 1. **禁止求和**：每个相邻字段各一例——前一项更优者**无条件**胜出，
//    哪怕后一项差得多。修复前 `CandidateScorer` 把截止、优先级、精力、连续性、
//    碎片与移动成本相加，于是"一个足够大的软偏好可以覆盖跨日均衡意图"。
// 2. **优先级缺口是向量**：urgent / high / medium / low 依次比较，同级再比分钟。
//    一个加权和会让"少缺 1 分钟紧急任务"与"少缺 30 分钟低优先任务"变得可比。
// 3. **三种 profile 的字段顺序互不混用**：`scheduleObjectiveStageNames` 是顺序的
//    唯一事实源，本文件直接对它断言，因此顺序改动不可能静默。
// 4. **稳定签名**：所有业务字段相同后由签名分胜负，且签名与 Map 顺序无关。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/schedule_objective.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

const String _zoneId = 'UTC';

final TimeZoneDatabase _zones = TimeZoneDatabase();

/// 造一个目标向量，只让 `overrides` 指定的字段偏离"大而坏"的基线。
///
/// 基线取**统一的大值**（999），于是"某个字段更小"就等于"这一项更优"，
/// 而"字典序"与"加权和"的差别可以逐字段钉住。
ScheduleObjective _objective([
  Map<ScheduleObjectiveField, int> overrides = const {},
]) {
  int value(ScheduleObjectiveField field) => overrides[field] ?? 999;
  return ScheduleObjective(
    hardViolationCount: value(ScheduleObjectiveField.hardViolationCount),
    invariantViolationCount: value(
      ScheduleObjectiveField.invariantViolationCount,
    ),
    unfulfilledAdjustmentCount: value(
      ScheduleObjectiveField.unfulfilledAdjustmentCount,
    ),
    newShortageMinutesAgainstReference: value(
      ScheduleObjectiveField.newShortageMinutesAgainstReference,
    ),
    shortageMinutesByPriority: [
      value(ScheduleObjectiveField.urgentShortageMinutes),
      value(ScheduleObjectiveField.highShortageMinutes),
      value(ScheduleObjectiveField.mediumShortageMinutes),
      value(ScheduleObjectiveField.lowShortageMinutes),
    ],
    maximumDailyUtilizationPermille: value(
      ScheduleObjectiveField.maximumDailyUtilizationPermille,
    ),
    totalOverTargetPermille: value(
      ScheduleObjectiveField.totalOverTargetPermille,
    ),
    pacingDeviationMinutes: value(
      ScheduleObjectiveField.pacingDeviationMinutes,
    ),
    movedConfirmedBlockCount: value(
      ScheduleObjectiveField.movedConfirmedBlockCount,
    ),
    changedConfirmedBlockCount: value(
      ScheduleObjectiveField.changedConfirmedBlockCount,
    ),
    displacementMinutes: value(ScheduleObjectiveField.displacementMinutes),
    extraTargetDisplacementMinutes: value(
      ScheduleObjectiveField.extraTargetDisplacementMinutes,
    ),
    recreatedBlockCount: value(ScheduleObjectiveField.recreatedBlockCount),
    fragmentCount: value(ScheduleObjectiveField.fragmentCount),
    softPreferencePenalty: value(ScheduleObjectiveField.softPreferencePenalty),
    orphanGapCount: value(ScheduleObjectiveField.orphanGapCount),
    orphanGapMinutes: value(ScheduleObjectiveField.orphanGapMinutes),
    stableSignature: 'same-signature',
  );
}

void main() {
  group('逐层不可覆盖（Task 4 Step 1）', () {
    for (final profile in ScheduleObjectiveProfile.values) {
      final stages = scheduleObjectiveStageNames(profile);

      test('$profile：每一项更优者胜出，且后一项的恶化不能补偿', () {
        for (final field in stages) {
          // a 只在 `field` 上更优（值 0 对 1），其余字段两边**完全相同**。
          final a = _objective({field: 0});
          final b = _objective({field: 1});

          expect(
            compareScheduleObjectives(a, b, profile),
            lessThan(0),
            reason: '$profile：$field 更小时必须更优',
          );
          expect(
            compareScheduleObjectives(b, a, profile),
            greaterThan(0),
            reason: '$profile：$field 更大时必须更差（对称性）',
          );
        }
      });

      test('$profile：**前面一项的 1 个单位胜过后面所有项的任意改善**', () {
        // 这是"禁止求和"的直接形式：两个方案**只在第一项上**差 1 个单位，
        // 而第一项更差的那个把**后面所有字段**都做到最优（0）。
        // 它仍然必须输——若有人把目标压成加权和，"后面全部最优"的总分足以反超。
        final first = stages.first;
        final worseOnFirst = _objective({first: 1});
        final bestOnEverythingElse = _objective({
          for (final field in stages.skip(1)) field: 0,
          // 第一项也更优：这是**唯一**的差别，因此字典序必须由它决定。
          first: 0,
        });

        expect(
          compareScheduleObjectives(
            worseOnFirst,
            bestOnEverythingElse,
            profile,
          ),
          greaterThan(0),
          reason:
              '$profile：第一项（$first）差 1 个单位时，后面全部最优也不能胜出——'
              '若这条失败，说明有人把目标压成了加权和',
        );
        expect(
          compareScheduleObjectives(
            bestOnEverythingElse,
            worseOnFirst,
            profile,
          ),
          lessThan(0),
          reason: '反向比较必须给出相反结论，证明差别确实只来自第一项',
        );
      });
    }
  });

  group('三种 profile 的字段顺序互不混用（Task 4 Step 1 / ALG-31）', () {
    test('顺序表本身：三种 profile 的字段顺序不同，且各自与计划 §3.3 一致', () {
      expect(
        scheduleObjectiveStageNames(ScheduleObjectiveProfile.initialGeneration),
        [
          ScheduleObjectiveField.hardViolationCount,
          ScheduleObjectiveField.invariantViolationCount,
          ScheduleObjectiveField.urgentShortageMinutes,
          ScheduleObjectiveField.highShortageMinutes,
          ScheduleObjectiveField.mediumShortageMinutes,
          ScheduleObjectiveField.lowShortageMinutes,
          ScheduleObjectiveField.maximumDailyUtilizationPermille,
          ScheduleObjectiveField.totalOverTargetPermille,
          ScheduleObjectiveField.pacingDeviationMinutes,
          ScheduleObjectiveField.fragmentCount,
          ScheduleObjectiveField.softPreferencePenalty,
          ScheduleObjectiveField.orphanGapCount,
          ScheduleObjectiveField.orphanGapMinutes,
        ],
        reason: '初次生成：完成度 → 负载 → 节奏 → 形状 → 偏好 → 空档',
      );

      expect(
        scheduleObjectiveStageNames(ScheduleObjectiveProfile.backgroundReplan),
        [
          ScheduleObjectiveField.hardViolationCount,
          ScheduleObjectiveField.invariantViolationCount,
          ScheduleObjectiveField.urgentShortageMinutes,
          ScheduleObjectiveField.highShortageMinutes,
          ScheduleObjectiveField.mediumShortageMinutes,
          ScheduleObjectiveField.lowShortageMinutes,
          // 稳定性**先于**均衡。
          ScheduleObjectiveField.changedConfirmedBlockCount,
          ScheduleObjectiveField.movedConfirmedBlockCount,
          ScheduleObjectiveField.displacementMinutes,
          ScheduleObjectiveField.recreatedBlockCount,
          ScheduleObjectiveField.maximumDailyUtilizationPermille,
          ScheduleObjectiveField.totalOverTargetPermille,
          ScheduleObjectiveField.pacingDeviationMinutes,
          ScheduleObjectiveField.fragmentCount,
          ScheduleObjectiveField.softPreferencePenalty,
          ScheduleObjectiveField.orphanGapCount,
          ScheduleObjectiveField.orphanGapMinutes,
        ],
        reason: '普通重排：完成度不变，**稳定性排在均衡之前**',
      );

      expect(
        scheduleObjectiveStageNames(
          ScheduleObjectiveProfile.explicitAdjustment,
        ),
        [
          ScheduleObjectiveField.hardViolationCount,
          ScheduleObjectiveField.invariantViolationCount,
          // "这次调整兑现了没有"必须最优先，否则可以用删掉目标块来赢得"少移动"。
          ScheduleObjectiveField.unfulfilledAdjustmentCount,
          ScheduleObjectiveField.newShortageMinutesAgainstReference,
          ScheduleObjectiveField.changedConfirmedBlockCount,
          ScheduleObjectiveField.displacementMinutes,
          ScheduleObjectiveField.extraTargetDisplacementMinutes,
          ScheduleObjectiveField.urgentShortageMinutes,
          ScheduleObjectiveField.highShortageMinutes,
          ScheduleObjectiveField.mediumShortageMinutes,
          ScheduleObjectiveField.lowShortageMinutes,
          ScheduleObjectiveField.maximumDailyUtilizationPermille,
          ScheduleObjectiveField.totalOverTargetPermille,
          ScheduleObjectiveField.pacingDeviationMinutes,
          ScheduleObjectiveField.fragmentCount,
          ScheduleObjectiveField.softPreferencePenalty,
          ScheduleObjectiveField.orphanGapCount,
          ScheduleObjectiveField.orphanGapMinutes,
        ],
        reason: '指定调整：未兑现 > 新缺口 > 少动 > 完成度 > 负载',
      );
    });

    test('**未兑现目标的方案永远输**，哪怕它在别的维度全面更优', () {
      final unfulfilled = _objective({
        ScheduleObjectiveField.unfulfilledAdjustmentCount: 1,
      });
      final perfectElsewhere = _objective({
        ScheduleObjectiveField.unfulfilledAdjustmentCount: 0,
        for (final field in scheduleObjectiveStageNames(
          ScheduleObjectiveProfile.explicitAdjustment,
        ).skip(3))
          field: 0,
      });

      expect(
        compareScheduleObjectives(
          unfulfilled,
          perfectElsewhere,
          ScheduleObjectiveProfile.explicitAdjustment,
        ),
        greaterThan(0),
      );
    });

    test('**普通重排里少动一个块胜过均衡更好**', () {
      final fewerChanges = _objective({
        ScheduleObjectiveField.changedConfirmedBlockCount: 1,
        ScheduleObjectiveField.maximumDailyUtilizationPermille: 900,
      });
      final betterBalance = _objective({
        ScheduleObjectiveField.changedConfirmedBlockCount: 2,
        ScheduleObjectiveField.maximumDailyUtilizationPermille: 100,
      });

      expect(
        compareScheduleObjectives(
          fewerChanges,
          betterBalance,
          ScheduleObjectiveProfile.backgroundReplan,
        ),
        lessThan(0),
        reason: '重排设置改动门槛：稳定性优先于均衡，否则微小质量改善会移动一批已确认块',
      );
    });

    test('**初次生成里均衡更好胜过少动一块**（同一对方案，顺序相反）', () {
      final fewerChanges = _objective({
        ScheduleObjectiveField.changedConfirmedBlockCount: 1,
        ScheduleObjectiveField.maximumDailyUtilizationPermille: 900,
      });
      final betterBalance = _objective({
        ScheduleObjectiveField.changedConfirmedBlockCount: 2,
        ScheduleObjectiveField.maximumDailyUtilizationPermille: 100,
      });

      expect(
        compareScheduleObjectives(
          fewerChanges,
          betterBalance,
          ScheduleObjectiveProfile.initialGeneration,
        ),
        greaterThan(0),
        reason: '初次生成没有"已确认块"可言，因此不比较 changedConfirmedBlockCount',
      );
    });
  });

  group('优先级缺口是向量（Task 4 Step 2）', () {
    test('**紧急缺口少 1 分钟胜过低优先缺口少 30 分钟**', () {
      final urgentBetter = _objective({
        ScheduleObjectiveField.urgentShortageMinutes: 1,
        ScheduleObjectiveField.lowShortageMinutes: 30,
      });
      final lowBetter = _objective({
        ScheduleObjectiveField.urgentShortageMinutes: 2,
        ScheduleObjectiveField.lowShortageMinutes: 0,
      });

      for (final profile in ScheduleObjectiveProfile.values) {
        expect(
          compareScheduleObjectives(urgentBetter, lowBetter, profile),
          lessThan(0),
          reason:
              '$profile：加权和会把这两个方案压成一个数（1+30 与 2+0），'
              '而紧急任务永远必须先完整',
        );
      }
    });

    test('urgent → high → medium → low 依次比较', () {
      // 每一级各造一对：**只**在这一级上更优、其余级相同。
      final levels = <ScheduleObjectiveField>[
        ScheduleObjectiveField.urgentShortageMinutes,
        ScheduleObjectiveField.highShortageMinutes,
        ScheduleObjectiveField.mediumShortageMinutes,
        ScheduleObjectiveField.lowShortageMinutes,
      ];
      for (final level in levels) {
        final a = _objective({level: 5});
        final b = _objective({level: 6});
        expect(
          compareScheduleObjectives(
            a,
            b,
            ScheduleObjectiveProfile.initialGeneration,
          ),
          lessThan(0),
          reason: '同一级内比分钟：$level',
        );
      }
    });
  });

  group('稳定签名（Task 4 Step 3）', () {
    test('业务字段完全相同 ⇒ 由签名决定，且反向比较也一致', () {
      final a = _objective();
      final b = _objective();
      // 两个目标的业务字段逐值相同，签名也相同 ⇒ 返回 0。
      expect(
        compareScheduleObjectives(
          a,
          b,
          ScheduleObjectiveProfile.initialGeneration,
        ),
        0,
      );

      final earlier = ScheduleObjective(
        hardViolationCount: 0,
        invariantViolationCount: 0,
        unfulfilledAdjustmentCount: 0,
        newShortageMinutesAgainstReference: 0,
        shortageMinutesByPriority: const [0, 0, 0, 0],
        maximumDailyUtilizationPermille: 0,
        totalOverTargetPermille: 0,
        pacingDeviationMinutes: 0,
        movedConfirmedBlockCount: 0,
        changedConfirmedBlockCount: 0,
        displacementMinutes: 0,
        extraTargetDisplacementMinutes: 0,
        recreatedBlockCount: 0,
        fragmentCount: 0,
        softPreferencePenalty: 0,
        orphanGapCount: 0,
        orphanGapMinutes: 0,
        stableSignature: 'aaa',
      );
      final later = ScheduleObjective(
        hardViolationCount: 0,
        invariantViolationCount: 0,
        unfulfilledAdjustmentCount: 0,
        newShortageMinutesAgainstReference: 0,
        shortageMinutesByPriority: const [0, 0, 0, 0],
        maximumDailyUtilizationPermille: 0,
        totalOverTargetPermille: 0,
        pacingDeviationMinutes: 0,
        movedConfirmedBlockCount: 0,
        changedConfirmedBlockCount: 0,
        displacementMinutes: 0,
        extraTargetDisplacementMinutes: 0,
        recreatedBlockCount: 0,
        fragmentCount: 0,
        softPreferencePenalty: 0,
        orphanGapCount: 0,
        orphanGapMinutes: 0,
        stableSignature: 'bbb',
      );

      expect(
        compareScheduleObjectives(
          earlier,
          later,
          ScheduleObjectiveProfile.initialGeneration,
        ),
        lessThan(0),
      );
      expect(
        compareScheduleObjectives(
          later,
          earlier,
          ScheduleObjectiveProfile.initialGeneration,
        ),
        greaterThan(0),
      );
    });

    test('**签名与块集合的输入顺序无关，只由（起点、任务 ID、块 ID）排序决定**', () {
      final blocks = [
        PlannedBlock(
          id: 'b2',
          taskId: 't-a',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 12, 10),
            endUtc: DateTime.utc(2026, 10, 12, 11),
          ),
        ),
        PlannedBlock(
          id: 'b1',
          taskId: 't-b',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 12, 9),
            endUtc: DateTime.utc(2026, 10, 12, 10),
          ),
        ),
        PlannedBlock(
          id: 'b3',
          taskId: 't-a',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 12, 10),
            endUtc: DateTime.utc(2026, 10, 12, 10, 30),
          ),
        ),
      ];

      final forward = stableSignatureOf(blocks);
      final reversed = stableSignatureOf(blocks.reversed.toList());
      expect(reversed, forward, reason: '排程要求相同输入相同输出，而块的输入顺序不改变"这份计划是什么"');
      // 起点 09:00 的那一块必须排在前面。
      expect(forward.indexOf('t-b|b1'), lessThan(forward.indexOf('t-a|b2')));
      // 起点相同时按任务 ID，再按块 ID：`t-a|b2` 在 `t-a|b3` 之前。
      expect(forward.indexOf('t-a|b2'), lessThan(forward.indexOf('t-a|b3')));
    });
  });

  group('evaluateScheduleObjective 从显式输入求值（Task 4 Step 4）', () {
    ScheduleProblem problem({int dailyLimit = 600}) {
      final window = TimeRange(
        startUtc: DateTime.utc(2026, 10, 12),
        endUtc: DateTime.utc(2026, 10, 13),
      );
      final rules = DefaultSettings.v1().copyWith(
        energyWindows: const [],
        protectedTimes: const [],
        sleepRange: LocalTimeRange(startMinute: 0, endMinute: 1),
        dailyMovableTaskLimitMinutes: dailyLimit,
      );
      return ScheduleProblem(
        planningWindow: window,
        timeZoneId: _zoneId,
        tasks: const [
          SchedulableTask(
            id: 't-a',
            requiredMinutes: 120,
            splitMode: TaskSplitMode.splittable,
            minChunkMinutes: 30,
            maxChunkMinutes: 60,
            priority: TaskPriority.high,
          ),
        ],
        fixedIntervals: const [],
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: _zones,
          window: window,
          rules: rules,
          timeZoneId: _zoneId,
        ),
        weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
          zones: _zones,
          window: window,
          rules: rules,
          timeZoneId: _zoneId,
        ),
        preferences: const PreferenceProfile(),
        inputHash: 'schedule-objective',
      );
    }

    DayCapacityLedger ledgerFor(ScheduleProblem problem) =>
        DayCapacityLedger.fromSnapshots([
          DayCapacitySnapshot(
            localDate: DateTime(2026, 10, 12),
            hardFreeMinutes: 600,
            calendarGapMinutes: 480,
            licensedCapacityMinutes: 600,
            usedMovableMinutes: 120,
            allocatedMinutes: 0,
            remainingMinutes: 360,
            utilizationPermille: 200,
          ),
        ]);

    test('缺口按优先级归入向量，而不是一个总数', () {
      final problemTime = problem();
      final objective = evaluateScheduleObjective(
        problem: problemTime,
        // 只排了 30 分钟 ⇒ 还缺 90，而任务优先级是 high。
        blocks: [
          PlannedBlock(
            id: 'b1',
            taskId: 't-a',
            range: TimeRange(
              startUtc: DateTime.utc(2026, 10, 12, 9),
              endUtc: DateTime.utc(2026, 10, 12, 9, 30),
            ),
          ),
        ],
        ledger: ledgerFor(problemTime),
        zones: _zones,
        profile: ScheduleObjectiveProfile.initialGeneration,
      );

      // TaskPriority 的声明顺序决定向量顺序：urgent / high / medium / low。
      expect(
        objective.shortageMinutesByPriority[TaskPriority.high.index],
        90,
        reason: 'high 那一格是 90 分钟',
      );
      expect(
        objective.shortageMinutesByPriority
            .where((minutes) => minutes > 0)
            .length,
        1,
        reason: '缺口只属于一个优先级',
      );
    });

    test('最大单日负载率来自账本', () {
      final problemTime = problem();
      final objective = evaluateScheduleObjective(
        problem: problemTime,
        blocks: const [],
        ledger: ledgerFor(problemTime),
        zones: _zones,
        profile: ScheduleObjectiveProfile.initialGeneration,
      );

      expect(objective.maximumDailyUtilizationPermille, 200);
    });

    test('同一份输入重复求值逐值相同', () {
      final problemTime = problem();
      final blocks = [
        PlannedBlock(
          id: 'b1',
          taskId: 't-a',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 12, 9),
            endUtc: DateTime.utc(2026, 10, 12, 10),
          ),
        ),
      ];
      final first = evaluateScheduleObjective(
        problem: problemTime,
        blocks: blocks,
        ledger: ledgerFor(problemTime),
        zones: _zones,
        profile: ScheduleObjectiveProfile.initialGeneration,
      );
      for (var run = 0; run < 5; run++) {
        final again = evaluateScheduleObjective(
          problem: problemTime,
          blocks: blocks,
          ledger: ledgerFor(problemTime),
          zones: _zones,
          profile: ScheduleObjectiveProfile.initialGeneration,
        );
        expect(again.stableSignature, first.stableSignature);
        expect(
          again.shortageMinutesByPriority,
          first.shortageMinutesByPriority,
        );
        expect(
          compareScheduleObjectives(
            again,
            first,
            ScheduleObjectiveProfile.initialGeneration,
          ),
          0,
        );
      }
    });
  });
}
