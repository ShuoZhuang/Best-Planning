// 容量感知的逐周排程回归门槛（计划 `2026-10-16-capacity-aware-hierarchical-scheduler-repair.md`
// §Task 1 Step 2–5）。
//
// ## 这一组用例要钉住的结构缺口
//
// 算法 16 的日期选择没有独立的**日负载**目标：候选评分相同后按最早开始时间打破平局，
// 于是天然向窗口前部聚集（计划 §1.2 第 4 条）。用户可观察到的现象是
// 「工作日越来越挤、周末整周空着」，而不是「容量不够」。
//
// 三种形状在这里各成一条门槛：
//
// 1. **普通任务（`unconstrained`）**：工作日已占许可容量的 75%、周末为 0，截止在下周一。
//    周末是**容量更高、负载更低**的合法日期，因此必须有块落在周末，且工作日负载不得继续恶化。
// 2. **截止覆盖均衡**：同一输入把截止收到周五 12:00。低负载的周末在截止之后，
//    **不得**被使用；缺口可以存在，但必须有结构化证据（`unscheduled`）。
// 3. **逐日每日上限**：周一至周五上限 180、周末上限 360。周日的账面容量必须按 360 算，
//    而不是复制窗口首日的 180（计划 §1.2 第 1 条：日期敏感字段不得取窗口首日）。
//
// ## 为什么夹具形状是这样
//
// 每一天的容量都是「一段合法空档 + 一段固定占用」。工作日把 75% 的许可容量交给固定占用，
// 于是剩下的空档刚好只够一个最小片段；周末整天空着。这样"块落哪一天"只由**跨日选择**
// 决定，不会与"某天根本没有合法形状"混为一谈。
//
// ## 匿名化
//
// 只使用相对时刻与匿名 id（`ordinary-a`）。没有真实任务标题、没有真实 UUID、
// 没有用户数据库内容（Global Constraints）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import '../support/daily_policies.dart';

const String _timeZoneId = 'Asia/Shanghai';

final TimeZoneDatabase _zones = TimeZoneDatabase();

/// 本地周：2026-10-05（周一）00:00 到 2026-10-12（周一）00:00。
DateTime _localMidnight(int day) =>
    _zones.localMidnightToUtc(DateTime(2026, 10, day), _timeZoneId);

DateTime _localAt(int day, int minuteOfDay) => _zones.localDateTimeToUtc(
  DateTime(2026, 10, day),
  minuteOfDay,
  _timeZoneId,
);

/// 每天的许可容量（`min(硬空闲, 每日可移动上限)`）：10-05 至 10-11 各 120 分钟。
const int _licensedPerDay = 120;

/// 工作日空档里被占住的分钟数：许可容量 120 里已用 50（约 42%），周末为 0。
///
/// 取 50 而不是 90 是有意的：工作日空档因此是 **70 分钟**，足够放下**两**个 30 分钟片段
/// （70 = 30 + 10 + 30），于是「七天各拿一份 30 分钟」在容量上真的可行，
/// 日期选择不会被"某天根本排不下"掩盖。
const int _weekdayBusy = 50;

/// 工作日空档长度：08:00 起 70 分钟。
const int _weekdayGapEndMinute = 8 * 60 + 70;

/// 工作日与周末各自的每日可移动上限（第 5 个用例的形状）。
const int _weekdayLimit = 180;
const int _weekendLimit = 360;

const int _granularity = 5;
const int _breakMinutes = 10;

/// 本组夹具统一的规则。
///
/// 刻意把 `granularityMinutes` 与 `breakMinutes` 显式写出来：每日下限与片段形状都读它，
/// 不写就会拿到与生产不同的默认值，测试钉的就不再是生产形状。
PlanningRules _rules({
  required int dailyMovableLimit,
  int granularityMinutes = _granularity,
}) => PlanningRules(
  energyWindows: const [],
  protectedTimes: const [],
  // 睡眠 00:00–06:00 本地：完全落在每日空档之外，因此不改变容量形状。
  sleepRange: LocalTimeRange(startMinute: 0, endMinute: 6 * 60),
  minimumSleepMinutes: 60,
  defaultFocusMinutes: 60,
  breakMinutes: _breakMinutes,
  dailyMovableTaskLimitMinutes: dailyMovableLimit,
  weeklyLifeQuotaMinutes: 0,
  minChunkMinutes: 30,
  maxChunkMinutes: 90,
  granularityMinutes: granularityMinutes,
);

