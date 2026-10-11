// 1.8.0（设计规范 §11.2／§11.3，计划 Task 11）：延后请求的类型化语义与生命周期。
//
// 修复前的缺陷（§2.5）：今日页把分钟换成 `RequestedMove.atInstant`，排程输入再把该块以
// `locked: true` 钉在**精确目标时刻**。目标点一旦被固定日程、保护时间或另一个锁定块占用，
// 方案直接失败——它不会去找目标之后最近的合法时段。而且一次失败还可能留下待处理内存意图。
//
// 本文件钉两件事：
// 1. 三种单位的 `notBeforeUtc` 计算（**天按本地日历日，不是加 24 小时**）；
// 2. 调整请求的四种结束路径都销毁它（规范 §11.3 最后一段）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_moves.dart';
import 'package:personal_planner/core/time_zone.dart';

void main() {
  final zones = TimeZoneDatabase();

  group('deferNotBeforeUtc', () {
    test('分钟与小时按经过时长计算', () {
      final start = DateTime.utc(2026, 10, 12, 4);

      expect(
        deferNotBeforeUtc(
          sourceStartUtc: start,
          amount: 30,
          unit: DeferUnit.minutes,
          timeZoneId: 'Asia/Shanghai',
          zones: zones,
        ),
        DateTime.utc(2026, 10, 12, 4, 30),
      );
      expect(
        deferNotBeforeUtc(
          sourceStartUtc: start,
          amount: 3,
          unit: DeferUnit.hours,
          timeZoneId: 'Asia/Shanghai',
          zones: zones,
        ),
        DateTime.utc(2026, 10, 12, 7),
      );
    });

    test('天按本地日历日并保留本地钟点', () {
      // 上海 12:00 的块延后 1 天 ⇒ 次日 12:00 本地，也就是 UTC 04:00。
      final start = DateTime.utc(2026, 10, 12, 4);

      expect(
        deferNotBeforeUtc(
          sourceStartUtc: start,
          amount: 1,
          unit: DeferUnit.days,
          timeZoneId: 'Asia/Shanghai',
          zones: zones,
        ),
        DateTime.utc(2026, 10, 13, 4),
      );
    });

    test('延后 1 天遇夏令时切换保持本地钟点，而不是加固定 24 小时（规范 §17 第 9 行）', () {
      // 柏林 2026-03-28 本地 03:00（CET +01:00）⇒ UTC 02:00。
      // 次日 2026-03-29 是切换日（02:00 本地跳到 03:00），本地 03:00 ⇒ UTC 01:00。
      // 因此**本地钟点不变、UTC 只前进 23 小时**。
      final beforeSwitch = DateTime.utc(2026, 3, 28, 2);

      final deferred = deferNotBeforeUtc(
        sourceStartUtc: beforeSwitch,
        amount: 1,
        unit: DeferUnit.days,
        timeZoneId: 'Europe/Berlin',
        zones: zones,
      );

      expect(deferred, DateTime.utc(2026, 3, 29, 1));
      expect(
        deferred.difference(beforeSwitch).inHours,
        23,
        reason: '加固定 24 小时会得到 03-29 02:00Z，而那一刻柏林已是本地 04:00——钟点漂了',
      );
      // 反过来说明"加 24 小时"确实是错的：
      expect(beforeSwitch.add(const Duration(days: 1)), isNot(deferred));
    });

    test('非正数被拒绝（提前是独立操作，不在本批次）', () {
      expect(
        () => deferNotBeforeUtc(
          sourceStartUtc: DateTime.utc(2026, 10, 12, 4),
          amount: 0,
          unit: DeferUnit.minutes,
          timeZoneId: 'Asia/Shanghai',
          zones: zones,
        ),
        throwsArgumentError,
      );
    });

    test('非 UTC 起点被拒绝', () {
      expect(
        () => deferNotBeforeUtc(
          sourceStartUtc: DateTime(2026, 10, 12, 4),
          amount: 30,
          unit: DeferUnit.minutes,
          timeZoneId: 'Asia/Shanghai',
          zones: zones,
        ),
        throwsArgumentError,
      );
    });
  });

  group('PlanAdjustmentRequest 的生命周期', () {
    PlanAdjustmentRequest request({String blockId = 'block-1'}) =>
        PlanAdjustmentRequest(
          blockId: blockId,
          amount: 30,
          unit: DeferUnit.minutes,
          sourceStartUtc: DateTime.utc(2026, 10, 12, 4),
          timeZoneId: 'Asia/Shanghai',
        );

    test('请求给出的是**下界**，不是精确点', () {
      final adjustment = request();

      expect(
        adjustment.notBeforeUtc(zones),
        DateTime.utc(2026, 10, 12, 4, 30),
        reason: '排程输入拿它当下界用；"必须正好落在这里"是 §2.5 的缺陷',
      );
    });

    test('开始调整后可按块取出下界', () {
      final drafts = PendingMoveDrafts()..beginAdjustment(request());

      expect(
        drafts.notBeforeForBlock('block-1', zones),
        DateTime.utc(2026, 10, 12, 4, 30),
      );
      expect(
        drafts.notBeforeForBlock('block-2', zones),
        isNull,
        reason: '调整只作用于它绑定的那一个块',
      );
    });

    test('开始调整会清掉同一块上残留的普通移动意图', () {
      // 用户先拖过一次（还没生成），又对同一块发起延后：后发起的那一个才算数。
      final drafts = PendingMoveDrafts()
        ..setRequestedMove(
          RequestedMove(
            blockId: 'block-1',
            localDate: DateTime(2026, 10, 15),
            lock: true,
          ),
        );

      drafts.beginAdjustment(request());

      expect(
        drafts.forBlock('block-1'),
        isNull,
        reason: '两种意图作用在同一块上时，后发起的那一个才算数',
      );
    });

    test('endAdjustment 之后下界消失，且不影响下一次生成（规范第 4 条不变量）', () {
      final drafts = PendingMoveDrafts()..beginAdjustment(request());

      drafts.endAdjustment();

      expect(drafts.adjustment, isNull);
      expect(
        drafts.notBeforeForBlock('block-1', zones),
        isNull,
        reason: '作废的调整绝不能被下一次普通"生成计划"再应用一遍',
      );
    });

    test('调整期间普通移动意图照常工作（两者互不干扰）', () {
      final drafts = PendingMoveDrafts()
        ..beginAdjustment(request(blockId: 'block-1'))
        ..setRequestedMove(
          RequestedMove(
            blockId: 'block-2',
            localDate: DateTime(2026, 10, 15),
            lock: true,
          ),
        );

      expect(drafts.forBlock('block-2'), isNotNull);
      expect(drafts.notBeforeForBlock('block-1', zones), isNotNull);
    });
  });
}
