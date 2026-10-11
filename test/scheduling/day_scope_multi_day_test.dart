// 1.8.0（规范 §11.4 末段；用户第 64 轮复核）：
// **多日计划下的"当天优先"**，以及**跨午夜的固定日程／保护时间**。
//
// 上一轮我补了 `repairBestPlanDayScoped`（当天优先）并把固定日程／保护时间接成硬障碍。
// 但复核发现还差一层：**"当天尝试"的输入与它的校验口径不一致**。
//
//   · 输入：整个规划窗口（默认 7 天）里的**全部**确认块 + 全部固定／保护区间；
//   · 校验（`_isLegalRepairCandidate`）：结果里**每一个块**都要落在目标当天之内。
//
// 两者一撞，只要**后几天**存在确认块、固定日程或保护时间，
// "当天尝试"就会被**误判失败**，然后退回七天范围重挑 —— 当天优先形同虚设。
//
// 正确口径（用户给出的三条）：
//   1. 当天尝试**只处理目标当天的可移动块**；
//   2. 后续日期的块**保持原位**，不参与当天候选的合法性判断；
//   3. 不可移动障碍**只负责占位**，不能因为自身位于后续日期或跨午夜就让当天方案失败。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  // 东八区 2026-10-12（周一）09:00 = 01:00Z
  final monday = DateTime.utc(2026, 10, 12, 1);
  DateTime at(int hour) => monday.add(Duration(hours: hour));

  PlannedBlock block(String id, DateTime start, {int minutes = 60}) =>
      PlannedBlock(
        id: id,
        taskId: 't-a',
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(Duration(minutes: minutes)),
        ),
      );

  test('**后几天有确认块时，当天尝试仍然成立**（不退回七天窗口）', () {
    // 目标块在周一 09:00（本地），下界 09:30。
    // 周二另有一块确认块 —— 它**不该**让"周一当天"的方案被判非法。
    final outcome = repairBestPlanDayScoped(
      targetBlockId: 'mon',
      notBeforeUtc: at(0).add(const Duration(minutes: 30)),
      blocks: [
        block('mon', at(0)),
        // 周二 09:00（本地）= `at(24)`
        block('tue', at(24)),
      ],
      immovable: const [],
      targetStartUtc: at(0),
      timeZoneId: zoneId,
      zones: zones,
      planningEndUtc: at(24 * 7),
      tasks: const [],
    );

    expect(outcome.feasible, isTrue);
    final mon = outcome.blocks.firstWhere((b) => b.id == 'mon');
    // 周一本地日终 = 本地 24:00 = `at(15)`。
    expect(
      mon.startUtc.isBefore(at(15)),
      isTrue,
      reason:
          '修复前：周二那块会让"当天尝试"的候选校验失败，'
          '于是退回七天范围，目标块可能落到几天之后',
    );
  });

  test('**后几天有固定日程时，当天尝试仍然成立**', () {
    // 周二整天有一个固定日程（跨到周三），它只该占位，不该让周一方案失败。
    final outcome = repairBestPlanDayScoped(
      targetBlockId: 'mon',
      notBeforeUtc: at(0).add(const Duration(minutes: 30)),
      blocks: [block('mon', at(0))],
      immovable: [block('fixed:tue', at(24), minutes: 600)],
      targetStartUtc: at(0),
      timeZoneId: zoneId,
      zones: zones,
      planningEndUtc: at(24 * 7),
      tasks: const [],
    );

    expect(outcome.feasible, isTrue);
    final mon = outcome.blocks.firstWhere((b) => b.id == 'mon');
    expect(
      mon.startUtc.isBefore(at(15)),
      isTrue,
      reason: '后续日期的固定日程只占位，不该让当天方案失败',
    );
  });

  test('**跨午夜的保护时间只占位，不让当天方案失败**', () {
    // 保护时间：周一本地 23:00 → 周二 01:00（`at(14)`→`at(16)`），**跨午夜**。
    // 它占用周一末尾，但周一 09:30 起仍有大段空间 ⇒ 当天方案必须成立。
    final outcome = repairBestPlanDayScoped(
      targetBlockId: 'mon',
      notBeforeUtc: at(0).add(const Duration(minutes: 30)),
      blocks: [block('mon', at(0))],
      immovable: [block('protected:night', at(14), minutes: 120)],
      targetStartUtc: at(0),
      timeZoneId: zoneId,
      zones: zones,
      planningEndUtc: at(24 * 7),
      tasks: const [],
    );

    expect(outcome.feasible, isTrue);
    final mon = outcome.blocks.firstWhere((b) => b.id == 'mon');
    expect(
      mon.startUtc.isBefore(at(15)),
      isTrue,
      reason: '跨午夜的保护时间只占位，不该让当天方案失败',
    );
  });

  test('当天确实放不下时仍然往后找（多日输入下也一样）', () {
    // 下界 = 周一本地次日 00:30（`at(14)` + 90 分钟）⇒ 周一放不下 ⇒ 必须跨天。
    final outcome = repairBestPlanDayScoped(
      targetBlockId: 'mon',
      notBeforeUtc: at(14).add(const Duration(minutes: 90)),
      blocks: [block('mon', at(0))],
      immovable: const [],
      targetStartUtc: at(0),
      timeZoneId: zoneId,
      zones: zones,
      planningEndUtc: at(24 * 7),
      tasks: const [],
    );

    expect(outcome.feasible, isTrue, reason: '当天放不下要往后找，不能判不可行');
    final mon = outcome.blocks.firstWhere((b) => b.id == 'mon');
    expect(
      mon.startUtc.isBefore(at(15)),
      isFalse,
      reason: '下界已落在次日 ⇒ 落点必须在之后的本地日',
    );
  });

  test('**当天方案里不含后续日期的块**（它们保持原位、由引擎照常处理）', () {
    final outcome = repairBestPlanDayScoped(
      targetBlockId: 'mon',
      notBeforeUtc: at(0).add(const Duration(minutes: 30)),
      blocks: [block('mon', at(0)), block('tue', at(24))],
      immovable: const [],
      targetStartUtc: at(0),
      timeZoneId: zoneId,
      zones: zones,
      planningEndUtc: at(24 * 7),
      tasks: const [],
    );

    expect(outcome.feasible, isTrue);
    expect(
      outcome.blocks.map((b) => b.id).toSet(),
      {'mon'},
      reason:
          '当天尝试只处理目标当天的可移动块；'
          '周二那块不参与当天候选（它保持原位，引擎按既有路径处理）',
    );
  });
}
