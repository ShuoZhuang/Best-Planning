import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/frozen_block_policy.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

final _now = DateTime.utc(2026, 10, 17, 12);

PlannedBlock _block(
  String id, {
  int startHour = 14,
  int endHour = 15,
  bool locked = false,
}) => PlannedBlock(
  id: id,
  taskId: 'task-$id',
  range: TimeRange(
    startUtc: DateTime.utc(2026, 10, 17, startHour),
    endUtc: DateTime.utc(2026, 10, 17, endHour),
  ),
  locked: locked,
);

void main() {
  test('已执行块冻结', () {
    final frozen = computeFrozenBlockIds(
      baseline: [_block('done', startHour: 8, endHour: 9)],
      nowUtc: _now,
      executingBlockIds: const {},
      explicitlyPinnedIds: const {},
    );
    expect(frozen, {'done'});
  });

  test('执行中块冻结', () {
    final frozen = computeFrozenBlockIds(
      baseline: [_block('running', startHour: 11, endHour: 13)],
      nowUtc: _now,
      executingBlockIds: const {},
      explicitlyPinnedIds: const {},
    );
    expect(frozen, {'running'});
  });

  test('显式锁定与手动钉住都冻结', () {
    final frozen = computeFrozenBlockIds(
      baseline: [
        _block('locked', locked: true),
        _block('pinned'),
        _block('future'),
      ],
      nowUtc: _now,
      executingBlockIds: const {},
      explicitlyPinnedIds: const {'pinned'},
    );
    expect(frozen, {'locked', 'pinned'});
  });

  test('未锁定的未来块可移动', () {
    final frozen = computeFrozenBlockIds(
      baseline: [_block('future')],
      nowUtc: _now,
      executingBlockIds: const {},
      explicitlyPinnedIds: const {},
    );
    expect(frozen, isEmpty);
  });

  test('目标调整块不被冻结，即使它带锁定标记', () {
    final frozen = computeFrozenBlockIds(
      baseline: [_block('target', locked: true), _block('other', locked: true)],
      nowUtc: _now,
      executingBlockIds: const {},
      explicitlyPinnedIds: const {'target'},
      adjustment: BlockAdjustmentContext(
        targetBlockId: 'target',
        notBeforeUtc: _now,
        kind: BlockAdjustmentKind.defer,
      ),
    );
    expect(frozen, {'other'});
  });

  test('来源缺失时阻断而不是猜测', () {
    expect(
      () => computeFrozenBlockIds(
        baseline: [_block('a')],
        nowUtc: _now,
        executingBlockIds: const {'ghost'},
        explicitlyPinnedIds: const {},
      ),
      throwsStateError,
    );
    expect(
      () => computeFrozenBlockIds(
        baseline: [_block('a')],
        nowUtc: _now,
        executingBlockIds: const {},
        explicitlyPinnedIds: const {},
        adjustment: BlockAdjustmentContext(
          targetBlockId: 'ghost',
          notBeforeUtc: _now,
          kind: BlockAdjustmentKind.defer,
        ),
      ),
      throwsStateError,
    );
  });

  test('空集合、重复 ID 与稳定排序', () {
    expect(
      computeFrozenBlockIds(
        baseline: const [],
        nowUtc: _now,
        executingBlockIds: const {},
        explicitlyPinnedIds: const {},
      ),
      isEmpty,
    );
    expect(
      () => computeFrozenBlockIds(
        baseline: [_block('a'), _block('a')],
        nowUtc: _now,
        executingBlockIds: const {},
        explicitlyPinnedIds: const {},
      ),
      throwsArgumentError,
    );
    final frozen = computeFrozenBlockIds(
      baseline: [
        _block('z', locked: true),
        _block('a', locked: true),
        _block('m', locked: true),
      ],
      nowUtc: _now,
      executingBlockIds: const {},
      explicitlyPinnedIds: const {},
    );
    expect(frozen.toList(), ['a', 'm', 'z']);
  });
}
