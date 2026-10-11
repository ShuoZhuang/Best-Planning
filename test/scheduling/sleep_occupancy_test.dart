// 1.8.0（用户第 65 轮复核第 3 条的最后一类）：**睡眠必须是硬占用区间**。
//
// 复核列出的硬占用应当是"固定日程（含课程缓冲）＋ 规则保护时间 ＋ 自定义保护时间 ＋
// **睡眠** ＋ 锁定块 ＋ 已经过去的块"。前几类已在 `defer_hard_occupancy_test.dart`
// 覆盖，睡眠此前只有 `AvailabilityBuilder._sleepIntervals` 在算 ——
// 它**没有**进入 `ScheduleProblem.protectedIntervals`，因此：
//
//   · 引擎的 `PlanValidator` 不会把"块压在睡眠上"报成冲突；
//   · 可用容量（`_capacityFor`）走的是 `AvailabilityBuilder`，那里**有**睡眠 ——
//     于是"容量认为睡眠不可用、校验却认为压上去没关系"，两处口径不一致；
//   · 调整路径的硬障碍集合里也没有睡眠。
//
// 本文件钉住统一之后的契约：**睡眠与前几类走同一份展开结果**。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/protected_time_expander.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  // 东八区 2026-10-12（周一）00:00 = 前一天 16:00Z
  final localMidnightUtc = DateTime.utc(2026, 10, 11, 16);
  DateTime at(int hour) => localMidnightUtc.add(Duration(hours: hour));

  PlanningRules rulesWithSleep(LocalTimeRange sleep) =>
      DefaultSettings.v1().copyWith(sleepRange: sleep);

  test('**睡眠被展开成真实区间**（跨午夜 22:00–06:00）', () {
    final intervals = ProtectedTimeExpander(TimeZoneDatabase()).sleep(
      rules: rulesWithSleep(
        LocalTimeRange(startMinute: 22 * 60, endMinute: 6 * 60),
      ),
      startUtc: at(0),
      endUtc: at(48),
      timeZoneId: zoneId,
    );

    expect(intervals, isNotEmpty, reason: '睡眠必须展开出区间');
    for (final interval in intervals) {
      expect(
        interval.range.durationMinutes,
        greaterThan(0),
        reason: '展开出的区间必须有正长度',
      );
    }
    // 跨午夜的睡眠 22:00–06:00 应当展开成 **8 小时一整段**。
    //
    // **首尾会被窗口裁掉**：`sleep` 向前后各多覆盖一天（否则窗口起点落在本地 00:00 时
    // 会漏掉"前一夜"的尾巴），因此第一段从窗口起点开始、最后一段在窗口终点截断。
    // 用 `sublist(1, length - 1)` 只看**完全落在窗口内**的那些段。
    //
    // 实测（这些数字来自打印，不是我算的）：
    //   `16:00Z→22:00Z (360m)`（被裁）/ `14:00Z→22:00Z (480m)` / `14:00Z→16:00Z (120m)`（被裁）
    expect(intervals, hasLength(3), reason: '前后各一天被裁 + 中间一整段');
    expect(
      intervals[1].range.durationMinutes,
      8 * 60,
      reason:
          '跨午夜睡眠必须合并成**一整段 8 小时**。'
          '`splitAtMidnight` 会把它拆成 6h+2h 两段，'
          '若没有合并，这里会看到 360 而不是 480',
    );
  });

  test('睡眠区间覆盖窗口前一天的尾巴（窗口从本地 00:00 开始时也要挡住当天凌晨）', () {
    // 睡眠 22:00–06:00、窗口正好从本地 00:00 起：
    // 当天 00:00–06:00 属于**前一夜**的睡眠，必须被挡住。
    final intervals = ProtectedTimeExpander(TimeZoneDatabase()).sleep(
      rules: rulesWithSleep(
        LocalTimeRange(startMinute: 22 * 60, endMinute: 6 * 60),
      ),
      startUtc: at(0),
      endUtc: at(12),
      timeZoneId: zoneId,
    );

    expect(
      intervals.any(
        (i) =>
            !i.range.startUtc.isAfter(at(0)) && i.range.endUtc.isAfter(at(0)),
      ),
      isTrue,
      reason:
          '本地 00:00–06:00 必须被睡眠覆盖。'
          '若只从窗口当天开始展开，这段会被漏掉',
    );
  });

  test('**可用容量与硬占用口径一致**：睡眠时段不再被算作可用时间', () {
    // 窗口一天（本地 00:00 → 次日 00:00），睡眠 00:00–06:00。
    // 可用时间因此**不含**那 6 小时。
    final rules = rulesWithSleep(
      LocalTimeRange(startMinute: 0, endMinute: 6 * 60),
    );
    final slots = AvailabilityBuilder(zones).build(
      AvailabilityInput(
        planningWindow: TimeRange(startUtc: at(0), endUtc: at(24)),
        timeZoneId: zoneId,
        rules: rules,
      ),
    );

    final totalMinutes = slots.fold<int>(
      0,
      (sum, slot) => sum + slot.durationMinutes,
    );
    expect(
      totalMinutes,
      lessThanOrEqualTo(24 * 60 - 6 * 60),
      reason: '睡 6 小时 ⇒ 当天可用不超过 18 小时',
    );
    for (final slot in slots) {
      expect(
        slot.range.startUtc.isBefore(at(6)),
        isFalse,
        reason: '本地 06:00 之前的时段不得出现在可用里（睡眠）',
      );
    }
  });
}
