// 1.8.0（用户第 69 轮）：**级联失败时"不冻结任何块"这条边界的直接覆盖**。
//
// 背景：装配层用
//
//     final frozenIds = adjustment != null && adjustedTarget != null ? {...} : {}
//
// 作门槛。`adjustedTarget == null` 表示级联当天不可行（回退路径），
// 此时**不能**把目标块冻结在原位，否则延后彻底失效。
//
// 上一轮我尝试用"端到端 + 日历堵死"来覆盖它，**没走通**：
// 那种夹具里级联失败的原因是"整天没有连续 60 分钟"，而窗口是 7 天，
// 引擎仍能把任务排到别处，于是目标块本来就不在原位。
//
// 本文件改用**能确定触发级联失败**的构造：目标块**太长**，
// 目标当天从下界起到日终再也放不下它（下界靠近日终）。
// 这是级联必然失败的场景，且它与"日历里有什么"无关，因此不脆。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  // 东八区 2026-10-12（周一）09:00 = 01:00Z
  final dayStart = DateTime.utc(2026, 10, 12, 1);
  DateTime at(int hour) => dayStart.add(Duration(hours: hour));

  PlannedBlock block(String id, DateTime start, {int minutes = 60}) =>
      PlannedBlock(
        id: id,
        taskId: 't-a',
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(Duration(minutes: minutes)),
        ),
      );

  test('**级联当天不可行时返回 infeasible，且块的相对位置不变**', () {
    // 目标块 60 分钟在本地 09:00（`at(0)`），下界本地 23:30（`at(14.5)`）：
    // 目标当天从 23:30 起只剩 30 分钟，放不下 60 分钟 ⇒ **级联必然失败**。
    final outcome = repairBestPlanDayScoped(
      targetBlockId: 'b-target',
      notBeforeUtc: at(14).add(const Duration(minutes: 30)),
      blocks: [block('b-target', at(0)), block('b-other', at(12))],
      immovable: const [],
      targetStartUtc: at(0),
      timeZoneId: zoneId,
      zones: zones,
      // 窗口终点只到目标当天（不开后门），因此"放宽到窗口终点"也救不回来。
      planningEndUtc: at(15),
      tasks: const [],
    );

    expect(
      outcome.feasible,
      isFalse,
      reason:
          '当天从下界起放不下 60 分钟、且窗口终点就在当天 ⇒ 级联必须如实报不可行。'
          '这正是装配层 `adjustedTarget == null` 的那条分支',
    );
    expect(
      outcome.blocks,
      isEmpty,
      reason:
          '不可行时**不得返回任何"看起来像结果"的块**（返回原样会被误当成成功）。'
          '装配层据此保持 `adjustedTarget == null` ⇒ 不冻结任何块 ⇒ 目标块不被冻在原位',
    );
  });

  test('**同一天但下界之前有空间时仍然可行**（对照，确认上一条不是恒 true）', () {
    // 同一组块，只把下界移回本地 09:30（`at(0.5)`）⇒ 当天放得下 ⇒ 可行。
    final outcome = repairBestPlanDayScoped(
      targetBlockId: 'b-target',
      notBeforeUtc: at(0).add(const Duration(minutes: 30)),
      blocks: [block('b-target', at(0)), block('b-other', at(12))],
      immovable: const [],
      targetStartUtc: at(0),
      timeZoneId: zoneId,
      zones: zones,
      planningEndUtc: at(15),
      tasks: const [],
    );

    expect(
      outcome.feasible,
      isTrue,
      reason: '对照组：下界之后放得下 ⇒ 必须可行（否则上一条的断言没有意义）',
    );
    expect(outcome.blocks.map((b) => b.id).toSet(), {
      'b-target',
      'b-other',
    }, reason: '可行时两块都在结果里');
  });

  test('**放不下时不得把目标块"留在原位"当作结果**', () {
    // 这条直接钉用户第 68 轮的红线在**核心函数**层的表现：
    // 级联不可行时，如果它返回"目标块留在原位"的块列表，
    // 上层就可能把"保持原位置"当成延后成功。
    final outcome = repairBestPlanDayScoped(
      targetBlockId: 'b-target',
      notBeforeUtc: at(14).add(const Duration(minutes: 30)),
      blocks: [block('b-target', at(0))],
      immovable: const [],
      targetStartUtc: at(0),
      timeZoneId: zoneId,
      zones: zones,
      planningEndUtc: at(15),
      tasks: const [],
    );

    expect(outcome.feasible, isFalse);
    expect(
      outcome.blocks.any((b) => b.id == 'b-target' && b.startUtc == at(0)),
      isFalse,
      reason:
          '不可行时**绝不能**返回"目标块在原位"。'
          '那正是"保持原位置却显示成功"的原料',
    );
  });
}
