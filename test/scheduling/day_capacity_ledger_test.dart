// 逐日容量账本（算法 17，计划 `2026-10-16-capacity-aware-hierarchical-scheduler-repair.md`
// Task 3 Step 1/2/3）。
//
// ## 这一组用例要钉住的四件事
//
// 1. **容量并集**：固定日程与保护时间重叠 30 分钟只扣一次。
// 2. **两层空闲**：`hardFreeMinutes`（只扣非任务硬占用）与 `calendarGapMinutes`
//    （再扣基线任务块）必须分开——修复前只有一个数字，于是"日历上明明空着"与
//    "引擎说容量不足"无法区分。
// 3. **零容量边界**：许可容量为 0 时**不除零**，负载率记 0 或 1001。
// 4. **allocate / release 守恒**：分配精确减少、释放逐值恢复、越界抛错、原账本不变。
//
// 还有一条来自计划 Task 3 Step 1 的**关键夹具**：
// 「硬空闲 240、锁定任务 60、每日上限 180」必须得到
// `hardFree=240`、`calendarGap=180`、`licensed=180`、`used=60`、`remaining=120`，
// **不得得到 60**。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/availability_builder.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/day_capacity_ledger.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

const String _zoneId = 'Asia/Shanghai';

final TimeZoneDatabase _zones = TimeZoneDatabase();

DateTime _midnight(int day) =>
    _zones.localMidnightToUtc(DateTime(2026, 10, day), _zoneId);

DateTime _at(int day, int minuteOfDay) =>
    _zones.localDateTimeToUtc(DateTime(2026, 10, day), minuteOfDay, _zoneId);

/// 一天的窗口（本地 00:00 → 次日 00:00）。
TimeRange _dayWindow(int day) =>
    TimeRange(startUtc: _midnight(day), endUtc: _midnight(day + 1));

/// 建立"问题 + 分析 + 账本"三件套。
///
/// **三者必须一起给**：账本的全部输入就是 `AvailabilityAnalysis` 与基线块，
/// 因此任何一条用例都不可能只改其中一项而让账本悄悄用另一份口径。
({
  ScheduleProblem problem,
  AvailabilityAnalysis availability,
  DayCapacityLedger ledger,
})
_build({
  required TimeRange window,
  required PlanningRules rules,
  List<TimeRange> fixed = const [],
  List<TimeRange> protected = const [],
  List<PlannedBlock> locked = const [],
  List<PlannedBlock> pinnedUnlocked = const [],
  PlanningRules? weekendRules,
}) {
  final policies = <DateTime, DailySchedulingPolicy>{};
  for (final date in enumerateLocalDates(
    zones: _zones,
    window: window,
    timeZoneId: _zoneId,
  )) {
    final isWeekend =
        date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
    policies[date] = DailySchedulingPolicy(
      localDate: date,
      resolvedRules: isWeekend && weekendRules != null ? weekendRules : rules,
      softReserveTargetMinutes: 0,
    );
  }
  final problem = ScheduleProblem(
    planningWindow: window,
    timeZoneId: _zoneId,
    tasks: const [
      SchedulableTask(
        id: 't-a',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 60,
      ),
    ],
    fixedIntervals: const [],
    protectedIntervals: const [],
    lockedBlocks: locked,
    rules: rules,
    dailyPolicies: policies,
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: _zoneId,
    ),
    pinnedUnlockedBlockIds: {for (final block in pinnedUnlocked) block.id},
    preferences: const PreferenceProfile(),
    inputHash: 'day-capacity-ledger',
  );
  final availability = AvailabilityBuilder(_zones).analyze(
    AvailabilityInput(
      planningWindow: window,
      timeZoneId: _zoneId,
      rules: rules,
      dailyPolicies: problem.dailyPolicies,
      fixedIntervals: fixed,
      protectedIntervals: protected,
      lockedBlocks: [for (final block in locked) block.range],
      chargedMovableBlocks: [
        for (final block in [...locked, ...pinnedUnlocked]) block.range,
      ],
    ),
  );
  return (
    problem: problem,
    availability: availability,
    ledger: buildDayCapacityLedger(
      problem: problem,
      availability: availability,
      baselineBlocks: [...locked, ...pinnedUnlocked],
      zones: _zones,
    ),
  );
}

