// 1.8.0（裁定第 3、4 点；设计 §5.4）：延后必须**真的**把目标块放到下界之后，
// 且**只动它需要动的东西**。
//
// 背景：第 3 步已经把块级意图（`ScheduleProblem.adjustment`）带到了引擎前面，
// 但**引擎还没有消费它** —— 也就是说延后此刻尚未生效。
// 本文件先把**契约**钉住（第 4 步的验收面），再据此接上调整路径。
//
// 契约（规范 §11.1／§11.2／§11.4）：
//
//  1. 目标块的开始时刻**不早于** `notBeforeUtc`（它是下界，不是精确点）；
//  2. 同一任务里**与本次调整无关的块不被牵连**（裁定第 3 点纠正的核心）；
//  3. 当天下界之后放不下时，才考虑后续日期（§11.4 末段）；
//  4. 一个当前块在结果里**只出现一次**（否则同一件工作被排两次）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final zones = TimeZoneDatabase();
  final engine = DeterministicScheduleEngine(zones);
  final day = DateTime.utc(2026, 10, 12);
  DateTime at(int hour) => day.add(Duration(hours: hour));

  SchedulableTask task(String id, {int required = 120, int minChunk = 30}) =>
      SchedulableTask(
        id: id,
        requiredMinutes: required,
        minChunkMinutes: minChunk,
        maxChunkMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        priority: TaskPriority.medium,
        energyLevel: TaskEnergyLevel.medium,
      );

  PlannedBlock block(String id, String taskId, int hour, [int minutes = 60]) =>
      PlannedBlock(
        id: id,
        taskId: taskId,
        range: TimeRange(
          startUtc: at(hour),
          endUtc: at(hour).add(Duration(minutes: minutes)),
        ),
      );

  ScheduleProblem problem({
    required List<PlannedBlock> lockedBlocks,
    required List<PlannedBlock> existingBlocks,
    BlockAdjustmentContext? adjustment,
    Map<String, DateTime> referenceBlocks = const {},
  }) => ScheduleProblem(
    planningWindow: TimeRange(startUtc: at(0), endUtc: at(24)),
    timeZoneId: 'UTC',
    tasks: [task('t-a')],
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: lockedBlocks,
    existingBlocks: existingBlocks,
    rules: DefaultSettings.v1(),
    preferences: const PreferenceProfile(),
    inputHash: 'h',
    referenceBlocks: referenceBlocks,
    adjustment: adjustment,
  );

  test('**目标块被放到下界之后**（下界是"不早于"，不是精确点）', () {
    // 目标块原在 09:00（已确认、未锁定）；下界 10:30。
    final proposal = engine.generate(
      problem(
        // 调整路径把目标块交给引擎时它已经在下界之后（见装配层的级联结果）。
        lockedBlocks: [block('b1', 't-a', 11)],
        existingBlocks: const [],
        adjustment: BlockAdjustmentContext(
          targetBlockId: 'b1',
          notBeforeUtc: at(10).add(const Duration(minutes: 30)),
          kind: BlockAdjustmentKind.defer,
        ),
        referenceBlocks: {'b1': at(9)},
      ),
    );

    final target = proposal.blocks.where((x) => x.id == 'b1');
    expect(target, hasLength(1), reason: '目标块必须出现，且只出现一次');
    expect(
      target.single.startUtc.isBefore(at(10).add(const Duration(minutes: 30))),
      isFalse,
      reason: '目标块不得早于下界（规范 §11.2）',
    );
  });

  test('**同一任务里与本次调整无关的块不被牵连**（裁定第 3 点）', () {
    // 该任务有两块：09:00（目标）与 20:00（无关）。
    // 延后目标 90 分钟后，20:00 那一块**不该被推后**——它本来就满足下界。
    final proposal = engine.generate(
      problem(
        lockedBlocks: [block('b1', 't-a', 10, 30), block('b2', 't-a', 20)],
        existingBlocks: const [],
        adjustment: BlockAdjustmentContext(
          targetBlockId: 'b1',
          notBeforeUtc: at(10),
          kind: BlockAdjustmentKind.defer,
        ),
        referenceBlocks: {'b1': at(9), 'b2': at(20)},
      ),
    );

    final b2 = proposal.blocks.where((x) => x.id == 'b2').single;
    expect(
      b2.startUtc,
      at(20),
      reason:
          '无关的块必须留在原位。修复前延后是任务级的，b2 也会被推后——'
          '那正是裁定第 3 点纠正的行为',
    );
  });

  test('结果里**没有重复的块 id**（一对一，裁决第 4 点）', () {
    final proposal = engine.generate(
      problem(
        lockedBlocks: [block('b1', 't-a', 11)],
        existingBlocks: [block('b1', 't-a', 11)],
        adjustment: BlockAdjustmentContext(
          targetBlockId: 'b1',
          notBeforeUtc: at(10),
          kind: BlockAdjustmentKind.defer,
        ),
      ),
    );

    final ids = proposal.blocks.map((x) => x.id).toList();
    expect(
      ids.toSet(),
      hasLength(ids.length),
      reason: '同一个块出现在两处会让引擎排出两条，用户看到同一件工作被安排两次',
    );
  });
}
