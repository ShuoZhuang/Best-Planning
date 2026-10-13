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

  // ── 详细分析（1.8.0 专项 §2.3 / Task 4 Step 1）──────────────────────────────
  //
  // `analyze()` 是 `build()` 的详细形式：同一批空闲，加上**带来源标签**的占用分段与
  // 空闲分钟总数。三条纪律在这里逐条钉住：
  // 1. `build(input)` 必须**逐值等于** `analyze(input).slots`（旧行为不得漂移）；
  // 2. `calendarGapMinutes == sum(slots.durationMinutes)`（两个数字不能是两件事）；
  // 3. 同一分钟只扣一次，而一个区间可以同时带多个 blocker kind。
  test('build(input) 与 analyze(input).slots 逐值一致', () {
    final zones = TimeZoneDatabase();
    const zoneId = 'Asia/Shanghai';
    final localDate = DateTime(2026, 10, 2);
    DateTime at(int hour, [int minute = 0]) =>
        zones.localDateTimeToUtc(localDate, hour * 60 + minute, zoneId);

    final input = AvailabilityInput(
      planningWindow: TimeRange(
        startUtc: zones.localMidnightToUtc(localDate, zoneId),
        endUtc: zones.localMidnightToUtc(
          localDate.add(const Duration(days: 1)),
          zoneId,
        ),
      ),
      timeZoneId: zoneId,
      rules: DefaultSettings.v1(),
      fixedIntervals: [TimeRange(startUtc: at(9), endUtc: at(11))],
      protectedIntervals: [TimeRange(startUtc: at(12), endUtc: at(13))],
      lockedBlocks: [TimeRange(startUtc: at(15), endUtc: at(16))],
      chargedMovableBlocks: [TimeRange(startUtc: at(20), endUtc: at(21))],
    );

    final builder = AvailabilityBuilder(zones);
    expect(builder.analyze(input).slots, builder.build(input));
  });

  test('calendarGapMinutes 恒等于 slots 的分钟之和', () {
    final zones = TimeZoneDatabase();
    final window = TimeRange(
      startUtc: DateTime.utc(2026, 10, 2, 8),
      endUtc: DateTime.utc(2026, 10, 2, 18),
    );
    final analysis = AvailabilityBuilder(zones).analyze(
      AvailabilityInput(
        planningWindow: window,
        timeZoneId: 'UTC',
        rules: DefaultSettings.v1().copyWith(
          sleepRange: LocalTimeRange(startMinute: 0, endMinute: 60),
          breakMinutes: 10,
        ),
        fixedIntervals: [
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 2, 9),
            endUtc: DateTime.utc(2026, 10, 2, 10),
          ),
        ],
      ),
    );

    expect(
      analysis.calendarGapMinutes,
      analysis.slots.fold<int>(0, (sum, slot) => sum + slot.durationMinutes),
      reason: '"空闲"不能是两个数字：两个来源迟早会对不上',
    );
    expect(analysis.calendarGapMinutes, greaterThan(0));
  });

  test('**固定日程与保护时间重叠 30 分钟，总容量只扣一次，且两个标签都在**', () {
    final zones = TimeZoneDatabase();
    final window = TimeRange(
      startUtc: DateTime.utc(2026, 10, 2, 8),
      endUtc: DateTime.utc(2026, 10, 2, 12),
    );
    final analysis = AvailabilityBuilder(zones).analyze(
      AvailabilityInput(
        planningWindow: window,
        timeZoneId: 'UTC',
        rules: DefaultSettings.v1().copyWith(
          sleepRange: LocalTimeRange(startMinute: 0, endMinute: 60),
        ),
        // 固定 09:00–10:30、保护 10:00–10:30 ⇒ 重叠 30 分钟。
        fixedIntervals: [
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 2, 9),
            endUtc: DateTime.utc(2026, 10, 2, 10, 30),
          ),
        ],
        protectedIntervals: [
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 2, 10),
            endUtc: DateTime.utc(2026, 10, 2, 10, 30),
          ),
        ],
      ),
    );

    // 08:00–12:00 共 240 分钟，被占用的是 09:00–10:30（90 分钟，只扣一次）⇒ 空闲 150。
    expect(
      analysis.calendarGapMinutes,
      150,
      reason: '重叠的 30 分钟只能扣一次（扣两次会得到 120）',
    );
    final overlap = analysis.blockedSegments.singleWhere(
      (segment) =>
          segment.range ==
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 2, 10),
            endUtc: DateTime.utc(2026, 10, 2, 10, 30),
          ),
    );
    expect(overlap.kinds, {
      AvailabilityBlockerKind.fixed,
      AvailabilityBlockerKind.protected,
    }, reason: '同一段分钟可以同时被固定日程与保护时间覆盖，两个来源都必须报出来');
    expect(analysis.blockedSegments.map((s) => s.range).toList(), [
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 2, 9),
        endUtc: DateTime.utc(2026, 10, 2, 10),
      ),
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 2, 10),
        endUtc: DateTime.utc(2026, 10, 2, 10, 30),
      ),
    ], reason: '重叠段被切开：09:00–10:00 只有 fixed，10:00–10:30 两个都有');
  });

  test('睡眠与 locked 也带标签，跨午夜时按本地日展开', () {
    final zones = TimeZoneDatabase();
    final window = TimeRange(
      startUtc: DateTime.utc(2026, 10, 2, 20),
      endUtc: DateTime.utc(2026, 10, 3, 10),
    );
    final analysis = AvailabilityBuilder(zones).analyze(
      AvailabilityInput(
        planningWindow: window,
        timeZoneId: 'UTC',
        rules: DefaultSettings.v1().copyWith(
          sleepRange: LocalTimeRange(startMinute: 22 * 60, endMinute: 6 * 60),
        ),
        lockedBlocks: [
          TimeRange(
            startUtc: DateTime.utc(2026, 10, 2, 20, 30),
            endUtc: DateTime.utc(2026, 10, 2, 21, 30),
          ),
        ],
      ),
    );

    final sleepSegments = analysis.blockedSegments
        .where(
          (segment) => segment.kinds.contains(AvailabilityBlockerKind.sleep),
        )
        .toList();
    expect(sleepSegments, hasLength(1));
    expect(
      sleepSegments.single.range,
      TimeRange(
        startUtc: DateTime.utc(2026, 10, 2, 22),
        endUtc: DateTime.utc(2026, 10, 3, 6),
      ),
      reason:
          '22:00–06:00 跨午夜：`ProtectedTimeExpander.sleep` 按本地日展开成两段，'
          '分析层再按"标签相同且相邻即合并"合回一段。**总分钟数因此仍然是 480**——'
          '展开与合并都只改变形状，不改变"扣多少"。窗口起点在 10-02 20:00，'
          '因此这段完全落在窗口内。',
    );
    expect(sleepSegments.single.durationMinutes, 480);
    expect(
      analysis.blockedSegments.any(
        (segment) =>
            segment.kinds.contains(AvailabilityBlockerKind.locked) &&
            segment.range.durationMinutes == 60,
      ),
      isTrue,
      reason: '锁定块也必须是带标签的占用（它扣容量，但不是"不许安排"）',
    );
    expect(
      analysis.calendarGapMinutes,
      analysis.slots.fold<int>(0, (sum, slot) => sum + slot.durationMinutes),
    );
  });
}
