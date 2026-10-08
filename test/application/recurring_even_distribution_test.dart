// 1.7.1 周期目标「均匀分布」修复的回归门槛。
//
// 实施计划：`2026-10-08-v1.7.1-recurring-goal-even-distribution-fix.md`
//   Task 1（用本次真实现象建立失败回归测试）、Task 4（局部改进不得重新聚拢）。
//
// ## 这些用例为什么必须存在
//
// 修复前的"均匀分布"测试只断言结果**跨越多于一个本地日期**（见
// `recurring_planning_test.dart` 的"均匀分布不会把 180 分钟全堆到周日"）。
// 而用户实测的 `35 / 125 / 50 / 0` **同样跨越了三个日期**，因此错误结果照样能通过。
//
// 所以这里的门槛是**每日分钟差**，不是"跨越几天"。
//
// ## 用户实测的原始现象（计划 §1.2）
//
// 模板"蓝桥杯竞赛课"：目标 210、节奏 `even`、允许星期 127、可拆分 25～90 分钟、中等精力、
// `Asia/Shanghai`。2026-10-08（周四）晚生成计划，本周（10-05～10-11）的实际分布是：
//
//   | 日期 | 分钟 |
//   | --- | ---: |
//   | 10-08 周四 | 35 |
//   | 10-09 周五 | 125 |
//   | 10-10 周六 | 50 |
//   | 10-11 周日 | 0 |
//
// 周四到周日都还有容量，理想均分是 `210 ÷ 4 = 52.5`，按 5 分钟粒度可实现的最均匀组合是
// **两个 50 与两个 55**。本文件把 `[50, 50, 55, 55]` 钉成回归门槛。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

const _timeZoneId = 'Asia/Shanghai';

final _zones = TimeZoneDatabase();

// ── 用户实测场景的时间轴（全部按本地时间写出，再换算成 UTC）────────────────────
//
// 周四 2026-10-08 20:00 开始规划；本周周期在周一 2026-10-12 00:00 结束。
// 注意周期**结束于下周一零点**，因此 10-12 当天属于下一周、不属于本周。
final _planStartUtc = _zones.localDateTimeToUtc(
  DateTime(2026, 10, 8),
  20 * 60,
  _timeZoneId,
);
final _periodEndUtc = _zones.localMidnightToUtc(
  DateTime(2026, 10, 12),
  _timeZoneId,
);

/// 本地某天从 [startHour] 起空闲 [minutes] 分钟。
TimeRange _freeOn(int day, int startHour, int minutes) => TimeRange(
  startUtc: _zones.localDateTimeToUtc(
    DateTime(2026, 10, day),
    startHour * 60,
    _timeZoneId,
  ),
  endUtc: _zones.localDateTimeToUtc(
    DateTime(2026, 10, day),
    startHour * 60 + minutes,
    _timeZoneId,
  ),
);

/// 把"空闲时间"变成"忙碌时间"：整个周期都占住，只留下 [free] 这些窗口。
List<BusyInterval> _busyExcept(List<TimeRange> free) {
  final result = <BusyInterval>[];
  var cursor = _planStartUtc;
  for (final range in free) {
    if (range.startUtc.isAfter(cursor)) {
      result.add(
        BusyInterval(
          id: 'busy-${cursor.millisecondsSinceEpoch}',
          range: TimeRange(startUtc: cursor, endUtc: range.startUtc),
        ),
      );
    }
    if (range.endUtc.isAfter(cursor)) cursor = range.endUtc;
  }
  if (cursor.isBefore(_periodEndUtc)) {
    result.add(
      BusyInterval(
        id: 'busy-tail',
        range: TimeRange(startUtc: cursor, endUtc: _periodEndUtc),
      ),
    );
  }
  return result;
}

PlanningRules _rules() => PlanningRules(
  energyWindows: const [],
  protectedTimes: const [],
  // 睡眠 00:00–07:00（本地）。**不能写成 0–0**：`LocalTimeRange` 拒绝零长度区间。
  // 这个窗口落在四天空闲窗口之外，因此不影响本例的容量形状。
  sleepRange: LocalTimeRange(startMinute: 0, endMinute: 7 * 60),
  minimumSleepMinutes: 60,
  defaultFocusMinutes: 60,
  breakMinutes: 0,
  dailyMovableTaskLimitMinutes: 1440,
  weeklyLifeQuotaMinutes: 0,
  minChunkMinutes: 25,
  maxChunkMinutes: 90,
  granularityMinutes: 5,
);

SchedulableTask _goal({LocalTimeRange? preferredWindow}) => SchedulableTask(
  id: 'recurring:template-1:2026-10-05',
  requiredMinutes: 210,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 25,
  maxChunkMinutes: 90,
  priority: TaskPriority.medium,
  energyLevel: TaskEnergyLevel.medium,
  preferredWindow: preferredWindow,
);