/// 工作日（10-05..10-09）的固定占用：占满许可容量里的 50 分钟。
///
/// 形状是「空档 08:00–09:10 共 70 分钟，然后 09:10 起被固定日程占到 10:10」。
/// 70 分钟的空档能放下两个 30 分钟片段（含 10 分钟休息），因此工作日
/// **不是**没有合法形状——它们只是负载更高、可放量更少。
List<BusyInterval> _weekdayOccupancy(int day) => [
  BusyInterval(
    id: 'occupied-$day',
    range: TimeRange(
      startUtc: _localAt(day, _weekdayGapEndMinute),
      endUtc: _localAt(day, _weekdayGapEndMinute + _weekdayBusy),
    ),
  ),
];

/// 七天窗口：工作日 75% 已占、周末整天空着。
List<BusyInterval> _busyWeekdaysOnly() => [
  for (var day = 5; day <= 9; day++) ..._weekdayOccupancy(day),
];

/// 每天固定占用 30 分钟：许可容量（120）里已用 30，剩余 90 分钟。
///
/// 七天形状完全相同，因此"选择哪五天"只可能来自**日期偏好**，不可能来自容量形状。
List<BusyInterval> _busyEveryDay() => [
  for (var day = 5; day <= 11; day++)
    BusyInterval(
      id: 'occupied-$day',
      range: TimeRange(
        startUtc: _localAt(day, 8 * 60),
        endUtc: _localAt(day, 8 * 60 + 30),
      ),
    ),
];

SchedulableTask _task({
  required int requiredMinutes,
  DateTime? dueAtUtc,
  int minChunkMinutes = 30,
  TaskDistributionPolicy distributionPolicy =
      TaskDistributionPolicy.unconstrained,
}) => SchedulableTask(
  id: 'ordinary-a',
  requiredMinutes: requiredMinutes,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: minChunkMinutes,
  maxChunkMinutes: 90,
  dueAtUtc: dueAtUtc,
  priority: TaskPriority.medium,
  energyLevel: TaskEnergyLevel.medium,
  distributionPolicy: distributionPolicy,
);

ScheduleProblem _problem({
  required SchedulableTask task,
  required List<BusyInterval> busy,
  required int dailyMovableLimit,
  int granularityMinutes = _granularity,
}) {
  final window = TimeRange(
    startUtc: _localMidnight(5),
    endUtc: _localMidnight(12),
  );
  final rules = _rules(
    dailyMovableLimit: dailyMovableLimit,
    granularityMinutes: granularityMinutes,
  );
  return ScheduleProblem(
    planningWindow: window,
    timeZoneId: _timeZoneId,
    tasks: [task],
    fixedIntervals: busy,
    protectedIntervals: const [],
    lockedBlocks: const [],
    rules: rules,
    // 本文件的多条用例正是要证明"每日上限、粒度按**当天**规则生效"，
    // 因此逐日策略必须显式给出（计划 Task 2 Step 4）。
    dailyPolicies: dailyPoliciesForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: _timeZoneId,
    ),
    weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
      zones: _zones,
      window: window,
      rules: rules,
      timeZoneId: _timeZoneId,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'capacity-aware-week-v1',
  );
}

/// 每个本地日的已排分钟（10-05..10-11），键是月内日号。
Map<int, int> _minutesByDay(ScheduleProposal proposal) {
  final result = <int, int>{for (var day = 5; day <= 11; day++) day: 0};
  for (final block in proposal.blocks) {
    final local = _zones.toLocal(block.startUtc, _timeZoneId);
    if (local.month != 10) continue;
    final current = result[local.day];
    if (current == null) continue;
    result[local.day] = current + block.durationMinutes;
  }
  return result;
}

/// 本地星期是否属于周末（周六、周日）。
bool _isWeekendLocal(DateTime localDate) =>
    localDate.weekday == DateTime.saturday ||
    localDate.weekday == DateTime.sunday;

