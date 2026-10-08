import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';

void main() {
  // 用户实测修复（1.7.1，计划 §2.4 / Task 2）：
  //
  // **这条用例的期望被刻意改过一次，理由是行为契约变了。**
  //
  // 修复前 `AvailabilityBuilder.build()` 把"每日可移动任务上限"当成"最多保留多少分钟空闲
  // 候选"，从清晨开始依次消费：一天上限 360 分钟时，前 360 分钟空闲被保留，**后面的空闲
  // 区间直接不进入候选集**（旧断言就是"合计恰好 360，最后一段结束于 17:30"）。
  //
  // 这不是该规则的真实含义。每日上限应限制**最终选中的可移动任务总时长**，
  // 而不是只允许算法看见一天中最早的那些空档（计划 §2.4：它使候选可见性依赖空档顺序，
  // 并让用户看到的空闲与引擎实际能选择的空闲不一致）。上限的最终防线在 `PlanValidator`，
  // 生成过程中的检查由 `ScheduleEngine` 承担（Task 2 Step 4）。
  //
  // 因此现在断言：**全天真实空闲都可见**，且仍然正确扣除睡眠、固定、保护与锁定。
  test('扣除睡眠、午餐、课程和锁定块后返回全天真实空闲（不再按上限截断候选）', () {
    final zones = TimeZoneDatabase();
    const zoneId = 'Asia/Shanghai';
    final localDate = DateTime(2026, 10, 2);
    DateTime at(int hour, [int minute = 0]) =>
        zones.localDateTimeToUtc(localDate, hour * 60 + minute, zoneId);

    final fixed = [TimeRange(startUtc: at(9), endUtc: at(11))];
    final protected = [TimeRange(startUtc: at(12), endUtc: at(13))];
    final locked = [TimeRange(startUtc: at(15), endUtc: at(16))];
    final slots = AvailabilityBuilder(zones).build(
      AvailabilityInput(
        planningWindow: TimeRange(
          startUtc: zones.localMidnightToUtc(localDate, zoneId),
          endUtc: zones.localMidnightToUtc(
            localDate.add(const Duration(days: 1)),
            zoneId,
          ),
        ),
        timeZoneId: zoneId,
        rules: DefaultSettings.v1(),
        fixedIntervals: fixed,
        protectedIntervals: protected,
        lockedBlocks: locked,
      ),
    );

    // 全天 24 小时扣掉睡眠 7.5 小时、课程 2 小时、午餐 1 小时、锁定 1 小时 = 12.5 小时。
    // 全天 24 小时扣掉睡眠 8 小时（默认 23:30–07:30）、课程 2 小时、午餐 1 小时、
    // 锁定 1 小时 = 12 小时 = 720 分钟。
    //
    // **这是实测值，不是推算值**：四段空闲依次是 90 / 60 / 120 / 450 分钟。
    // 最后一段从 16:00 一直连到 23:30——我第一版把下午和晚间当成两段，算错了。
    expect(
      slots.fold<int>(0, (sum, slot) => sum + slot.durationMinutes),
      720,
      reason: '候选必须覆盖全天真实空闲，不能只留时间最早的 360 分钟',
    );
    expect(slots.first.startUtc, at(7, 30));
    expect(slots.last.endUtc, at(23, 30), reason: '旧行为在这一天 17:30 就把候选截断了');

    final allBusy = [...fixed, ...protected, ...locked];
    for (var index = 0; index < slots.length; index++) {
      expect(allBusy.any((busy) => slots[index].range.overlaps(busy)), isFalse);
      if (index > 0) {
        expect(slots[index - 1].range.overlaps(slots[index].range), isFalse);
      }
    }
  });

  // 计划 §2.4 / Task 2 Step 1 的专门用例：一天上限 360 分钟，但有早、中、晚三个分离空档，
  // 合计超过 360 分钟。三段**都必须**返回——上限不再决定"哪一段可见"。
  test('早中晚三个分离空档都进入候选，不按上限只留时间最早的那些', () {
    final zones = TimeZoneDatabase();
    const zoneId = 'Asia/Shanghai';
    final localDate = DateTime(2026, 10, 3);
    DateTime at(int hour, [int minute = 0]) =>
        zones.localDateTimeToUtc(localDate, hour * 60 + minute, zoneId);

    // 睡眠 00:00–06:00，留出 06:00 起的可用时间。
    final rules = DefaultSettings.v1().copyWith(
      sleepRange: LocalTimeRange(startMinute: 0, endMinute: 6 * 60),
      dailyMovableTaskLimitMinutes: 360,
    );

    // 三个分离空档，各 180 分钟，合计 540 > 360。
    // 上午 06:00–09:00、下午 12:00–15:00、晚间 18:00–21:00；其余时间忙碌。
    final busy = <TimeRange>[
      TimeRange(startUtc: at(9), endUtc: at(12)),
      TimeRange(startUtc: at(15), endUtc: at(18)),
      TimeRange(startUtc: at(21), endUtc: at(23, 30)),
    ];

    final slots = AvailabilityBuilder(zones).build(
      AvailabilityInput(
        planningWindow: TimeRange(
          startUtc: zones.localMidnightToUtc(localDate, zoneId),
          endUtc: zones.localMidnightToUtc(
            localDate.add(const Duration(days: 1)),
            zoneId,
          ),
        ),
        timeZoneId: zoneId,
        rules: rules,
        fixedIntervals: busy,
      ),
    );

    expect(
      slots.fold<int>(0, (sum, slot) => sum + slot.durationMinutes),
      570,
      reason:
          '三个各 180 分钟的空档，另加 23:30–00:00 的 30 分钟'
          '（睡眠 23:30 才开始，因此那半小时同样是真实空闲）；上限 360 不参与候选可见性',
    );
    expect(slots.map((slot) => slot.range).toList(), [
      TimeRange(startUtc: at(6), endUtc: at(9)),
      TimeRange(startUtc: at(12), endUtc: at(15)),
      TimeRange(startUtc: at(18), endUtc: at(21)),
      // 21:00–23:30 被"21:00–23:30 忙碌"占掉，因此剩下的是 23:30 到午夜这半小时。
      // 半夜不能用 `at(24)` 表达：`minuteOfDay` 必须小于 1440，直接给次日零点。
      TimeRange(
        startUtc: at(23, 30),
        endUtc: zones.localMidnightToUtc(
          localDate.add(const Duration(days: 1)),
          zoneId,
        ),
      ),
    ], reason: '晚间空档属于真实空闲，必须保留（旧行为会在消费满 360 分钟后丢弃它）');
  });

  test('合并重叠忙碌区间并保持半开边界可相邻', () {
    final zones = TimeZoneDatabase();
    final window = TimeRange(
      startUtc: DateTime.utc(2026, 10, 2, 8),
      endUtc: DateTime.utc(2026, 10, 2, 12),
    );
    final rules = DefaultSettings.v1().copyWith(
      sleepRange: LocalTimeRange(startMinute: 12 * 60, endMinute: 8 * 60),
      dailyMovableTaskLimitMinutes: 240,
    );

    final slots = AvailabilityBuilder(zones).build(
      AvailabilityInput(
        planningWindow: window,
        timeZoneId: 'UTC',
        rules: rules,
        fixedIntervals: [
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 2, 9),
            endUtc: DateTime.utc(2026, 10, 2, 10),
          ),
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 2, 9, 30),
            endUtc: DateTime.utc(2026, 10, 2, 11),
          ),
        ],
      ),
    );

    expect(slots.map((slot) => slot.range).toList(), [
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 2, 8),
        endUtc: DateTime.utc(2026, 10, 2, 9),
      ),
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 2, 11),
        endUtc: DateTime.utc(2026, 10, 2, 12),
      ),
    ]);
  });
}
