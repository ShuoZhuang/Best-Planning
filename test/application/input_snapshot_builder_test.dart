// 排程输入哈希的确定性（算法 17，计划 Task 2 Step 6）。
//
// ## 为什么逐日规则必须进哈希
//
// 算法 17 的排程结果按"**每一天自己的规则**"变化，而 `ScheduleProblem.rules` 只是
// 窗口首日的兼容快照。若只哈希首日规则，用户把**周末**的每日上限、睡眠或粒度改掉之后，
// 输入哈希仍然命中——确认阶段就会接受一份按旧规则生成的提案。
// 症状是"我改了设置，预览却说没变化"，而用户没有任何依据判断哪一个是真的。
//
// ## 两条纪律
//
// 1. **与 Map 插入顺序无关**：反转 `dailyPolicies` 与 `weeklyLifeQuotaByWeekStart`
//    的插入顺序必须得到同一个哈希（排程要求相同输入得到相同结果，而 Dart 的 Map
//    迭代顺序取决于插入顺序）。
// 2. **字段敏感**：改变任意一个日期敏感字段都必须让哈希变化。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

const String _zoneId = 'Asia/Shanghai';

final TimeZoneDatabase _zones = TimeZoneDatabase();

/// 窗口：本地 2026-10-05（周一）00:00 → 2026-10-12（周一）00:00，**整周七天**。
///
/// 取整周而不是三天：本文件的核心用例是"改变**周末**规则必须改变哈希"，
/// 而只有窗口真的覆盖周末，那条用例才不是在测空气。
TimeRange _window() => TimeRange(
  startUtc: _zones.localMidnightToUtc(DateTime(2026, 10, 5), _zoneId),
  endUtc: _zones.localMidnightToUtc(DateTime(2026, 10, 12), _zoneId),
);

List<DateTime> _localDates() => [
  for (var day = 5; day <= 11; day++) DateTime(2026, 10, day),
];

/// 三条日期各带一份（可能相同的）规则。
///
/// [rulesByDay] 为空时三天用同一份 [baseRules]。
Map<DateTime, DailySchedulingPolicy> _policies(
  PlanningRules baseRules, {
  PlanningRules? weekendRules,
  int softReserveTargetMinutes = 0,
  bool reversed = false,
}) {
  final dates = _localDates();
  final ordered = reversed ? dates.reversed.toList() : dates;
  return {
    for (final date in ordered)
      date: DailySchedulingPolicy(
        localDate: date,
        resolvedRules:
            weekendRules != null &&
                (date.weekday == DateTime.saturday ||
                    date.weekday == DateTime.sunday)
            ? weekendRules
            : baseRules,
        softReserveTargetMinutes: softReserveTargetMinutes,
      ),
  };
}

Map<DateTime, int> _weeklyQuota(PlanningRules rules, {bool reversed = false}) {
  final mondays = [DateTime(2026, 10, 5)];
  final ordered = reversed ? mondays.reversed.toList() : mondays;
  return {for (final monday in ordered) monday: rules.weeklyLifeQuotaMinutes};
}

ScheduleProblem _problem({
  PlanningRules? baseRules,
  PlanningRules? weekendRules,
  int softReserveTargetMinutes = 0,
  bool reversed = false,
  String inputHash = 'snapshot-hash',
}) {
  final base = baseRules ?? DefaultSettings.v1();
  return ScheduleProblem(
    planningWindow: _window(),
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
    lockedBlocks: const [],
    rules: base,
    dailyPolicies: _policies(
      base,
      weekendRules: weekendRules,
      softReserveTargetMinutes: softReserveTargetMinutes,
      reversed: reversed,
    ),
    weeklyLifeQuotaByWeekStart: _weeklyQuota(base, reversed: reversed),
    preferences: const PreferenceProfile(),
    inputHash: inputHash,
  );
}

String _hash(ScheduleProblem problem) =>
    const InputSnapshotBuilder().hash(InputSnapshot(problem: problem));

