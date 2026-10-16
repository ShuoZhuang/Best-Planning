// R5：任务期望时段因子（设计 §5.4「任务期望时段」，权重 -300 至 500）。
//
// 这个因子此前从未被引擎设置——`CandidateScoringContext.preferredTimeScore` 恒为 0，
// 期望时段字段也不存在。这里同时覆盖纯函数的插值与边界，以及经引擎的端到端落位。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/preferred_time_scorer.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

import '../support/daily_policies.dart';

/// 与 `SchedulingWeights.v1` 一致的区间端点。
const _minimum = -300;
const _maximum = 500;

final _zones = TimeZoneDatabase();

/// 09:00–12:00 的期望时段。
final _morning = LocalTimeRange(startMinute: 9 * 60, endMinute: 12 * 60);

int _score(
  LocalTimeRange? window,
  DateTime startUtc,
  int durationMinutes, {
  String timeZoneId = 'UTC',
  DateTime? localDate,
}) => preferredTimeScore(
  window: window,
  candidateRange: TimeRange(
    startUtc: startUtc,
    endUtc: startUtc.add(Duration(minutes: durationMinutes)),
  ),
  localDate: localDate ?? DateTime(startUtc.year, startUtc.month, startUtc.day),
  timeZoneId: timeZoneId,
  zones: _zones,
  minimumScore: _minimum,
  maximumScore: _maximum,
);

