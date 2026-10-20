// 1.11.0（计划 Task 13 Step 2、DFR-042）：冻结块与软稳定块的纯函数矩阵。
//
// 修复前"哪些块必须保留"藏在装配流程里，目标块经常被顺带冻回原位——
// 于是"延后成功"与"原地不动"分不开。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/stable_block_identity.dart';

void main() {
  final now = DateTime.utc(2026, 10, 19, 5);

  PlannedBlock block({
    required String id,
    required DateTime start,
    int minutes = 30,
    bool locked = false,
  }) => PlannedBlock(
    id: id,
    taskId: 'task-$id',
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
    locked: locked,
  );

  final baseline = [
    block(id: 'future-unlocked', start: DateTime.utc(2026, 10, 19, 9)),
    block(
      id: 'future-locked',
      start: DateTime.utc(2026, 10, 19, 10),
      locked: true,
    ),
    // 正在进行：09:45 → 10:15，跨过 now（05:00? 不跨；这里用 04:50 → 05:10）。
    block(id: 'ongoing', start: DateTime.utc(2026, 10, 19, 4, 50)),
    block(id: 'finished', start: DateTime.utc(2026, 10, 19, 3)),
    block(id: 'started-evidence', start: DateTime.utc(2026, 10, 19, 9)),
    block(id: 'target', start: DateTime.utc(2026, 10, 19, 8), locked: true),
  ];

  test('冻结集合包含锁定、进行中、已结束、已开始的块，排除目标块', () {
    final frozen = computeFrozenBlockIds(
      baselineBlocks: baseline,
      targetBlockId: 'target',
      nowUtc: now,
      executionStartedBlockIds: {'started-evidence'},
    );

    expect(frozen, {
      'future-locked',
      'ongoing',
      'finished',
      'started-evidence',
    });
    expect(
      frozen.contains('target'),
      isFalse,
      reason: '目标块即使锁定/已开始也不得进入冻结集合，否则回退会"原地成功"',
    );
    expect(frozen.contains('future-unlocked'), isFalse);
  });

  test('返回的集合不可变', () {
    final frozen = computeFrozenBlockIds(
      baselineBlocks: baseline,
      targetBlockId: 'target',
      nowUtc: now,
      executionStartedBlockIds: const {},
    );

    expect(() => frozen.add('x'), throwsUnsupportedError);
  });

  test('软稳定集合是"未冻结且非目标"的未来未锁定块', () {
    final reference = computeReferenceBlockIds(
      baselineBlocks: baseline,
      targetBlockId: 'target',
      nowUtc: now,
      executionStartedBlockIds: {'started-evidence'},
    );

    expect(reference, {'future-unlocked'});
  });

  test('空基线返回空集合；非 UTC 的 now 被拒绝', () {
    expect(
      computeFrozenBlockIds(
        baselineBlocks: const [],
        targetBlockId: 'target',
        nowUtc: now,
        executionStartedBlockIds: const {},
      ),
      isEmpty,
    );
    expect(
      () => computeFrozenBlockIds(
        baselineBlocks: baseline,
        targetBlockId: 'target',
        nowUtc: DateTime(2026, 10, 19, 5),
        executionStartedBlockIds: const {},
      ),
      throwsArgumentError,
    );
  });

  test('开始时刻恰好等于现在按"已开始"处理（半开区间语义）', () {
    final frozen = computeFrozenBlockIds(
      baselineBlocks: [block(id: 'edge', start: now)],
      targetBlockId: 'target',
      nowUtc: now,
      executionStartedBlockIds: const {},
    );

    expect(frozen, {'edge'});
  });
}
