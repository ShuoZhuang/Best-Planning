// 1.8.0（用户第 73 轮）：**多块任务的延后不得被误判为"时长不一致"**。
//
// 缺陷：`evaluateAdjustmentFulfilment` 把"**同一任务的所有计划块**"加起来，
// 与 `AdjustmentRequirement.requiredMinutes`（**被延后那一块**的时长）比较。
// 一个任务本来就被拆成多块时，只延后其中一块就会算出 sum(所有块) ≠ 该块时长
// ⇒ 被误判为未兑现 ⇒ **禁止应用**。
//
// 正确口径：只看**被延后那一块的延续者**。
// 延续关系由来源关联给出（`continuedFromId`，裁定第 1、4 点）：
//   · 未被拆分 ⇒ 提案里就是原 id；
//   · 被拆分 ⇒ 各片段带 `continuedFromId == 目标块 id`；
//   · 被级联接管的块 ⇒ 也保留原 id。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final dayStart = DateTime.utc(2026, 10, 12, 1);
  DateTime at(int hour) => dayStart.add(Duration(hours: hour));

  PlannedBlock block(
    String id,
    DateTime start, {
    int minutes = 60,
    String task = 't-a',
    String? continuedFromId,
  }) => PlannedBlock(
    id: id,
    taskId: task,
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
    continuedFromId: continuedFromId,
  );

  /// 用户把 09:00（`at(0)`）那一块延后 30 分钟 ⇒ 下界 09:30（`at(0.5)`），
  /// **该块**时长 60 分钟。
  AdjustmentRequirement requirement() => AdjustmentRequirement(
    targetBlockId: 'b-target',
    notBeforeUtc: at(0).add(const Duration(minutes: 30)),
    requiredMinutes: 60,
    originalStartUtc: at(0),
  );

  AdjustmentFulfilment evaluate(List<PlannedBlock> blocks) =>
      evaluateAdjustmentFulfilment(
        requirement: requirement(),
        proposalBlocks: blocks,
      );

  test('**同一任务还有别的块时，只看被延后那一块的延续者**', () {
    // 任务被拆成两块：`b-target`（09:00，本次延后）与 `b-sibling`（14:00，无关）。
    // 延后后 `b-target` 落到 09:30。任务总时长是 120 分钟，
    // 但**本次延后涉及的只有 60 分钟**。
    final result = evaluate([
      // 被延后那一块的延续者（未拆分 ⇒ 保留原 id）。
      block('b-target', at(0).add(const Duration(minutes: 30))),
      // 无关的兄弟块：它不该参与本次延后的时长核对。
      block('b-sibling', at(5)),
    ]);

    expect(
      result.isFulfilled,
      isTrue,
      reason:
          '只看被延后那一块 ⇒ 60 分钟一致 ⇒ 已兑现。'
          '修复前会把两块相加得 120 分钟，误判为"时长不一致"并禁止应用',
    );
  });

  test('**被延后那一块拆成两段时，合计仍要等于该块时长**', () {
    final result = evaluate([
      block(
        'p1',
        at(0).add(const Duration(minutes: 30)),
        minutes: 30,
        continuedFromId: 'b-target',
      ),
      block('p2', at(1), minutes: 30, continuedFromId: 'b-target'),
      // 兄弟块也在，同样不参与。
      block('b-sibling', at(5)),
    ]);

    expect(
      result.isFulfilled,
      isTrue,
      reason: '两段各 30 分钟 ⇒ 合计 60 分钟 ⇒ 已兑现；兄弟块不参与',
    );
  });

  test('**被延后那一块的延续者时长不足 ⇒ 仍未兑现**（不能因为"有兄弟块"就放松）', () {
    final result = evaluate([
      block('b-target', at(0).add(const Duration(minutes: 30)), minutes: 30),
      // 兄弟块总时长很大 —— 修复前它会把总时长"补"成 60 而误判为已兑现。
      block('b-sibling', at(5), minutes: 30),
    ]);

    expect(
      result.isFulfilled,
      isFalse,
      reason:
          '被延后那一块只放下 30 分钟 ⇒ 未兑现。'
          '兄弟块的时长不得用来"凑数"',
    );
  });
}
