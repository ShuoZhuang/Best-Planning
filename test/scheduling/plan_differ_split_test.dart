// T2/T4：`PlanChangeType.split` 这个生产分支此前没有任何测试覆盖。
//
// 登记 T2 原先说 `plan_preview_test` 手写的 `split` 是"不可达状态"；核实后那句话已失效——
// `plan_differ.dart:89` 确实会产出 `split`。但同一轮 grep 暴露了相反的问题：**全库测试里
// 一次都没出现 `PlanChangeType.split`**，即"会产出"这条分支从未被断言。因此补在这里。
//
// 判定条件是两个布尔量的合取（`plan_differ.dart:82-90`），所以三例分别覆盖：两者都真 →
// `split`；只"原本有块"为真 → `added`；只"块数变多"为真 → `added`。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/plan_differ.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

PlannedBlock _block(String id, String taskId, int hour) => PlannedBlock(
  id: id,
  taskId: taskId,
  range: TimeRange(
    startUtc: DateTime.utc(2026, 10, 5, hour),
    endUtc: DateTime.utc(2026, 10, 5, hour + 1),
  ),
  explanationCode: 'priority',
);

PlanChange _changeFor(PlanDiff diff, String blockId) =>
    diff.changes.singleWhere((change) => change.blockId == blockId);

void main() {
  const differ = PlanDiffer();

  test('原本已有块且块数变多 → 新块记为 split', () {
    final diff = differ.diff(
      [_block('a', 'task-1', 9)],
      [_block('a', 'task-1', 9), _block('b', 'task-1', 11)],
    );

    // 未变动的块不产生变更；只有新增的那一块被记为拆分。
    expect(diff.changes, hasLength(1));
    expect(_changeFor(diff, 'b').type, PlanChangeType.split);
    expect(_changeFor(diff, 'b').reason, 'priority');
  });

  test('原本没有该任务的块 → 即使一次来了两块也是 added', () {
    final diff = differ.diff(const [], [
      _block('a', 'task-1', 9),
      _block('b', 'task-1', 11),
    ]);

    // "原本有块"为假，因此不构成拆分，而是首次排入。
    expect(
      diff.changes.map((change) => change.type),
      everyElement(PlanChangeType.added),
    );
  });

  test('原本有块但块数没变多（换了块）→ 记为 added 而不是 split', () {
    final diff = differ.diff(
      [_block('a', 'task-1', 9)],
      // 旧块 a 被移除、新块 b 顶上：任务总块数仍是 1。
      [_block('b', 'task-1', 14)],
    );

    expect(_changeFor(diff, 'a').type, PlanChangeType.removed);
    expect(_changeFor(diff, 'b').type, PlanChangeType.added);
    expect(
      diff.changes.where((change) => change.type == PlanChangeType.split),
      isEmpty,
    );
  });
}
