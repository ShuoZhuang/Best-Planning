// 局部修复**复用方案级目标**的比较顺序（算法 17，计划 Task 4 Step 5）。
//
// ## 为什么需要这个文件
//
// `LocalRepairPlan.compare` 的六段比较（规范 §11.4 第 3～7 条 + 稳定签名）此前是
// **自己写的一串 `if`**，而 Task 4 引入的统一字典序目标
// （`compareScheduleObjectives` + `ScheduleObjectiveProfile.explicitAdjustment`）
// 表达的是**同一件事**。两套实现并存等于两套口径：跨日分配器、方案级改进与
// 局部修复会按不同的顺序挑方案，而用户看到的是"同一个问题在不同入口给出不同答案"。
//
// 因此 Step 5 把局部修复接到统一目标上，并要求它的**对外行为逐字不变**。
// 本文件钉住三件事：
//
// 1. 统一目标的排序**确实等价于** §11.4（同一对方案、两个入口给出同号结果）；
// 2. 每一级都能单独决定胜负（前一级相同时才看后一级）；
// 3. 映射过程中"§11.4 之外"的字段恒为 0——否则会给排序加一层规范没要求的层级。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/gap_classifier.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_objective.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final day = DateTime.utc(2026, 10, 12);
  DateTime at(int minute) => day.add(Duration(minutes: minute));

  PlannedBlock block(String id, int startMinute, int minutes) => PlannedBlock(
    id: id,
    taskId: 't-a',
    range: TimeRange(
      startUtc: at(startMinute),
      endUtc: at(startMinute + minutes),
    ),
  );

  SchedulableTask task({int minChunk = 30}) => SchedulableTask(
    id: 't-a',
    requiredMinutes: 120,
    minChunkMinutes: minChunk,
    maxChunkMinutes: 60,
    splitMode: TaskSplitMode.splittable,
    priority: TaskPriority.medium,
    energyLevel: TaskEnergyLevel.medium,
  );

  /// §11.4 的排序在**统一目标**这一侧的表达：只填它用到的层级，其余置 0。
  ///
  /// 这正是 `LocalRepairPlan.compare` 内部的映射方式（见 `local_repair.dart`
  /// 的 `_objectiveOf`）。测试把它**独立复现一遍**：如果生产代码哪天开始给
  /// "§11.4 之外"的字段赋非零值，两个入口的结果就会分叉，本文件会当场发现。
  ScheduleObjective objectiveOf(
    LocalRepairPlan plan, {
    required Map<String, DateTime> reference,
    required String targetBlockId,
    required DateTime notBeforeUtc,
    Iterable<SchedulableTask> tasks = const [],
    List<TimeRange> protectedRanges = const [],
    int breakMinutes = 0,
  }) {
    var gapCount = 0;
    var gapMinutes = 0;
    if (tasks.any((item) => item.requiredMinutes > 0)) {
      for (final gap in classifyGaps(
        blocks: plan.blocks,
        tasks: tasks,
        protectedRanges: protectedRanges,
        breakMinutes: breakMinutes,
      )) {
        if (gap.kind != GapKind.orphan) continue;
        gapCount++;
        gapMinutes += gap.minutes;
      }
    }
    var targetDistance = 1 << 30;
    for (final candidate in plan.blocks) {
      if (candidate.id != targetBlockId) continue;
      final delta = candidate.startUtc.difference(notBeforeUtc).inMinutes;
      targetDistance = delta < 0 ? -delta + 100000 : delta;
    }
    return ScheduleObjective(
      hardViolationCount: 0,
      invariantViolationCount: 0,
      unfulfilledAdjustmentCount: 0,
      newShortageMinutesAgainstReference: 0,
      shortageMinutesByPriority: const [0, 0, 0, 0],
      maximumDailyUtilizationPermille: 0,
      totalOverTargetPermille: 0,
      pacingDeviationMinutes: 0,
      movedConfirmedBlockCount: plan.movedBlockIds.length,
      changedConfirmedBlockCount: plan.movedBlockIds.length,
      displacementMinutes: localRepairDisplacementMinutes(plan, reference),
      extraTargetDisplacementMinutes: targetDistance,
      recreatedBlockCount: 0,
      fragmentCount: 0,
      softPreferencePenalty: 0,
      orphanGapCount: gapCount,
      orphanGapMinutes: gapMinutes,
      stableSignature: stableSignatureOf(plan.blocks),
    );
  }

  /// 两个入口对同一对方案给出的**符号**必须一致。
  void expectSameVerdict(
    LocalRepairPlan a,
    LocalRepairPlan b, {
    required Map<String, DateTime> reference,
    required String targetBlockId,
    required DateTime notBeforeUtc,
    Iterable<SchedulableTask> tasks = const [],
    List<TimeRange> protectedRanges = const [],
    int breakMinutes = 0,
    String? reason,
  }) {
    final byLocalRepair = LocalRepairPlan.compare(
      a,
      b,
      reference: reference,
      targetBlockId: targetBlockId,
      notBeforeUtc: notBeforeUtc,
      tasks: tasks,
      protectedRanges: protectedRanges,
      breakMinutes: breakMinutes,
    );
    final byObjective = compareScheduleObjectives(
      objectiveOf(
        a,
        reference: reference,
        targetBlockId: targetBlockId,
        notBeforeUtc: notBeforeUtc,
        tasks: tasks,
        protectedRanges: protectedRanges,
        breakMinutes: breakMinutes,
      ),
      objectiveOf(
        b,
        reference: reference,
        targetBlockId: targetBlockId,
        notBeforeUtc: notBeforeUtc,
        tasks: tasks,
        protectedRanges: protectedRanges,
        breakMinutes: breakMinutes,
      ),
      ScheduleObjectiveProfile.explicitAdjustment,
    );
    expect(
      byLocalRepair.sign,
      byObjective.sign,
      reason:
          reason ??
          '两个入口必须给出同一个结论：局部修复（$byLocalRepair）与'
              '统一目标（$byObjective）分叉就意味着两套排序口径',
    );
  }

  group('两个入口的结论一致（Task 4 Step 5）', () {
    test('第 3 级：少移动一个块胜出', () {
      final fewer = LocalRepairPlan(
        blocks: [block('b1', 0, 60)],
        movedBlockIds: const {'b1'},
      );
      final more = LocalRepairPlan(
        blocks: [block('b1', 0, 60)],
        movedBlockIds: const {'b1', 'b2'},
      );

      expectSameVerdict(
        fewer,
        more,
        reference: const {},
        targetBlockId: 'b1',
        notBeforeUtc: at(0),
        reason: '§11.4 第 3 条：移动的其他块数量最少',
      );
    });

    test('第 4 级：块数相同时比总位移分钟', () {
      final reference = {'b1': at(0)};
      final closer = LocalRepairPlan(
        blocks: [block('b1', 10, 60)],
        movedBlockIds: const {'b1'},
      );
      final farther = LocalRepairPlan(
        blocks: [block('b1', 50, 60)],
        movedBlockIds: const {'b1'},
      );

      expectSameVerdict(
        closer,
        farther,
        reference: reference,
        targetBlockId: 'b1',
        notBeforeUtc: at(0),
        reason: '§11.4 第 4 条：总位移分钟最少',
      );
    });

    test('第 5 级：块数与位移都相同时比目标块距下界', () {
      final nearer = LocalRepairPlan(
        blocks: [block('b1', 10, 60)],
        movedBlockIds: const {'b1'},
      );
      final farther = LocalRepairPlan(
        blocks: [block('b1', 40, 60)],
        movedBlockIds: const {'b1'},
      );

      expectSameVerdict(
        nearer,
        farther,
        reference: const {},
        targetBlockId: 'b1',
        notBeforeUtc: at(10),
        reason: '§11.4 第 5 条：目标块距离 notBeforeUtc 最近',
      );
    });

    test('第 6 级：坏空档数量更少者胜出', () {
      // 两份方案的块数与位移相同（都没有"已确认"参照），差别只在空档形状：
      // A 留一段 20 分钟的缝（不足最小片段 30 ⇒ 坏空档），B 首尾相接。
      final gappy = LocalRepairPlan(
        blocks: [block('b1', 0, 60), block('b2', 80, 60)],
        movedBlockIds: const {},
      );
      final tidy = LocalRepairPlan(
        blocks: [block('b1', 0, 60), block('b2', 60, 60)],
        movedBlockIds: const {},
      );

      expectSameVerdict(
        tidy,
        gappy,
        reference: const {},
        targetBlockId: 'b1',
        notBeforeUtc: at(0),
        tasks: [task()],
        reason: '§11.4 第 6 条：不制造无法利用的短空档',
      );
    });

    test('第 7 级：坏空档数量相同时比总分钟', () {
      // 两份方案各有一段坏空档（数量都是 1），但总分钟不同。
      final shorter = LocalRepairPlan(
        blocks: [block('b1', 0, 60), block('b2', 75, 60)],
        movedBlockIds: const {},
      );
      final longer = LocalRepairPlan(
        blocks: [block('b1', 0, 60), block('b2', 85, 60)],
        movedBlockIds: const {},
      );

      expectSameVerdict(
        shorter,
        longer,
        reference: const {},
        targetBlockId: 'b1',
        notBeforeUtc: at(0),
        tasks: [task()],
        reason: '§11.4 第 7 条：坏空档总分钟更少',
      );
    });
  });

  group('映射不给"§11.4 之外"的字段赋非零值', () {
    test('局部修复的比较不受均衡、片段与软偏好影响', () {
      // 同一对方案，把"均衡/片段/偏好"调到极端：局部修复的结论**不应改变**，
      // 因为它们不在 §11.4 的顺序里。
      final reference = {'b1': at(0)};
      final a = LocalRepairPlan(
        blocks: [block('b1', 10, 60)],
        movedBlockIds: const {'b1'},
      );
      final b = LocalRepairPlan(
        blocks: [block('b1', 50, 60)],
        movedBlockIds: const {'b1'},
      );

      final base = LocalRepairPlan.compare(
        a,
        b,
        reference: reference,
        targetBlockId: 'b1',
        notBeforeUtc: at(0),
      );
      // 直接构造的目标里这些字段非零时，结论**仍然**由第 4 级决定。
      final objectiveA = ScheduleObjective(
        hardViolationCount: 0,
        invariantViolationCount: 0,
        unfulfilledAdjustmentCount: 0,
        newShortageMinutesAgainstReference: 0,
        shortageMinutesByPriority: const [0, 0, 0, 0],
        maximumDailyUtilizationPermille: 100,
        totalOverTargetPermille: 0,
        pacingDeviationMinutes: 0,
        movedConfirmedBlockCount: 1,
        changedConfirmedBlockCount: 1,
        displacementMinutes: 10,
        extraTargetDisplacementMinutes: 10,
        recreatedBlockCount: 0,
        fragmentCount: 99,
        softPreferencePenalty: 99,
        orphanGapCount: 9,
        orphanGapMinutes: 999,
        stableSignature: 'a',
      );
      final objectiveB = ScheduleObjective(
        hardViolationCount: 0,
        invariantViolationCount: 0,
        unfulfilledAdjustmentCount: 0,
        newShortageMinutesAgainstReference: 0,
        shortageMinutesByPriority: const [0, 0, 0, 0],
        maximumDailyUtilizationPermille: 999,
        totalOverTargetPermille: 0,
        pacingDeviationMinutes: 0,
        movedConfirmedBlockCount: 1,
        changedConfirmedBlockCount: 1,
        displacementMinutes: 50,
        extraTargetDisplacementMinutes: 50,
        recreatedBlockCount: 0,
        fragmentCount: 0,
        softPreferencePenalty: 0,
        orphanGapCount: 0,
        orphanGapMinutes: 0,
        stableSignature: 'b',
      );

      expect(base, lessThan(0), reason: '位移更小者胜出');
      expect(
        compareScheduleObjectives(
          objectiveA,
          objectiveB,
          ScheduleObjectiveProfile.explicitAdjustment,
        ),
        lessThan(0),
        reason:
            '把均衡/片段/偏好调到相反方向也不改变结论——'
            '它们在 explicitAdjustment 的位移之后，而位移已经分出胜负',
      );
    });

    test('完全同分时由稳定签名分胜负（不以 0 收场）', () {
      final a = LocalRepairPlan(
        blocks: [block('b1', 0, 60)],
        movedBlockIds: const {},
      );
      final b = LocalRepairPlan(
        blocks: [block('b2', 0, 60)],
        movedBlockIds: const {},
      );

      final verdict = LocalRepairPlan.compare(
        a,
        b,
        reference: const {},
        targetBlockId: 'b1',
        notBeforeUtc: at(0),
      );
      expect(verdict, isNot(0), reason: '块 ID 不同 ⇒ 稳定签名不同 ⇒ 必须有唯一答案');
    });
  });
}
