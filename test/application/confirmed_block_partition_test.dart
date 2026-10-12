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
    planningWindowStartUtc: nowUtc ?? at(0),
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

  test('**锁定块只属于 `hardOccupied`**，已结束的块属于 `historical`（用户第 2 条）', () {
    final partition = partitionOf(
      confirmed: [
        block('b-locked', 6, locked: true),
        block('b-past', -2),
        block('b-plain', 12),
      ],
      // 现在 = 本地 09:00（`at(0)`）；`b-past` 在 `at(-2)`、60 分钟 ⇒ 已结束。
      nowUtc: at(0),
    );

    expect(partition.categoriesFor('b-locked'), [
      ConfirmedBlockRole.hardOccupied,
    ]);
    expect(
      partition.categoriesFor('b-past'),
      [ConfirmedBlockRole.historical],
      reason:
          '**本轮改过**：已结束的块此前与锁定块同在 `hardOccupied`，于是装配层把'
          '`hardOccupiedIds` 整体放进 `lockedBlocks`，昨天的块因此进了提案'
          '（2026-10-12 实机故障的 R1）。历史与硬占用是两件事：'
          '前者**不进入**本次排程输入，后者进入且只占位。',
    );
  });

  test('**边界：恰好在窗口起点结束属于 `historical`，恰好开始属于未来**', () {
    // 半开区间规则（冻结决策 §1.3）：
    //   · `end <= 起点` ⇒ historical（**用 `<=`，不留端点缝隙**）；
    //   · `start == 起点` ⇒ 既不是历史、也不跨过起点 ⇒ 未来。
    final atStart = partitionOf(
      confirmed: [block('b-start-at-start', 0, minutes: 60)],
      nowUtc: at(0),
    );
    expect(atStart.categoriesFor('b-start-at-start'), [
      ConfirmedBlockRole.existing,
    ], reason: '起点恰好在窗口起点 ⇒ 属于未来（与"恰好在起点结束"是一对互补边界）');

    final boundary = partitionOf(
      confirmed: [
        // 08:00–09:00：结束时刻**恰好等于**窗口起点。
        PlannedBlock(
          id: 'b-ends-at-start',
          taskId: 't-a',
          range: TimeRange(startUtc: at(-1), endUtc: at(0)),
        ),
        // 08:30–09:30：跨过窗口起点。
        PlannedBlock(
          id: 'b-ongoing',
          taskId: 't-a',
          range: TimeRange(
            startUtc: at(0).subtract(const Duration(minutes: 30)),
            endUtc: at(0).add(const Duration(minutes: 30)),
          ),
        ),
      ],
      nowUtc: at(0),
    );

    expect(boundary.categoriesFor('b-ends-at-start'), [
      ConfirmedBlockRole.historical,
    ], reason: '`end == 起点` 必须归历史：用 `isBefore` 会在这里留出一条端点缝隙');
    expect(
      boundary.categoriesFor('b-ongoing'),
      [ConfirmedBlockRole.hardOccupied],
      reason:
          '跨过窗口起点 ⇒ **进行中**：原位且不可移动。'
          '修复前它落到 `existing`，于是被局部改进搬走（实测 09:15 → 13:45）',
    );
  });

  test('**过去的块若被明确指定为调整目标，调整角色优先于 `historical`**', () {
    // 优先级是"先到先得"：用户**明确**要求调整的那一块仍然要能被表达出来，
    // 否则"修正昨天放错的那一块"这件事在界面上就无从落地。
    final partition = partitionOf(
      confirmed: [block('b-past', -2), block('b-plain', 12)],
      adjustedTargetId: 'b-past',
      nowUtc: at(0),
    );

    expect(partition.categoriesFor('b-past'), [
      ConfirmedBlockRole.replacedByAdjustment,
    ]);
    expect(partition.historicalIds, isNot(contains('b-past')));
  });

  test('**历史块不出现在任何未来集合里**', () {
    final partition = partitionOf(
      confirmed: [
        block('b-past', -2),
        block('b-locked', 6, locked: true),
        block('b-plain', 12),
      ],
      nowUtc: at(0),
    );

    for (final id in ['b-past']) {
      expect(partition.historicalIds, contains(id));
      expect(partition.hardOccupiedIds, isNot(contains(id)));
      expect(partition.existingIds, isNot(contains(id)));
      expect(partition.frozenIds, isNot(contains(id)));
      expect(partition.takenOverIds, isNot(contains(id)));
    }
  });

  test('**每个确认块 ID 仍然恰好一个角色**（历史与硬占用不得重叠）', () {
    final partition = partitionOf(
      confirmed: [
        block('b-past', -2),
        block('b-ongoing-half', 0),
        block('b-locked', 6, locked: true),
        block('b-plain', 12),
      ],
      nowUtc: at(0),
    );

    final all = partition.allCategoryIds;
    expect(all.length, all.toSet().length);
    expect(partition.historicalIds, {
      'b-past',
    }, reason: '`b-ongoing-half` 在 09:00 开始、都在窗口起点之后 ⇒ 不是历史');
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