ScheduleProblem _problem(
  SchedulableTask task,
  List<BusyInterval> busy, {
  List<PlannedBlock> lockedBlocks = const [],
}) => ScheduleProblem(
  planningWindow: TimeRange(startUtc: _planStartUtc, endUtc: _periodEndUtc),
  timeZoneId: _timeZoneId,
  tasks: [task],
  fixedIntervals: busy,
  protectedIntervals: const [],
  lockedBlocks: lockedBlocks,
  rules: _rules(),
  preferences: const PreferenceProfile(),
  inputHash: 'even-distribution-v1',
  pinnedUnlockedBlockIds: const {},
);

/// 每个本地日期的已安排分钟（只统计 [taskId]，且只统计落在本周内的块）。
Map<int, int> _minutesByDay(
  ScheduleProposal proposal,
  String taskId, {
  required int firstDay,
  required int lastDay,
}) {
  final result = <int, int>{
    for (var day = firstDay; day <= lastDay; day++) day: 0,
  };
  for (final block in proposal.blocks) {
    if (block.taskId != taskId) continue;
    final local = _zones.toLocal(block.startUtc, _timeZoneId);
    if (local.month != 10) continue;
    if (!result.containsKey(local.day)) continue;
    final current = result[local.day];
    if (current == null) continue;
    result[local.day] = current + block.durationMinutes;
  }
  return result;
}

