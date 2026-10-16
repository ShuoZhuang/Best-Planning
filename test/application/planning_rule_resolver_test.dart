// 逐日规划规则解析（算法 17，计划 `2026-10-16-capacity-aware-hierarchical-scheduler-repair.md`
// Task 2 Step 1/2/4）。
//
// ## 这一组用例要钉住的三件事
//
// 1. **兼容入口不变**：`resolveForWindow` 的签名、返回类型与"合并工作日／周末两套日间
//    规则"的行为逐值保持（日历读取路径仍在用它，本计划不碰界面）。
// 2. **新入口逐日**：`resolveByDateForWindow` 两端包含、按本地日期升序、去时分秒、
//    返回不可修改 Map，且一次性覆盖**只作用于命中日期**。
// 3. **缺日必须响亮失败**：`ScheduleProblem.policyForLocalDate` 找不到日期时抛
//    `StateError`，**绝不回退窗口首日**——那正是本计划要根除的缺陷本身。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/daily_scheduling_policy.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

const String _zoneId = 'Asia/Shanghai';

final TimeZoneDatabase _zones = TimeZoneDatabase();

PlanningRuleResolver _resolver() => PlanningRuleResolver(
  SettingsService(repository: MemorySettingsRepository()),
);

void main() {
  group('DailySchedulingPolicy（Task 2 Step 1）', () {
    test('构造时把带时分秒的日期归一为本地自然日', () {
      final policy = DailySchedulingPolicy(
        // 用带时刻、且带 UTC 标志的值：归一必须按"年月日"取，不受时刻与时区标志影响。
        localDate: DateTime.utc(2026, 10, 5, 23, 59),
        resolvedRules: DefaultSettings.v1(),
        softReserveTargetMinutes: 0,
      );

      expect(policy.localDate, DateTime(2026, 10, 5));
      expect(policy.localDate.isUtc, isFalse, reason: '归一结果必须是本地日期');
      expect(policy.localDate.hour, 0);
      expect(policy.localDate.minute, 0);
    });

    test('负恢复余量被拒绝', () {
      expect(
        () => DailySchedulingPolicy(
          localDate: DateTime(2026, 10, 5),
          resolvedRules: DefaultSettings.v1(),
          softReserveTargetMinutes: -1,
        ),
        throwsA(isA<ArgumentError>()),
        reason: '恢复余量是"至少留出多少"，负数没有含义',
      );
    });

    test('保存的是完整规则快照，而不是"当前碰巧用到的几个字段"', () {
      final rules = DefaultSettings.v1().copyWith(
        sleepRange: LocalTimeRange(startMinute: 0, endMinute: 300),
        dailyMovableTaskLimitMinutes: 480,
        granularityMinutes: 10,
        weeklyLifeQuotaMinutes: 90,
        courseTransitionMinutes: 15,
      );
      final policy = DailySchedulingPolicy(
        localDate: DateTime(2026, 10, 5),
        resolvedRules: rules,
        softReserveTargetMinutes: 30,
      );

      // 逐字段核对：漏抄任何一个日期敏感字段，都会让"周末用自己的规则"再次失效。
      expect(policy.resolvedRules.sleepRange.startMinute, 0);
      expect(policy.resolvedRules.sleepRange.endMinute, 300);
      expect(policy.resolvedRules.dailyMovableTaskLimitMinutes, 480);
      expect(policy.resolvedRules.granularityMinutes, 10);
      expect(policy.resolvedRules.weeklyLifeQuotaMinutes, 90);
      expect(policy.resolvedRules.courseTransitionMinutes, 15);
    });
  });

  group('resolveForWindow 兼容入口保持不变（Task 2 Step 2）', () {
    test('返回类型仍是 Future<PlanningRules>，且合并工作日与周末的日间规则', () async {
      final rules = await _resolver().resolveForWindow(DateTime(2026, 10, 5));

      // `PlanningRules` 是编译期检查，这里再断一次以防有人改成别的类型。
      expect(rules, isA<PlanningRules>());
      // 合并后的保护时间可以同时含工作日与周末两套（引擎按当天 `DayKind` 筛选）。
      expect(rules.protectedTimes, isNotNull);
    });
  });

  group('resolveByDateForWindow 逐日解析（Task 2 Step 2）', () {
    test('范围两端均包含，且按本地日期升序去时分秒', () async {
      final byDate = await _resolver().resolveByDateForWindow(
        DateTime(2026, 10, 5, 13, 45), // 带时刻：必须被归一
        DateTime(2026, 10, 7),
      );

      expect(byDate.keys.toList(), [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 6),
        DateTime(2026, 10, 7),
      ], reason: '两端均包含、升序、且去时分秒');
    });

    test('返回不可修改的 Map', () async {
      final byDate = await _resolver().resolveByDateForWindow(
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 6),
      );

      expect(
        () => byDate[DateTime(2026, 10, 8)] = DefaultSettings.v1(),
        throwsUnsupportedError,
        reason: '逐日规则是对外的事实快照，调用方不得就地改写',
      );
    });

    test('终点早于起点时抛 ArgumentError', () {
      expect(
        () => _resolver().resolveByDateForWindow(
          DateTime(2026, 10, 7),
          DateTime(2026, 10, 5),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('一次性覆盖只作用于命中日期', () async {
      final override = ScheduleRuleOverride(
        localDate: DateTime(2026, 10, 6),
        patch: PlanningRulesPatch(dailyMovableTaskLimitMinutes: 240),
      );

      final byDate = await _resolver().resolveByDateForWindow(
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 7),
        override: override,
      );
      final baseline = await _resolver().resolveByDateForWindow(
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 7),
      );

      expect(byDate[DateTime(2026, 10, 6)]!.dailyMovableTaskLimitMinutes, 240);
      expect(
        byDate[DateTime(2026, 10, 5)]!.dailyMovableTaskLimitMinutes,
        baseline[DateTime(2026, 10, 5)]!.dailyMovableTaskLimitMinutes,
        reason: '未命中日期必须逐值等于无覆盖的解析结果',
      );
      expect(
        byDate[DateTime(2026, 10, 7)]!.dailyMovableTaskLimitMinutes,
        baseline[DateTime(2026, 10, 7)]!.dailyMovableTaskLimitMinutes,
      );
    });

    test('**月末与年末边界逐日连续，不重复也不跳日**', () async {
      // 月份长度不同（31 天 / 30 天）与跨年进位都必须由"按日历日推进"保证。
      // 用 `add(Duration(days: 1))` 在 DST 切换日会错位——那条不变量由
      // `availability_builder_test.dart` 与 `repository_schedule_problem_source_test.dart`
      // 的时区用例钉住（它们持有 `TimeZoneDatabase`）。
      final monthEnd = await _resolver().resolveByDateForWindow(
        DateTime(2026, 10, 30),
        DateTime(2026, 11, 2),
      );
      expect(monthEnd.keys.toList(), [
        DateTime(2026, 10, 30),
        DateTime(2026, 10, 31),
        DateTime(2026, 11, 1),
        DateTime(2026, 11, 2),
      ]);

      final yearEnd = await _resolver().resolveByDateForWindow(
        DateTime(2026, 12, 31),
        DateTime(2027, 1, 1),
      );
      expect(yearEnd.keys.toList(), [
        DateTime(2026, 12, 31),
        DateTime(2027, 1, 1),
      ], reason: '跨年必须进位到 2027，而不是继续用 2026 的月日');
    });
  });

  group('ScheduleProblem.dailyPolicies 校验（Task 2 Step 4）', () {
    ScheduleProblem build({
      required Map<DateTime, DailySchedulingPolicy> policies,
      Map<DateTime, int> weeklyQuota = const {},
      TimeRange? window,
    }) => ScheduleProblem(
      planningWindow:
          window ??
          TimeRange(
            startUtc: _zones.localMidnightToUtc(DateTime(2026, 10, 5), _zoneId),
            endUtc: _zones.localMidnightToUtc(DateTime(2026, 10, 7), _zoneId),
          ),
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
      rules: DefaultSettings.v1(),
      dailyPolicies: policies,
      weeklyLifeQuotaByWeekStart: weeklyQuota,
      preferences: const PreferenceProfile(),
      inputHash: 'daily-policies-contract',
    );

    Map<DateTime, DailySchedulingPolicy> policiesFor(List<DateTime> dates) => {
      for (final date in dates)
        date: DailySchedulingPolicy(
          localDate: date,
          resolvedRules: DefaultSettings.v1(),
          softReserveTargetMinutes: 0,
        ),
    };

    test('空表被拒绝', () {
      expect(
        () => build(policies: const {}),
        throwsA(isA<ArgumentError>()),
        reason: '逐日策略是每一次日期敏感判断的事实源，空表意味着装配层没做这件事',
      );
    });

    test('缺一天被拒绝（缺日会让那一天悄悄回退首日规则）', () {
      expect(
        () => build(
          policies: policiesFor([
            DateTime(2026, 10, 5),
            // 缺 10-06
            DateTime(2026, 10, 7),
          ]),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('重复日被拒绝', () {
      final policy = DailySchedulingPolicy(
        localDate: DateTime(2026, 10, 5),
        resolvedRules: DefaultSettings.v1(),
        softReserveTargetMinutes: 0,
      );
      // 归一后同一个键出现两次：用带时刻的键绕过 Map 的字面量去重。
      expect(
        () => build(
          policies: {
            DateTime(2026, 10, 5): policy,
            DateTime(2026, 10, 5, 12): policy,
            DateTime(2026, 10, 6): policy,
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('policyForLocalDate 归一入参，缺键时抛 StateError 而不是回退首日', () {
      final problem = build(
        policies: policiesFor([DateTime(2026, 10, 5), DateTime(2026, 10, 6)]),
      );

      expect(
        problem.policyForLocalDate(DateTime(2026, 10, 6, 22, 30)).localDate,
        DateTime(2026, 10, 6),
        reason: '入参带时刻也要命中当天的策略',
      );

      expect(
        () => problem.policyForLocalDate(DateTime(2026, 10, 9)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('2026-10-9'),
          ),
        ),
        reason: '缺日必须响亮失败：回退首日就是本计划要根除的缺陷',
      );
    });

    test('lifeQuotaForLocalWeek 回退到该周周一，缺周抛 StateError', () {
      final problem = build(
        policies: policiesFor([
          DateTime(2026, 10, 5),
          DateTime(2026, 10, 6),
          DateTime(2026, 10, 7),
        ]),
        // 2026-10-05 是周一。
        weeklyQuota: {DateTime(2026, 10, 5): 210},
      );

      expect(problem.lifeQuotaForLocalWeek(DateTime(2026, 10, 7)), 210);
      expect(
        () => problem.lifeQuotaForLocalWeek(DateTime(2026, 10, 12)),
        throwsA(isA<StateError>()),
        reason: '缺周意味着装配层没有解析那一周的规则，静默返回 0 会让缺口无法解释',
      );
    });

    test('周配额不能为负', () {
      expect(
        () => build(
          policies: policiesFor([DateTime(2026, 10, 5), DateTime(2026, 10, 6)]),
          weeklyQuota: {DateTime(2026, 10, 5): -1},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