void main() {
  final engine = DeterministicScheduleEngine(_zones);

  group('工作日繁忙、周末空闲（计划 Task 1 Step 3）', () {
    test('**普通任务必须用上低负载周末，而不是把工作日继续堆满**', () {
      // 工作日已用 50 / 许可 120 ≈ 42%，周末 0 / 120 = 0%；
      // 但工作日空档只有 70 分钟（最多两块），周末有 120 分钟（最多三块）。
      // 新任务 150 分钟、最小片段 30、截止下周一，允许全部星期。
      final problem = _problem(
        task: _task(requiredMinutes: 150, dueAtUtc: _localMidnight(12)),
        busy: _busyWeekdaysOnly(),
        dailyMovableLimit: _licensedPerDay,
      );

      final proposal = engine.generate(problem);
      final byDay = _minutesByDay(proposal);

      expect(
        byDay.values.fold<int>(0, (sum, value) => sum + value),
        150,
        reason: '窗口内合法容量充足（周末每天 120 分钟），目标必须完整排下；实际 $byDay',
      );

      final weekendMinutes = byDay[10]! + byDay[11]!;
      expect(
        weekendMinutes,
        greaterThan(0),
        reason:
            '周末负载 0%、可放量 120 分钟，工作日负载 42%、可放量 70 分钟；'
            '至少一个块必须落到周末。工作日前置的旧行为会把 150 分钟全部塞进五个工作日'
            '（实际 $byDay）',
      );

      for (final day in [5, 6, 7, 8, 9]) {
        expect(
          byDay[day]!,
          lessThanOrEqualTo(60),
          reason:
              '工作日空档 70 分钟只能放下两块，因此单日新增不得超过 60 分钟；'
              '第 $day 日加到 ${byDay[day]} 说明工作日被继续堆满（实际 $byDay）',
        );
      }
    });
  });

  group('截止覆盖均衡（计划 Task 1 Step 4）', () {
    test('**低负载周末晚于截止时不得使用，并如实报告缺口**', () {
      // 同一份输入，只把截止收到周五 12:00。周六周日负载更低，但在截止之后。
      final problem = _problem(
        task: _task(requiredMinutes: 150, dueAtUtc: _localAt(9, 12 * 60)),
        busy: _busyWeekdaysOnly(),
        dailyMovableLimit: _licensedPerDay,
      );

      final proposal = engine.generate(problem);

      for (final block in proposal.blocks) {
        expect(
          block.endUtc.isAfter(_localAt(9, 12 * 60)),
          isFalse,
          reason:
              '块 ${block.startUtc.toIso8601String()}–${block.endUtc.toIso8601String()} '
              '越过截止（周五 12:00）',
        );
      }

      final byDay = _minutesByDay(proposal);
      expect(
        byDay[10]! + byDay[11]!,
        0,
        reason: '周末在截止之后，不得为了"低负载"而使用；实际 $byDay',
      );

      // 截止之前每个工作日只有 70 分钟空档，最多放下两块（60 分钟）。
      // 五个工作日合计最多 300 分钟，因此 150 分钟**排得下**——本用例钉的是
      // "不越过截止"，不是"排不下"。
      final scheduled = byDay.values.fold<int>(0, (sum, value) => sum + value);
      expect(scheduled, 150, reason: '截止前容量足以排下 150 分钟；实际 $byDay');
      expect(
        proposal.unscheduled.fold<int>(
          0,
          (sum, item) => sum + item.shortageMinutes,
        ),
        0,
        reason: '排得下就不该有缺口；有缺口说明截止前的合法容量被低估',
      );
    });
  });

  group('逐日每日上限（计划 Task 1 Step 5）', () {
    test('**周末账面容量按自己的上限 360 算，而不是复制窗口首日的 180**', () {
      // 周一至周五上限 180、周末上限 360。夹具**只在周末留出可行空档**，
      // 因此 400 分钟能否排下完全取决于周日是否按 360 计算。
      final busy = <BusyInterval>[
        for (var day = 5; day <= 9; day++)
          BusyInterval(
            id: 'all-day-$day',
            range: TimeRange(
              startUtc: _localAt(day, 0),
              endUtc: _localAt(day + 1, 0),
            ),
          ),
        // 周六整天占住；周日整日空着，可用量由它自己的 360 分钟上限约束。
        BusyInterval(
          id: 'all-day-10',
          range: TimeRange(startUtc: _localAt(10, 0), endUtc: _localAt(11, 0)),
        ),
      ];
      final window = TimeRange(
        startUtc: _localMidnight(5),
        endUtc: _localMidnight(12),
      );
      // `rules` 是窗口首日（周一）的解析结果，上限 180。
      final weekdayRules = _rules(dailyMovableLimit: _weekdayLimit);
      final weekendRules = _rules(dailyMovableLimit: _weekendLimit);
      final problem = ScheduleProblem(
        planningWindow: window,
        timeZoneId: _timeZoneId,
        tasks: [_task(requiredMinutes: 400)],
        fixedIntervals: busy,
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: weekdayRules,
        // **逐日策略给出真正的逐日上限**：周一至周五 180、周末 360。
        // 这正是"周末账面容量按 360 算"这件事的数据来源。
        dailyPolicies: {
          for (final date in enumerateLocalDates(
            zones: _zones,
            window: window,
            timeZoneId: _timeZoneId,
          ))
            date: DailySchedulingPolicy(
              localDate: date,
              resolvedRules: _isWeekendLocal(date)
                  ? weekendRules
                  : weekdayRules,
              softReserveTargetMinutes: 0,
            ),
        },
        weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
          zones: _zones,
          window: window,
          rules: weekdayRules,
          timeZoneId: _timeZoneId,
        ),
        preferences: const PreferenceProfile(),
        inputHash: 'capacity-aware-week-weekend-limit-v1',
      );

      final proposal = engine.generate(problem);
      final byDay = _minutesByDay(proposal);

      expect(
        byDay[11]!,
        greaterThan(_weekdayLimit),
        reason:
            '周日上限是 $_weekendLimit，不是窗口首日的 $_weekdayLimit；'
            '若周日只排到 ${byDay[11]} 分钟，说明日期敏感字段仍在读首日规则（实际 $byDay）',
      );
      expect(
        byDay.values.fold<int>(0, (sum, value) => sum + value),
        400,
        reason: '周日可用 360 分钟，400 分钟排得下；实际 $byDay',
      );
      expect(proposal.unscheduled, isEmpty, reason: '容量充足时不应有缺口');
    });
  });

  group('七天等容量时的日期选择（计划 Task 1 Step 2）', () {
    test('**150/30 不得固定选择前五个日期**', () {
      // 七天原始容量与已用量**完全相同**（各剩 90 分钟），因此"只选周一至周五"
      // 只可能来自"同分取最早日期"这条打破平局规则（计划 §1.2 第 3、4 条）。
      final problem = _problem(
        task: _task(requiredMinutes: 150, dueAtUtc: _localMidnight(12)),
        busy: _busyEveryDay(),
        dailyMovableLimit: _licensedPerDay,
      );

      final proposal = engine.generate(problem);
      final byDay = _minutesByDay(proposal);
      final usedDays = byDay.entries.where((entry) => entry.value > 0).length;

      expect(
        byDay.values.fold<int>(0, (sum, value) => sum + value),
        150,
        reason: '目标必须完整排下；实际 $byDay',
      );
      expect(
        usedDays,
        greaterThan(5),
        reason:
            '七天业务字段与容量完全相同，参与日不得固定是前五天；'
            '实际只用了 $usedDays 天（$byDay）',
      );
    });

    test('**150/30 均匀周期目标在七天等余量下也不得固定选前五日**', () {
      // 与上一条同形，但走**均匀分布**这条路径：`distributionPolicy == even`
      // 由容量感知均分器给出每日预算（计划 §1.2 第 3 条）。
      //
      // 粒度取 30（等于最小片段），于是"参与日期"这件事只由 K 日选择决定：
      // 七天各余 90 分钟，150 分钟分给 K 天要求 `K × 30 ≤ 150 ≤ K × 90`，
      // 因此 K 可以取到 5。修复前按"余量降序、日期升序"取前 K 天，
      // 于是永远选中周一至周五。
      final problem = _problem(
        task: _task(
          requiredMinutes: 150,
          dueAtUtc: _localMidnight(12),
          distributionPolicy: TaskDistributionPolicy.even,
        ),
        busy: _busyEveryDay(),
        dailyMovableLimit: _licensedPerDay,
        granularityMinutes: 30,
      );

      final proposal = engine.generate(problem);
      final byDay = _minutesByDay(proposal);
      final usedDays = byDay.entries.where((entry) => entry.value > 0).length;

      expect(
        byDay.values.fold<int>(0, (sum, value) => sum + value),
        150,
        reason: '目标必须完整排下；实际 $byDay',
      );
      expect(
        usedDays,
        greaterThan(5),
        reason:
            '七天的余量与业务字段完全相同，参与日不得固定是周一至周五；'
            '实际只用了 $usedDays 天（$byDay）',
      );
    });
  });
}