void main() {
  group('210 分钟、周四晚开始、周四至周日各有容量（用户实测回归）', () {
    // 四天各留 90 分钟合法容量（≥ 最大片段，因此任何一天都能独立承接一段）。
    // 关键：**四天容量相同**，所以"某天多排"只能来自评分偏好，不能归因于容量形状。
    List<BusyInterval> fourEvenDays() => _busyExcept([
      _freeOn(8, 20, 90), // 周四 20:00–21:30
      _freeOn(9, 10, 90), // 周五 10:00–11:30
      _freeOn(10, 10, 90), // 周六 10:00–11:30
      _freeOn(11, 10, 90), // 周日 10:00–11:30
    ]);

    test('**每日分钟是 [50, 50, 55, 55]，四天都有安排**', () {
      final task = _goal();
      final proposal = DeterministicScheduleEngine(_zones)
          .generate(_problem(task, fourEvenDays()));

      final byDay = _minutesByDay(proposal, task.id, firstDay: 8, lastDay: 11);

      expect(
        byDay.values.fold<int>(0, (sum, value) => sum + value),
        210,
        reason: '总目标必须完整排下；实际 $byDay',
      );
      expect(
        byDay.values.where((value) => value > 0),
        hasLength(4),
        reason: '周四至周日都有容量，四天都该用上；实际 $byDay',
      );
      expect(
        byDay.values.toList()..sort(),
        [50, 50, 55, 55],
        reason:
            '按 5 分钟粒度，210 分钟分给四天最均匀的组合就是两个 50 与两个 55'
            '（修复前是 35/125/50/0）；实际 $byDay',
      );
    });

    test('**没有任何一天达到 125 分钟**（修复前的单日聚拢）', () {
      final task = _goal();
      final proposal = DeterministicScheduleEngine(_zones)
          .generate(_problem(task, fourEvenDays()));

      final byDay = _minutesByDay(proposal, task.id, firstDay: 8, lastDay: 11);
      expect(
        byDay.values.every((value) => value <= 60),
        isTrue,
        reason: '均匀分布下每天应接近 52.5 分钟，不该出现 125；实际 $byDay',
      );
    });
  });

  group('跨日均匀优先于日内评分', () {
    test('**同任务连续性与期望时段都偏向周五时，按日分布仍然是 [50, 50, 55, 55]**', () {
      // 期望时段写成周五 10:00–11:30：这是**软偏好**，只该决定"周五这一天内部放几点"，
      // 不该把另外三天的分钟搬进周五（计划 §3.2、§2.3）。
      final task = _goal(
        preferredWindow: LocalTimeRange(
          startMinute: 10 * 60,
          endMinute: 11 * 60 + 30,
        ),
      );
      final proposal = DeterministicScheduleEngine(_zones).generate(
        _problem(
          task,
          _busyExcept([
            _freeOn(8, 20, 90),
            _freeOn(9, 10, 90),
            _freeOn(10, 10, 90),
            _freeOn(11, 10, 90),
          ]),
        ),
      );

      final byDay = _minutesByDay(proposal, task.id, firstDay: 8, lastDay: 11);
      expect(byDay.values.toList()..sort(), [
        50,
        50,
        55,
        55,
      ], reason: '日内评分不得推翻跨日均匀分配；实际 $byDay');
    });

    test('**旧计划已经聚拢在周五时，稳定性惩罚不能阻止本次恢复均匀**', () {
      // 旧确认计划在周五堆了 125 分钟（正是用户实测的那一份）。稳定性评分通常会给
      // "移动既有块"扣 700 分，从而继续维持聚拢。计划 §3.3 要求：稳定性只在
      // **同等均匀度**的候选之间生效，不能成为保留不均匀结果的理由。
      final task = _goal();
      final fridayBase = _zones.localDateTimeToUtc(
        DateTime(2026, 10, 9),
        10 * 60,
        _timeZoneId,
      );
      final oldBlocks = [
        for (var i = 0; i < 3; i++)
          PlannedBlock(
            id: 'old-$i',
            taskId: task.id,
            range: TimeRange(
              startUtc: fridayBase.add(Duration(minutes: i * 30)),
              endUtc: fridayBase.add(Duration(minutes: (i + 1) * 30)),
            ),
            locked: false,
          ),
      ];

      final proposal = DeterministicScheduleEngine(_zones).generate(
        _problem(
          task,
          _busyExcept([
            _freeOn(8, 20, 90),
            _freeOn(9, 10, 90),
            _freeOn(10, 10, 90),
            _freeOn(11, 10, 90),
          ]),
          lockedBlocks: oldBlocks,
        ),
      );

      final byDay = _minutesByDay(proposal, task.id, firstDay: 8, lastDay: 11);
      expect(
        byDay[9],
        lessThanOrEqualTo(55),
        reason:
            '周五最多承担自己那一份（55 分钟）；修复前它会保留旧的 125 分钟。'
            '实际 $byDay',
      );
    });
  });

  group('上午是软偏好之外的合法容量', () {
    test('**周六下午只剩 25 分钟、上午有 120 分钟时，周六的份额全部完成且用到上午**', () {
      // 周六的日预算约 52.5 分钟（210 ÷ 4）。下午中等精力窗口只有 25 分钟，
      // 因此必须用上午补足——**不能**把不足部分挪到周五造成集中（计划 §3.2）。
      final task = _goal(
        preferredWindow: LocalTimeRange(
          startMinute: 13 * 60,
          endMinute: 14 * 60,
        ),
      );
      final proposal = DeterministicScheduleEngine(_zones).generate(
        _problem(
          task,
          _busyExcept([
            _freeOn(8, 20, 90),
            _freeOn(9, 10, 90),
            // 周六：上午 120 分钟 + 下午 25 分钟
            _freeOn(10, 8, 120),
            _freeOn(10, 13, 25),
            _freeOn(11, 10, 90),
          ]),
        ),
      );

      final byDay = _minutesByDay(proposal, task.id, firstDay: 8, lastDay: 11);
      expect(
        byDay[10],
        greaterThanOrEqualTo(50),
        reason: '周六该拿到自己那一份（约 50～55 分钟）；实际 $byDay',
      );

      final saturdayBlocks = proposal.blocks.where((block) {
        if (block.taskId != task.id) return false;
        final local = _zones.toLocal(block.startUtc, _timeZoneId);
        return local.month == 10 && local.day == 10;
      });
      expect(
        saturdayBlocks.any((block) {
          final local = _zones.toLocal(block.startUtc, _timeZoneId);
          return local.hour < 12;
        }),
        isTrue,
        reason:
            '下午窗口不足以完成当天份额，必须用上午补足；'
            '若没有任何上午片段，说明上午没进候选或被挪到了别的日期',
      );
    });
  });

  group('周期实例互相隔离', () {
    test('**下周实例的存在不改变本周的按日分配**', () {
      final task = _goal();
      final alone = DeterministicScheduleEngine(_zones).generate(
        _problem(
          task,
          _busyExcept([
            _freeOn(8, 20, 90),
            _freeOn(9, 10, 90),
            _freeOn(10, 10, 90),
            _freeOn(11, 10, 90),
          ]),
        ),
      );

      // 同一份输入，但**另外**塞进一个属于下周的已排块（10-12 周一）。
      // 它不在本周窗口内，因此本周的按日分配必须逐值不变。
      final nextWeekStart = _zones.localDateTimeToUtc(
        DateTime(2026, 10, 12),
        10 * 60,
        _timeZoneId,
      );
      final withNextWeek = DeterministicScheduleEngine(_zones).generate(
        _problem(
          task,
          _busyExcept([
            _freeOn(8, 20, 90),
            _freeOn(9, 10, 90),
            _freeOn(10, 10, 90),
            _freeOn(11, 10, 90),
          ]),
          lockedBlocks: [
            PlannedBlock(
              id: 'next-week-1',
              taskId: 'recurring:template-1:2026-10-12',
              range: TimeRange(
                startUtc: nextWeekStart,
                endUtc: nextWeekStart.add(const Duration(minutes: 90)),
              ),
              locked: true,
            ),
          ],
        ),
      );

      int thisWeekTotal(ScheduleProposal proposal) => _minutesByDay(
        proposal,
        task.id,
        firstDay: 8,
        lastDay: 11,
      ).values.fold<int>(0, (sum, value) => sum + value);

      expect(
        thisWeekTotal(withNextWeek),
        thisWeekTotal(alone),
        reason: '下周实例不得参与本周的分配或均匀度计算',
      );
      expect(
        withNextWeek.blocks.where((block) => block.taskId == task.id).every((
          block,
        ) {
          final local = _zones.toLocal(block.startUtc, _timeZoneId);
          return local.day <= 11;
        }),
        isTrue,
        reason: '本周实例的块必须落在 10-05～10-11 之内',
      );
    });
  });
}
