// 1.11.0（计划 Task 4 Step 1）：延后量、目标日粒度与 DST 解析。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/defer_time_policy.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';

void main() {
  final zones = TimeZoneDatabase();
  final policy = DeferTimePolicy(zones);
  const shanghai = 'Asia/Shanghai';

  int grid5(DateTime _) => 5;

  group('范围', () {
    test('分钟 1–240，0 与非正数被拒绝', () {
      expect(policy.validateAmount(0, DeferUnit.minutes).isValid, isFalse);
      expect(
        policy.validateAmount(0, DeferUnit.minutes).reasonCode,
        'amountNotPositive',
      );
      expect(policy.validateAmount(-5, DeferUnit.hours).isValid, isFalse);
      expect(policy.validateAmount(1, DeferUnit.minutes).isValid, isTrue);
      expect(policy.validateAmount(240, DeferUnit.minutes).isValid, isTrue);
      expect(policy.validateAmount(241, DeferUnit.minutes).isValid, isFalse);
      expect(
        policy.validateAmount(241, DeferUnit.minutes).reasonCode,
        'amountOutOfRange',
      );
    });

    test('小时 1–72，73 被拒绝', () {
      expect(policy.validateAmount(1, DeferUnit.hours).isValid, isTrue);
      expect(policy.validateAmount(72, DeferUnit.hours).isValid, isTrue);
      expect(policy.validateAmount(73, DeferUnit.hours).isValid, isFalse);
    });

    test('天 1–7，8 天属于改任务时间范围并给出专门原因', () {
      expect(policy.validateAmount(1, DeferUnit.days).isValid, isTrue);
      expect(policy.validateAmount(7, DeferUnit.days).isValid, isTrue);
      final eight = policy.validateAmount(8, DeferUnit.days);
      expect(eight.isValid, isFalse);
      expect(eight.reasonCode, 'longerThanOneWeek');
    });

    test('非法延后量在计算下界时抛 ArgumentError，不静默取整', () async {
      await expectLater(
        policy.computeNotBefore(
          sourceStartUtc: DateTime.utc(2026, 10, 19, 2),
          amount: 0,
          unit: DeferUnit.minutes,
          timeZoneId: shanghai,
          granularityForDate: grid5,
        ),
        throwsArgumentError,
      );
      await expectLater(
        policy.computeNotBefore(
          sourceStartUtc: DateTime.utc(2026, 10, 19, 2),
          amount: 8,
          unit: DeferUnit.days,
          timeZoneId: shanghai,
          granularityForDate: grid5,
        ),
        throwsArgumentError,
      );
    });
  });

  group('分钟与小时', () {
    test('自定义 7 分钟在 5 分钟粒度下向上为 10 分钟', () async {
      // 本地 10:00（= 02:00Z）加 7 分钟 = 10:07，向上吸附到 10:10。
      final result = await policy.computeNotBefore(
        sourceStartUtc: DateTime.utc(2026, 10, 19, 2),
        amount: 7,
        unit: DeferUnit.minutes,
        timeZoneId: shanghai,
        granularityForDate: grid5,
      );

      expect(result, DateTime.utc(2026, 10, 19, 2, 10));
    });

    test('小时按绝对经过时长计算，落在网格上时不被多推', () async {
      final result = await policy.computeNotBefore(
        sourceStartUtc: DateTime.utc(2026, 10, 19, 2),
        amount: 2,
        unit: DeferUnit.hours,
        timeZoneId: shanghai,
        granularityForDate: grid5,
      );

      expect(result, DateTime.utc(2026, 10, 19, 4));
    });

    test('跨日时使用**目标日**的粒度，而不是源日粒度', () async {
      // 源日 10-19 的粒度是 5，目标日 10-20 的粒度是 10：
      // 本地 23:55 + 10 分钟 = 次日 00:05，必须吸附到次日 00:10。
      final result = await policy.computeNotBefore(
        sourceStartUtc: DateTime.utc(2026, 10, 19, 15, 55),
        amount: 10,
        unit: DeferUnit.minutes,
        timeZoneId: shanghai,
        granularityForDate: (date) => date.day == 20 ? 10 : 5,
      );

      expect(result, DateTime.utc(2026, 10, 19, 16, 10));
      final local = zones.toLocal(result, shanghai);
      expect((local.hour, local.minute), (0, 10));
    });
  });

  group('天', () {
    test('保持本地钟面，而不是固定加 24 小时', () async {
      final result = await policy.computeNotBefore(
        sourceStartUtc: DateTime.utc(2026, 10, 19, 2),
        amount: 1,
        unit: DeferUnit.days,
        timeZoneId: shanghai,
        granularityForDate: grid5,
      );

      expect(result, DateTime.utc(2026, 10, 20, 2));
      expect(zones.toLocal(result, shanghai).hour, 10);
    });

    test('柏林夏令时切换日：本地钟点不变，UTC 只前进 23 小时', () async {
      // 2026-03-28 本地 03:00 CET = 02:00Z；次日切换，03:00 CEST = 01:00Z。
      final result = await policy.computeNotBefore(
        sourceStartUtc: DateTime.utc(2026, 3, 28, 2),
        amount: 1,
        unit: DeferUnit.days,
        timeZoneId: 'Europe/Berlin',
        granularityForDate: (_) => 1,
      );

      expect(result, DateTime.utc(2026, 3, 29, 1));
      expect(
        result.difference(DateTime.utc(2026, 3, 28, 2)).inHours,
        23,
      );
    });

    test('纽约春季前跳：缺失的 02:30 推进到第一个有效本地时刻 03:00', () async {
      // 2026-03-07 本地 02:30 EST = 07:30Z；+1 天后 03-08 02:30 不存在。
      final result = await policy.computeNotBefore(
        sourceStartUtc: DateTime.utc(2026, 3, 7, 7, 30),
        amount: 1,
        unit: DeferUnit.days,
        timeZoneId: 'America/New_York',
        granularityForDate: (_) => 1,
      );

      final local = zones.toLocal(result, 'America/New_York');
      expect((local.hour, local.minute), (3, 0));
      expect(result, DateTime.utc(2026, 3, 8, 7));
    });

    test('纽约秋季回拨：重复的 01:30 选择较早实例', () async {
      final result = await policy.computeNotBefore(
        sourceStartUtc: DateTime.utc(2026, 10, 31, 5, 30),
        amount: 1,
        unit: DeferUnit.days,
        timeZoneId: 'America/New_York',
        granularityForDate: (_) => 1,
      );

      expect(result, DateTime.utc(2026, 11, 1, 5, 30));
      final local = zones.toLocal(result, 'America/New_York');
      expect((local.hour, local.minute), (1, 30));
      expect(local.timeZoneOffset, const Duration(hours: -4));
    });
  });

  group('窗口', () {
    test('调整窗口至少覆盖目标下界之后的完整本地日', () {
      final notBefore = DateTime.utc(2026, 10, 19, 2);
      // 默认窗口在 10-19 就结束：延后必须把它扩到目标下界之后的完整本地日。
      final defaultEnd = DateTime.utc(2026, 10, 19, 12);

      final end = policy.adjustmentWindowEnd(
        notBeforeUtc: notBefore,
        defaultWindowEnd: defaultEnd,
        timeZoneId: shanghai,
      );

      // 下界本地日 10-19 → 完整覆盖 10-20 到 10-21 本地零点 = 10-20 16:00Z。
      expect(end, DateTime.utc(2026, 10, 20, 16));
    });

    test('默认窗口更大时保留默认窗口', () {
      final end = policy.adjustmentWindowEnd(
        notBeforeUtc: DateTime.utc(2026, 10, 19, 2),
        defaultWindowEnd: DateTime.utc(2026, 11, 30),
        timeZoneId: shanghai,
      );

      expect(end, DateTime.utc(2026, 11, 30));
    });

    test('目标本地日期按传入时区计算', () async {
      final date = await policy.targetLocalDate(
        sourceStartUtc: DateTime.utc(2026, 10, 19, 20),
        amount: 1,
        unit: DeferUnit.days,
        timeZoneId: shanghai,
      );

      // 20:00Z = 本地 10-20 04:00；+1 天 = 10-21。
      expect(date, DateTime(2026, 10, 21));
    });
  });
}

