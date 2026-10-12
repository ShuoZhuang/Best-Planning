// 1.8.0（用户第 70 轮）：**确认块互斥分区的纯函数**。
//
// 为什么不能只抽 `frozenIds`：第 67 轮那个缺陷的形态**不是某个集合算错**，
// 而是**同一个块同时进入了 `lockedBlocks`、冻结集合与 `existingBlocks`**。
// 只断言 `frozenIds` 仍然抓不到集合重叠。因此抽的是**互斥分区规则**：
//
//   · 纯函数测试负责证明**分类正确**；
//   · 端到端测试负责证明**生产装配确实使用了这个分类**。
//
// 纯函数必须保证（用户列的六条）：
//   1. 每个确认块 ID 只能属于一个类别；
//   2. 锁定块与已过去的块只属于 `hardOccupied`；
//   3. 钉住、调整目标、被挤开块用**替换结果**，原块不得再进其他集合；
//   4. 局部修复成功时，未受影响的可移动块属于 `frozen`；
//   5. 局部修复失败时，`frozen` 必须为空，可移动块回到 `existing`；
//   6. 跳过或不可排任务属于 `excluded`。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/confirmed_block_partition.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final dayStart = DateTime.utc(2026, 10, 12, 1);
  DateTime at(int hour) => dayStart.add(Duration(hours: hour));

  PlannedBlock block(
    String id,
    int hour, {
    int minutes = 60,
    bool locked = false,
    String task = 't-a',
  }) => PlannedBlock(
    id: id,
    taskId: task,
    range: TimeRange(
      startUtc: at(hour),
      endUtc: at(hour).add(Duration(minutes: minutes)),
    ),
    locked: locked,
  );

  /// 默认输入：两个可排任务、无跳过、无钉住、无调整。
  ConfirmedBlockPartition partitionOf({
    required List<PlannedBlock> confirmed,
    Set<String> schedulableTaskIds = const {'t-a'},
    Set<String> skippedBlockIds = const {},
    Set<String> pinnedBlockIds = const {},
    bool adjustmentSucceeded = false,
    String? adjustedTargetId,
    Set<String> displacedIds = const {},
    Set<String> lockedOverlayIds = const {},
    DateTime? nowUtc,
  }) => classifyConfirmedBlocks(
    confirmed: confirmed,
    schedulableTaskIds: schedulableTaskIds,
    skippedBlockIds: skippedBlockIds,
    pinnedBlockIds: pinnedBlockIds,
    // "有调整意图"与"调整成功"是两件事：失败时 `adjustedTargetId` 为空。
    adjustmentRequested: adjustmentSucceeded || adjustedTargetId != null,
    adjustedTargetId: adjustedTargetId,
    displacedIds: displacedIds,
    lockedOverlayIds: lockedOverlayIds,
    nowUtc: nowUtc ?? at(0),
  );

  test('**每个确认块 ID 只属于一个类别**（互斥）', () {
    final partition = partitionOf(
      confirmed: [
        block('b-target', 0),
        block('b-locked', 6, locked: true),
        block('b-plain', 12),
        block('b-past', -2),
        block('b-skipped', 18),
        block('b-othertask', 20, task: 't-z'),
      ],
      skippedBlockIds: {'b-skipped'},
      adjustedTargetId: 'b-target',
    );

    final all = partition.allCategoryIds;
    expect(
      all.length,
      all.toSet().length,
      reason: '同一个块不得出现在两个类别里 —— 这正是第 67 轮缺陷的形态',
    );
    expect(
      partition.categoriesFor('b-locked'),
      hasLength(1),
      reason: '锁定块只能有一个类别',
    );
    expect(
      partition.categoriesFor('b-target'),
      hasLength(1),
      reason: '调整目标只能有一个类别',
    );
  });

  test('**锁定块与已过去的块只属于 `hardOccupied`**（用户第 2 条）', () {
    final partition = partitionOf(
      confirmed: [
        block('b-locked', 6, locked: true),
        block('b-past', -2),
        block('b-plain', 12),
      ],
      // 现在 = 本地 09:00（`at(0)`）；`b-past` 在 `at(-2)`、60 分钟 ⇒ 已过去。
      nowUtc: at(0),
    );

    expect(partition.categoriesFor('b-locked'), [
      ConfirmedBlockRole.hardOccupied,
    ]);
    expect(partition.categoriesFor('b-past'), [
      ConfirmedBlockRole.hardOccupied,
    ]);
  });

  test('**钉住／调整目标／被挤开使用替换结果**，原块不再进其他集合（用户第 3 条）', () {
    final partition = partitionOf(
      confirmed: [
        block('b-target', 0),
        block('b-pinned', 6),
        block('b-squeezed', 12),
      ],
      pinnedBlockIds: {'b-pinned'},
      adjustedTargetId: 'b-target',
      displacedIds: {'b-squeezed'},
    );

    expect(partition.categoriesFor('b-pinned'), [
      ConfirmedBlockRole.replacedByPin,
    ]);
    expect(partition.categoriesFor('b-target'), [
      ConfirmedBlockRole.replacedByAdjustment,
    ]);
    expect(partition.categoriesFor('b-squeezed'), [
      ConfirmedBlockRole.displaced,
    ]);
    // 三者都不得同时出现在 frozen／existing。
    for (final id in ['b-pinned', 'b-target', 'b-squeezed']) {
      expect(
        partition.categoriesFor(id),
        hasLength(1),
        reason: '$id 被替换后不得再进入其他集合',
      );
    }
  });

  test('**局部修复成功 ⇒ 未受影响的可移动块属于 `frozen`**（用户第 4 条）', () {
    final partition = partitionOf(
      confirmed: [block('b-target', 0), block('b-plain', 12)],
      adjustmentSucceeded: true,
      adjustedTargetId: 'b-target',
    );

    expect(partition.frozenIds, {'b-plain'}, reason: '修复成功 ⇒ 未受影响的可移动块原位冻结');
    expect(partition.categoriesFor('b-plain'), [ConfirmedBlockRole.frozen]);
  });

  test('**局部修复失败 ⇒ `frozen` 必须为空**，可移动块回到 `existing`（用户第 5 条）', () {
    final partition = partitionOf(
      confirmed: [block('b-target', 0), block('b-plain', 12)],
      // 有调整意图，但级联失败 ⇒ `adjustedTargetId` 为空。
      adjustmentSucceeded: false,
      adjustedTargetId: null,
    );

    expect(
      partition.frozenIds,
      isEmpty,
      reason:
          '修复失败时**绝不能冻结**：把目标块冻在原位就是"保持原位置却显示成功"。'
          '可移动块必须交回引擎',
    );
    expect(partition.categoriesFor('b-plain'), [
      ConfirmedBlockRole.existing,
    ], reason: '失败 ⇒ 可移动块回到 existing，由全局引擎真正接管');
    expect(partition.categoriesFor('b-target'), [
      ConfirmedBlockRole.existing,
    ], reason: '失败时目标块也回到 existing（不冻结），否则延后失效');
  });

  test('**跳过或不可排任务属于 `excluded`**（用户第 6 条）', () {
    final partition = partitionOf(
      confirmed: [
        block('b-skipped', 6),
        block('b-othertask', 12, task: 't-z'),
        block('b-plain', 18),
      ],
      skippedBlockIds: {'b-skipped'},
    );

    expect(partition.categoriesFor('b-skipped'), [ConfirmedBlockRole.excluded]);
    expect(partition.categoriesFor('b-othertask'), [
      ConfirmedBlockRole.excluded,
    ], reason: '任务不在可排集合里 ⇒ 该块被排除');
    expect(partition.categoriesFor('b-plain'), [ConfirmedBlockRole.existing]);
  });

  test('`lockedOverlayIds`（拖动后的覆盖结果）属于 `replacedByPin`', () {
    final partition = partitionOf(
      confirmed: [block('b-pinned', 6)],
      lockedOverlayIds: {'b-pinned'},
    );

    expect(partition.categoriesFor('b-pinned'), [
      ConfirmedBlockRole.replacedByPin,
    ]);
  });

  test('分区结果与输入排列无关（确定性）', () {
    final confirmed = [
      block('b-target', 0),
      block('b-locked', 6, locked: true),
      block('b-plain', 12),
    ];
    final a = partitionOf(confirmed: confirmed, adjustedTargetId: 'b-target');
    final b = partitionOf(
      confirmed: confirmed.reversed.toList(),
      adjustedTargetId: 'b-target',
    );

    expect(a.frozenIds, b.frozenIds);
    expect(a.allCategoryIds.length, b.allCategoryIds.length);
  });
}