void main() {
  group('期望时段因子', () {
    test('没有期望时段时因子中性取 0', () {
      expect(_score(null, DateTime.utc(2026, 10, 5, 3), 60), 0);
      expect(_score(null, DateTime.utc(2026, 10, 5, 10), 60), 0);
    });

    test('完全落在时段内得满分', () {
      expect(_score(_morning, DateTime.utc(2026, 10, 5, 9), 60), _maximum);
      expect(_score(_morning, DateTime.utc(2026, 10, 5, 11), 60), _maximum);
    });

    test('完全不沾边得最低分，且低于"没有偏好"', () {
      expect(_score(_morning, DateTime.utc(2026, 10, 5, 13), 60), _minimum);
      expect(_score(_morning, DateTime.utc(2026, 10, 5, 6), 60), _minimum);
      // 用户表达了偏好却落空，应当比没有表达更差。
      expect(_minimum, lessThan(0));
    });

    test('部分落在时段内按重叠比例线性插值', () {
      // 11:45–12:15 有 15/30 落在时段内 → 半程。
      expect(_score(_morning, DateTime.utc(2026, 10, 5, 11, 45), 30), 100);
      // 08:45–09:15 同样有 15/30 落在时段内。
      expect(_score(_morning, DateTime.utc(2026, 10, 5, 8, 45), 30), 100);
      // 11:45–12:45 只有 15/60 落在时段内 → 四分之一。
      expect(_score(_morning, DateTime.utc(2026, 10, 5, 11, 45), 60), -100);
      // 09:00–10:00 完全落在时段内，不是部分满足。
      expect(_score(_morning, DateTime.utc(2026, 10, 5, 9), 60), _maximum);
      // 部分满足必须严格优于完全不满足。
      expect(
        _score(_morning, DateTime.utc(2026, 10, 5, 11, 45), 60),
        greaterThan(_score(_morning, DateTime.utc(2026, 10, 5, 14), 60)),
      );
    });

    test('跨越本地午夜的时段按两段计入，凌晨候选锚定到前一夜', () {
      // 22:00–02:00。
      final night = LocalTimeRange(startMinute: 22 * 60, endMinute: 2 * 60);
      // 当晚 23:00，锚定当日。
      expect(_score(night, DateTime.utc(2026, 10, 5, 23), 30), _maximum);
      // 次日凌晨 01:00：属于前一天夜里锚定的那个时段，必须同样满分，
      // 否则用户写下的 22:00–02:00 会把自己的凌晨时段判成落空。
      expect(_score(night, DateTime.utc(2026, 10, 6, 1), 30), _maximum);
      // 次日中午仍然落空。
      expect(_score(night, DateTime.utc(2026, 10, 6, 12), 30), _minimum);
    });

    test('时段终点为 24:00 时不抛错并正确判定', () {
      // 09:00–24:00：不跨午夜，但 endMinute 是 1440，直接换算会抛参数错误。
      final untilMidnight = LocalTimeRange(
        startMinute: 9 * 60,
        endMinute: LocalTimeRange.minutesPerDay,
      );
      expect(
        _score(untilMidnight, DateTime.utc(2026, 10, 5, 23), 30),
        _maximum,
      );
      expect(_score(untilMidnight, DateTime.utc(2026, 10, 5, 8), 30), _minimum);
    });

    test('夏令时切换当天按本地墙上时间判定', () {
      // 2026-03-08 是美国夏令时开始日，当地 09:00–12:00 对应 UTC 13:00–16:00（EDT，
      // UTC-4）。若误按切换前的 EST（UTC-5）换算，同一区间会落在 UTC 14:00–17:00，
      // 于是 13:30 UTC 会被误判为 08:30（落空），16:30 UTC 会被误判为 11:30（命中）。
      final localDate = DateTime(2026, 3, 8);
      expect(
        _score(
          _morning,
          DateTime.utc(2026, 3, 8, 13, 30),
          30,
          timeZoneId: 'America/New_York',
          localDate: localDate,
        ),
        _maximum,
      );
      expect(
        _score(
          _morning,
          DateTime.utc(2026, 3, 8, 16, 30),
          30,
          timeZoneId: 'America/New_York',
          localDate: localDate,
        ),
        _minimum,
      );
    });
  });

  group('引擎注入', () {
    ScheduleProblem problemWith(LocalTimeRange? window) {
      final planningWindowRange = TimeRange(
        startUtc: DateTime.utc(2026, 10, 5),
        endUtc: DateTime.utc(2026, 10, 6),
      );
      final zoneId = 'UTC';
      final rules = DefaultSettings.v1();
      return ScheduleProblem(
        planningWindow: planningWindowRange,
        timeZoneId: zoneId,
        tasks: [
          SchedulableTask(
            id: 'task-1',
            requiredMinutes: 60,
            splitMode: TaskSplitMode.splittable,
            minChunkMinutes: 30,
            maxChunkMinutes: 60,
            preferredWindow: window,
          ),
        ],
        fixedIntervals: const [],
        protectedIntervals: const [],
        lockedBlocks: const [],
        rules: rules,
        dailyPolicies: dailyPoliciesForWindow(
          zones: _zones,
          window: planningWindowRange,
          rules: rules,
          timeZoneId: zoneId,
        ),
        weeklyLifeQuotaByWeekStart: weeklyLifeQuotasForWindow(
          zones: _zones,
          window: planningWindowRange,
          rules: rules,
          timeZoneId: zoneId,
        ),
        preferences: const PreferenceProfile(),
        inputHash: 'preferred-time-v1',
      );
    }

    test('任务被安排在期望时段内', () {
      final engine = DeterministicScheduleEngine(_zones);
      final proposal = engine.generate(problemWith(_morning));

      expect(proposal.blocks, hasLength(1));
      final block = proposal.blocks.single;
      final startMinute = block.startUtc.hour * 60 + block.startUtc.minute;
      final endMinute = block.endUtc.hour * 60 + block.endUtc.minute;
      expect(startMinute, greaterThanOrEqualTo(9 * 60));
      expect(endMinute, lessThanOrEqualTo(12 * 60));
    });

    // 这条用例的断言被**刻意改过一次**（1.7.1），理由如下，不是为了让它变绿：
    //
    // 旧断言是"没有偏好时开始时间 < 09:00"，注释写"落在当天最早的可排位置"。
    // 它当时确实通过——但那是因为 `AvailabilityBuilder` 会把每日上限当成"最多保留多少分钟
    // 候选"从清晨开始消费，于是候选只到约 08:00，引擎**别无选择**。
    //
    // 1.7.1 删除了那个截断（计划 §2.4 / Task 2），候选延伸全天，于是这条用例暴露出它测的
    // 并不是它声称的东西：默认精力窗口是 09:00–12:00 高、14:00–17:00 中，而 60 分钟任务的
    // 精力判定取**中点**，因此起点 13:30（中点 14:00）拿到最高的 +600 精力匹配分
    // （13:00 被默认午餐保护挡掉）。实测得分 1600。
    //
    // 这**符合设计**：计划 §3.2 明确写"若下午足以完成当天预算，算法可以优先下午；
    // 若下午不足，必须使用上午补足"。旧断言"必须在 09:00 之前"与这条设计相矛盾。
    //
    // 因此改成断言**这条用例真正要证明的东西**：去掉偏好之后，任务不再被拉进 09:00–12:00，
    // 而是按精力窗口落在更晚的位置。与上一条用例形成对照。
    test('没有期望时段时不被拉进刻意时段，而是按精力窗口落到更晚的位置', () {
      final engine = DeterministicScheduleEngine(_zones);
      final withPreference = engine
          .generate(problemWith(_morning))
          .blocks
          .single;
      final withoutPreference = engine
          .generate(problemWith(null))
          .blocks
          .single;

      int startMinute(DateTime utc) => utc.hour * 60 + utc.minute;

      expect(
        startMinute(withoutPreference.startUtc),
        greaterThan(startMinute(withPreference.startUtc)),
        reason:
            '期望时段把任务拉进 09:00–12:00；没有它时任务会落到精力窗口内的更晚位置'
            '（实测 ${startMinute(withoutPreference.startUtc) ~/ 60}:'
            '${startMinute(withoutPreference.startUtc) % 60}）',
      );
    });
  });
}