/// 每天的规则都相同、且上限为一天（等于"这条规则不生效"），
/// 这样容量形状只由夹具给出的区间决定。
///
/// ## 睡眠必须离夹具的空档远一点
///
/// `LocalTimeRange` 拒绝零长度区间，而**睡眠只要不是零长度就一定会扣掉容量**。
/// 因此这里把睡眠放在本地 03:00–03:05（窗口内、但没有任何用例的空档在那里）。
/// 若放在 00:00 起，"一天 1440 分钟"的算术会全部少 5 分钟——第一版夹具就这么错过，
/// 五条用例同时报 `Expected: <1350> Actual: <1345>`。
///
/// **这也是一条真实约束**：睡眠永远会缩短可用容量，"全天可用"在睡眠非零时不成立。
PlanningRules _rules({int dailyLimit = 1440, int breakMinutes = 0}) =>
    DefaultSettings.v1().copyWith(
      energyWindows: const [],
      protectedTimes: const [],
      sleepRange: LocalTimeRange(startMinute: 3 * 60, endMinute: 3 * 60 + 5),
      minimumSleepMinutes: 5,
      breakMinutes: breakMinutes,
      dailyMovableTaskLimitMinutes: dailyLimit,
      granularityMinutes: 5,
    );

/// 手工构造一个快照，用于测试**无法由真实排程输入构造**的边界。
DayCapacitySnapshot _snapshot({
  required DateTime date,
  int licensedCapacityMinutes = 0,
  int usedMovableMinutes = 0,
}) {
  final numerator = usedMovableMinutes;
  final utilization = licensedCapacityMinutes <= 0
      ? (numerator <= 0 ? 0 : 1001)
      : ((numerator * 1000 + licensedCapacityMinutes - 1) ~/
            licensedCapacityMinutes);
  return DayCapacitySnapshot(
    localDate: date,
    hardFreeMinutes: licensedCapacityMinutes,
    calendarGapMinutes: licensedCapacityMinutes,
    licensedCapacityMinutes: licensedCapacityMinutes,
    usedMovableMinutes: usedMovableMinutes,
    allocatedMinutes: 0,
    remainingMinutes: 0,
    utilizationPermille: utilization,
    overLicensedMinutes: usedMovableMinutes > licensedCapacityMinutes
        ? usedMovableMinutes - licensedCapacityMinutes
        : 0,
  );
}

