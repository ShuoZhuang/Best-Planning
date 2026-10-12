// 1.8.0（用户第 72 轮）：**只针对当前调整请求**的精确拦截。
//
// 用户明确禁止的做法：
//
// > 不能因为方案中存在任意"未安排任务"就阻止应用。
//
// 因此这个纯函数只看**被延后的那一块所属任务**，别的任务有没有排进去完全不参与。
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
  }) => PlannedBlock(
    id: id,
    taskId: task,
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
  );

  /// 用户把 09:00（`at(0)`）的块延后 30 分钟 ⇒ 下界 09:30（`at(0.5)`），时长 60 分钟。
  AdjustmentRequirement requirement() => AdjustmentRequirement(
    targetBlockId: 'b-target',
    notBeforeUtc: at(0).add(const Duration(minutes: 30)),
    requiredMinutes: 60,
    originalStartUtc: at(0),
  );

  AdjustmentFulfilment evaluate(List<PlannedBlock> blocks) =>
      evaluateAdjustmentFulfilment(
        requirement: requirement(),
        taskId: 't-a',
        proposalBlocks: blocks,
      );

  test('**目标块仍在原位置 ⇒ 未兑现**', () {
    final result = evaluate([block('b-target', at(0))]);
    expect(result.isFulfilled, isFalse);
    expect(result.unsatisfiedReason, contains('原位置'));
  });

  test('**目标块被排在要求时间之前 ⇒ 未兑现**', () {
    // 仍离开了原位（在 `at(0.25)` = 09:15），但早于下界 09:30。
    final result = evaluate([block('b-moved', at(0), minutes: 60)]);
    expect(result.isFulfilled, isFalse);
  });

  test('**正确拆分且总时长完整 ⇒ 已兑现**（两块 30 分钟，均在界后）', () {
    final result = evaluate([
      block('p1', at(0).add(const Duration(minutes: 30)), minutes: 30),
      block('p2', at(1), minutes: 30),
    ]);
    expect(result.isFulfilled, isTrue, reason: '拆分是对的："各片段合计时长一致"就算兑现');
  });

  test('**总时长不足 ⇒ 未兑现**（下界之后只放下 30 分钟）', () {
    final result = evaluate([
      block('p1', at(0).add(const Duration(minutes: 30)), minutes: 30),
    ]);
    expect(result.isFulfilled, isFalse);
    expect(result.unsatisfiedReason, contains('时长'));
  });

  test('**重复块 ⇒ 未兑现**', () {
    final result = evaluate([block('dup', at(1)), block('dup', at(1))]);
    expect(result.isFulfilled, isFalse);
    expect(result.unsatisfiedReason, contains('重复'));
  });

  test('**延后后没有可用时间（一条都没排）⇒ 未兑现**', () {
    final result = evaluate([block('other', at(6), task: 't-z')]);
    expect(result.isFulfilled, isFalse);
  });

  test('**别的任务未安排不影响本调整的兑现判定**（用户第 4 条）', () {
    // 目标任务的块正确地落在界后、时长齐全；
    // 另有**别的任务**完全没排进去（`unscheduled` 会有它）——
    // 这不该让本调整判定为未兑现。
    final result = evaluate([block('moved', at(1))]);
    expect(
      result.isFulfilled,
      isTrue,
      reason: '拦截必须只针对当前调整请求，不能因为任意未安排任务就阻止应用',
    );
  });

  test('**下界之前的残留片段 ⇒ 未兑现**（即使后面有正确的一段）', () {
    final result = evaluate([
      block('leftover', at(0).add(const Duration(minutes: 15)), minutes: 30),
      block('after', at(2), minutes: 30),
    ]);
    expect(result.isFulfilled, isFalse);
    expect(result.unsatisfiedReason, contains('之前'));
  });
}