void main() {
  test('反转 dailyPolicies 的插入顺序不改变哈希', () {
    final forward = _hash(_problem());
    final reversed = _hash(_problem(reversed: true));

    expect(reversed, forward, reason: '排程要求相同输入得到相同结果，而 Map 迭代顺序取决于插入顺序');
  });

  test('相同输入重复求哈希逐值相同', () {
    final first = _hash(_problem());
    for (var run = 0; run < 5; run++) {
      expect(_hash(_problem()), first);
    }
  });

  test('**改变周末的每日上限 ⇒ 哈希必须变化**', () {
    final weekdayRules = DefaultSettings.v1().copyWith(
      dailyMovableTaskLimitMinutes: 180,
    );
    final weekendRules = DefaultSettings.v1().copyWith(
      dailyMovableTaskLimitMinutes: 360,
    );

    final sameEveryDay = _hash(
      _problem(baseRules: weekdayRules, weekendRules: weekdayRules),
    );
    final weekendDifferent = _hash(
      _problem(baseRules: weekdayRules, weekendRules: weekendRules),
    );

    expect(
      weekendDifferent,
      isNot(sameEveryDay),
      reason:
          '只哈希 `problem.rules`（窗口首日快照）时，这两种输入会得到同一个哈希，'
          '于是"改了周末设置"永远不会让预览过期',
    );
  });

  test('改变睡眠 ⇒ 哈希必须变化', () {
    final baseline = _hash(_problem());
    final changed = _hash(
      _problem(
        baseRules: DefaultSettings.v1().copyWith(
          sleepRange: LocalTimeRange(startMinute: 0, endMinute: 300),
        ),
      ),
    );

    expect(changed, isNot(baseline));
  });

  test('改变粒度 ⇒ 哈希必须变化', () {
    final baseline = _hash(_problem());
    final changed = _hash(
      _problem(
        baseRules: DefaultSettings.v1().copyWith(granularityMinutes: 15),
      ),
    );

    expect(changed, isNot(baseline));
  });

  test('改变休息间隔 ⇒ 哈希必须变化', () {
    final baseline = _hash(_problem());
    final changed = _hash(
      _problem(baseRules: DefaultSettings.v1().copyWith(breakMinutes: 25)),
    );

    expect(changed, isNot(baseline));
  });

  test('改变保护时间 ⇒ 哈希必须变化', () {
    final baseline = _hash(_problem());
    final changed = _hash(
      _problem(
        baseRules: DefaultSettings.v1().copyWith(
          protectedTimes: [
            ProtectedTimeRule(
              kind: ProtectedTimeKind.lunch,
              range: LocalTimeRange(startMinute: 12 * 60, endMinute: 13 * 60),
            ),
          ],
        ),
      ),
    );

    expect(changed, isNot(baseline));
  });

  test('改变周生活配额 ⇒ 哈希必须变化', () {
    final baseline = _hash(_problem());
    final changed = _hash(
      _problem(
        baseRules: DefaultSettings.v1().copyWith(weeklyLifeQuotaMinutes: 120),
      ),
    );

    expect(changed, isNot(baseline));
  });

  test('改变恢复余量目标 ⇒ 哈希必须变化', () {
    final baseline = _hash(_problem());
    final changed = _hash(_problem(softReserveTargetMinutes: 30));

    expect(changed, isNot(baseline));
  });

  test('哈希是稳定的十六进制串（sha256）', () {
    final hash = _hash(_problem());
    expect(hash, hasLength(64));
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hash), isTrue);
  });

  test('七日窗口里每一天真的带走自己的规则（夹具自检）', () {
    // 这条不是"测哈希"，而是证明上面那些"改变周末规则"的用例确实构造出了不同的
    // dailyPolicies——否则它们可能因为夹具没生效而变成假阳性。
    final weekdayRules = DefaultSettings.v1().copyWith(
      dailyMovableTaskLimitMinutes: 180,
    );
    final weekendRules = DefaultSettings.v1().copyWith(
      dailyMovableTaskLimitMinutes: 360,
    );
    final problem = _problem(
      baseRules: weekdayRules,
      weekendRules: weekendRules,
    );

    expect(
      problem.dailyPolicies.length,
      _localDates().length,
      reason: '逐日策略必须覆盖窗口的每一天',
    );
    // 2026-10-06 是周二、10-10 是周六。
    expect(
      problem
          .policyForLocalDate(DateTime(2026, 10, 6))
          .resolvedRules
          .dailyMovableTaskLimitMinutes,
      180,
    );
    expect(
      problem
          .policyForLocalDate(DateTime(2026, 10, 10))
          .resolvedRules
          .dailyMovableTaskLimitMinutes,
      360,
    );
  });
}