void main() {
  group('两层空闲与容量并集（Task 3 Step 1）', () {
    test('**固定日程与保护时间重叠 30 分钟只扣一次**', () {
      final window = _dayWindow(5);
      final result = _build(
        window: window,
        rules: _rules(),
        // 固定 09:00–10:30、保护 10:00–10:30 ⇒ 重叠 30 分钟。
        fixed: [
          TimeRange(startUtc: _at(5, 9 * 60), endUtc: _at(5, 10 * 60 + 30)),
        ],
        protected: [
          TimeRange(startUtc: _at(5, 10 * 60), endUtc: _at(5, 10 * 60 + 30)),
        ],
      );

      final snapshot = result.ledger.forDate(DateTime(2026, 10, 5));
      // 一天 1440 分钟，扣掉占用的 90 分钟（只扣一次）与**睡眠 5 分钟** ⇒ 1345。
      // （睡眠 03:00–03:05 落在窗口内，因此它一定参与扣除——见 `_rules` 的说明。）
      expect(snapshot.calendarGapMinutes, 1345, reason: '重叠的 30 分钟扣两次会得到 1315');
      expect(snapshot.hardFreeMinutes, 1345, reason: '没有任务块 ⇒ 两层空闲相同');
    });

    test('**硬空闲 240、锁定任务 60、每日上限 180 的关键夹具**', () {
      final window = _dayWindow(5);
      // 只留 10:00–14:00（240 分钟）空闲：其余时间被固定日程占住。
      final fixed = [
        TimeRange(startUtc: _midnight(5), endUtc: _at(5, 10 * 60)),
        TimeRange(startUtc: _at(5, 14 * 60), endUtc: _midnight(6)),
      ];
      final locked = [
        PlannedBlock(
          id: 'locked-1',
          taskId: 't-a',
          range: TimeRange(startUtc: _at(5, 11 * 60), endUtc: _at(5, 12 * 60)),
          locked: true,
        ),
      ];
      final result = _build(
        window: window,
        rules: _rules(dailyLimit: 180),
        fixed: fixed,
        locked: locked,
      );

      final snapshot = result.ledger.forDate(DateTime(2026, 10, 5));
      // 睡眠在 03:00–03:05，而那个时段被固定日程占着，因此它**不额外**缩小硬空闲：
      // 日硬空闲 = 10:00–14:00 的 240 分钟。
      expect(snapshot.hardFreeMinutes, 240, reason: '日硬空闲不扣任务块');
      expect(snapshot.calendarGapMinutes, 180, reason: '视觉空白再扣掉锁定块的 60 分钟');
      expect(
        snapshot.licensedCapacityMinutes,
        180,
        reason: 'min(硬空闲 240, 上限 180)',
      );
      expect(snapshot.usedMovableMinutes, 60, reason: '锁定块计入已用量');
      expect(
        snapshot.remainingMinutes,
        120,
        reason:
            'min(max(0, 视觉空白 180 − 已分配 0), max(0, 许可 180 − 已用 60 − 已分配 0)) = 120；'
            '若得到 60 或 0，说明账本把"已用"与"空白"混在了一起',
      );
    });

    test('跨午夜的基线块**按本地日切开**，与视觉空白同一口径', () {
      // 窗口覆盖 10-05 与 10-06 两天。
      final window = TimeRange(startUtc: _midnight(5), endUtc: _midnight(7));
      final locked = [
        PlannedBlock(
          id: 'cross-midnight',
          taskId: 't-a',
          range: TimeRange(startUtc: _at(5, 23 * 60), endUtc: _at(6, 60)),
          locked: true,
        ),
      ];
      final result = _build(window: window, rules: _rules(), locked: locked);

      final first = result.ledger.forDate(DateTime(2026, 10, 5));
      final second = result.ledger.forDate(DateTime(2026, 10, 6));
      expect(first.usedMovableMinutes, 60, reason: '10-05 只承担 23:00–24:00 那一半');
      expect(second.usedMovableMinutes, 60, reason: '10-06 承担 00:00–01:00 那一半');
      expect(
        first.calendarGapMinutes,
        1375,
        reason: '10-05 = 1440 − 睡眠 5 − 那一半 60',
      );
      expect(
        second.calendarGapMinutes,
        1375,
        reason: '10-06 = 1440 − 睡眠 5 − 那一半 60',
      );
      expect(
        first.calendarGapMinutes + first.usedMovableMinutes,
        1435,
        reason:
            '同一天的"视觉空白 + 已用量"必须等于"日硬空闲"（1435 = 1440 − 睡眠 5）。'
            '若已用量按起点整块记到 10-05，这个等式会差 60 分钟',
      );
    });

    test('**整天被占住 ⇒ 许可容量 0，负载率 0，且账本仍记录这一天**', () {
      final window = _dayWindow(5);
      // 整天被占住 ⇒ 硬空闲 0 ⇒ `min(0, 上限) = 0`。
      // 这一天**一个空闲切片都没有**，因此账本必须从窗口日期集合覆盖它，
      // 否则 `forDate` 会抛"缺日"，而"完全没有容量"恰恰是最该被记录的形状。
      final result = _build(
        window: window,
        rules: _rules(),
        fixed: [TimeRange(startUtc: _midnight(5), endUtc: _midnight(6))],
      );

      final snapshot = result.ledger.forDate(DateTime(2026, 10, 5));
      expect(snapshot.hardFreeMinutes, 0);
      expect(snapshot.licensedCapacityMinutes, 0);
      expect(snapshot.usedMovableMinutes, 0);
      expect(
        snapshot.utilizationPermille,
        0,
        reason: '许可容量为 0 且分子为 0 ⇒ 记 0（不是 NaN、不是除零崩溃）',
      );
      expect(snapshot.remainingMinutes, 0);
      expect(snapshot.canAllocate, isFalse);
    });

    test('**许可容量为 0 而分子大于 0 ⇒ 负载率 1001，不除零**', () {
      // 这条边界**不能由真实排程输入构造**（要它成立需要"许可容量 0 却有正占用"，
      // 而 `PlanningRules` 拒绝为 0 的每日上限、睡眠又至少占 1 分钟，
      // 于是 `licensed == 0` 时通常也没有占用）。因此直接钉住负载率函数
      // 在分母为 0 时的两个分支——"0/0 记 0"与"正数/0 记 1001"。
      final zero = DayCapacityLedger.fromSnapshots([
        _snapshot(date: DateTime(2026, 10, 5)),
      ]).forDate(DateTime(2026, 10, 5));
      expect(zero.utilizationPermille, 0, reason: '0/0 记 0');

      final anomaly = DayCapacityLedger.fromSnapshots([
        _snapshot(date: DateTime(2026, 10, 5), usedMovableMinutes: 60),
      ]).forDate(DateTime(2026, 10, 5));
      expect(
        anomaly.utilizationPermille,
        1001,
        reason: '没有容量却有占用 ⇒ 结构异常（不是除零崩溃、也不是 0）',
      );
      expect(anomaly.hasBaselineOverflow, isTrue);
      expect(anomaly.remainingMinutes, 0, reason: '超额许可时剩余量是 0，不是负数');
    });

    test('**基线已用超过许可容量 ⇒ 留下结构异常证据，不夹成 0**', () {
      final window = _dayWindow(5);
      // 每日上限 60 分钟，而基线里有一个 180 分钟的锁定块：
      // 计划**本身**就已经超出上限，这必须被报出来，而不是夹成 0 后声称输入正常。
      // 固定日程只占 00:00–10:00，因此 10:00 之后仍是真实空闲，
      // **账本不需要靠睡眠去找那 5 分钟**（睡眠落在 03:00–03:05，被固定日程吞掉）。
      final result = _build(
        window: window,
        rules: _rules(dailyLimit: 60),
        fixed: [TimeRange(startUtc: _midnight(5), endUtc: _at(5, 10 * 60))],
        locked: [
          PlannedBlock(
            id: 'locked-1',
            taskId: 't-a',
            range: TimeRange(
              startUtc: _at(5, 10 * 60),
              endUtc: _at(5, 13 * 60),
            ),
            locked: true,
          ),
        ],
      );

      final snapshot = result.ledger.forDate(DateTime(2026, 10, 5));
      expect(snapshot.hardFreeMinutes, 840, reason: '10:00–24:00 共 840 分钟');
      expect(
        snapshot.licensedCapacityMinutes,
        60,
        reason: 'min(硬空闲 840, 上限 60)',
      );
      expect(snapshot.usedMovableMinutes, 180, reason: '锁定块全额计入已用量');
      expect(
        snapshot.overLicensedMinutes,
        120,
        reason: '已用 180 − 许可 60 = 120；**不得夹成 0 后声称输入正常**',
      );
      expect(snapshot.hasBaselineOverflow, isTrue);
      expect(snapshot.remainingMinutes, 0, reason: '超额时剩余量是 0，不是负数');
      expect(
        result.ledger.anomalies,
        isNotEmpty,
        reason: '"基线已用超过许可容量"必须留下结构化证据',
      );
      expect(
        () => result.ledger.allocate(DateTime(2026, 10, 5), 5),
        throwsA(isA<StateError>()),
        reason: '许可容量已经用尽（且超额）⇒ 一分钟都不能再分配',
      );
    });

    test('工作日与周末各自使用自己的每日上限', () {
      // 窗口 10-09（周五）→ 10-11（周日）：既有工作日也有周末。
      final window = TimeRange(startUtc: _midnight(9), endUtc: _midnight(12));
      final result = _build(
        window: window,
        rules: _rules(dailyLimit: 180),
        weekendRules: _rules(dailyLimit: 360),
      );

      expect(
        result.ledger.forDate(DateTime(2026, 10, 9)).licensedCapacityMinutes,
        180,
        reason: '周五用工作日的上限',
      );
      expect(
        result.ledger.forDate(DateTime(2026, 10, 10)).licensedCapacityMinutes,
        360,
        reason: '周六用自己的上限，而不是复制窗口首日',
      );
      expect(
        result.ledger.forDate(DateTime(2026, 10, 11)).licensedCapacityMinutes,
        360,
      );
    });
  });

  group('allocate / release 守恒（Task 3 Step 2）', () {
    test('分配后 remaining 精确减少，且原账本逐值不变', () {
      final window = _dayWindow(5);
      final result = _build(
        window: window,
        rules: _rules(dailyLimit: 600),
        fixed: [
          TimeRange(startUtc: _midnight(5), endUtc: _at(5, 10 * 60)),
          TimeRange(startUtc: _at(5, 14 * 60), endUtc: _midnight(6)),
        ],
      );
      final date = DateTime(2026, 10, 5);
      final before = result.ledger.forDate(date);
      expect(before.remainingMinutes, 240);

      final after = result.ledger.allocate(date, 90);
      expect(after.forDate(date).allocatedMinutes, 90);
      expect(after.forDate(date).remainingMinutes, 150);
      expect(
        result.ledger.forDate(date),
        before,
        reason: '账本是不可变快照：allocate 返回新实例，不得就地改掉别人的视图',
      );
    });

    test('释放后逐值恢复到分配之前', () {
      final window = _dayWindow(5);
      final result = _build(
        window: window,
        rules: _rules(dailyLimit: 600),
        fixed: [
          TimeRange(startUtc: _midnight(5), endUtc: _at(5, 10 * 60)),
          TimeRange(startUtc: _at(5, 14 * 60), endUtc: _midnight(6)),
        ],
      );
      final date = DateTime(2026, 10, 5);
      final before = result.ledger.forDate(date);

      final roundTripped = result.ledger.allocate(date, 90).release(date, 90);
      expect(roundTripped.forDate(date), before);
    });

    test('超额分配抛 StateError，且不静默夹紧', () {
      final window = _dayWindow(5);
      final result = _build(
        window: window,
        rules: _rules(dailyLimit: 600),
        fixed: [
          TimeRange(startUtc: _midnight(5), endUtc: _at(5, 10 * 60)),
          TimeRange(startUtc: _at(5, 14 * 60), endUtc: _midnight(6)),
        ],
      );

      expect(
        () => result.ledger.allocate(DateTime(2026, 10, 5), 241),
        throwsA(isA<StateError>()),
        reason: '越界分配是算法缺陷，静默夹紧会把它变成"少排了几分钟"',
      );
      // 边界值本身合法。
      expect(
        result.ledger
            .allocate(DateTime(2026, 10, 5), 240)
            .forDate(DateTime(2026, 10, 5))
            .remainingMinutes,
        0,
      );
    });

    test('超额释放与负分钟都抛 StateError', () {
      final window = _dayWindow(5);
      final result = _build(window: window, rules: _rules());

      expect(
        () => result.ledger.release(DateTime(2026, 10, 5), 30),
        throwsA(isA<StateError>()),
        reason: '没分配过就释放 30 分钟意味着有人在重复退款',
      );
      expect(
        () => result.ledger.allocate(DateTime(2026, 10, 5), -30),
        throwsA(isA<StateError>()),
        reason: '负数分配应当走 release，不能靠 allocate 的负增量绕过守恒检查',
      );
    });

    test('缺日抛 StateError（账本必须覆盖窗口的每一天）', () {
      final window = _dayWindow(5);
      final result = _build(window: window, rules: _rules());

      expect(
        () => result.ledger.forDate(DateTime(2026, 10, 9)),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('负载率与确定性', () {
    test('负载率按**许可容量归一化**，而不是绝对空闲分钟', () {
      final window = _dayWindow(5);
      final result = _build(
        window: window,
        rules: _rules(dailyLimit: 240),
        // 许可容量 = min(硬空闲 600, 上限 240) = 240；已用 120 ⇒ 50%。
        //
        // 空档是 10:00–22:00（12 小时 = 720 分钟），扣掉睡眠 5 分钟 ⇒ 硬空闲 715；
        // 上限 240 更小，因此许可容量是 240。
        fixed: [
          TimeRange(startUtc: _midnight(5), endUtc: _at(5, 10 * 60)),
          TimeRange(startUtc: _at(5, 22 * 60), endUtc: _midnight(6)),
        ],
        locked: [
          PlannedBlock(
            id: 'locked-1',
            taskId: 't-a',
            range: TimeRange(
              startUtc: _at(5, 10 * 60),
              endUtc: _at(5, 12 * 60),
            ),
            locked: true,
          ),
        ],
      );

      final snapshot = result.ledger.forDate(DateTime(2026, 10, 5));
      expect(snapshot.licensedCapacityMinutes, 240);
      expect(snapshot.usedMovableMinutes, 120);
      expect(
        snapshot.utilizationPermille,
        500,
        reason:
            'ceil(120 × 1000 / 240) = 500；'
            '若用绝对空闲分钟（视觉空白 600）当分母会得到 200，'
            '那会让"许可容量小的日子"看起来比实际空闲',
      );
    });

    test('同一份输入重复构造逐值相同，且日期升序', () {
      final window = TimeRange(startUtc: _midnight(9), endUtc: _midnight(12));
      final first = _build(window: window, rules: _rules(dailyLimit: 300));
      final again = _build(window: window, rules: _rules(dailyLimit: 300));

      expect(again.ledger.localDates, first.ledger.localDates);
      for (final date in first.ledger.localDates) {
        expect(again.ledger.forDate(date), first.ledger.forDate(date));
      }
    });
  });
}
