// 容量感知的按日均分器（1.7.1 计划 §3.1 / Task 3 Step 1）。
//
// 计划要求至少覆盖：210 分给四天得到两个 55 与两个 50；180 分给七天总和精确且极差 ≤ 5；
// 某天容量为 0 时只在其他日期重分；某天容量 25、其余充足时先用 25 再均分剩余；总容量 120 时
// `allocatableMinutes == 120` 且 `shortageMinutes == target - 120`；已锁定 30 分钟计入
// `finalMinutesByLocalDate` 而 `additionalMinutesByLocalDate` 只含差额；输入 Map 顺序反转时
// 输出逐值相同；目标短于最小片段时沿用既有规则；DST 周／月末／年末日期键不合并错位。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/scheduling/even_distribution_allocator.dart';

DateTime _d(int month, int day) => DateTime(2026, month, day);

EvenDistributionPlan _allocate({
  required int target,
  required Map<DateTime, int> capacity,
  Map<DateTime, int> already = const {},
  int granularity = 5,
  int minChunk = 25,
}) => allocateEvenDistribution(
  EvenDistributionInput(
    targetMinutes: target,
    granularityMinutes: granularity,
    minChunkMinutes: minChunk,
    capacityMinutesByLocalDate: capacity,
    alreadyPlannedMinutesByLocalDate: already,
  ),
);

List<int> _sorted(List<int> values) => values.toList()..sort();

void main() {
  group('均分与余数', () {
    test('210 分钟分给四天 ⇒ 两个 55、两个 50', () {
      final plan = _allocate(
        target: 210,
        capacity: {for (var day = 8; day <= 11; day++) _d(10, day): 90},
      );

      expect(_sorted(plan.additionalMinutesByLocalDate.values.toList()), [
        50,
        50,
        55,
        55,
      ], reason: '210 ÷ 4 = 52.5，按 5 分钟粒度的最优组合');
      expect(plan.shortageMinutes, 0);
      expect(plan.allocatableMinutes, 210);
      expect(plan.finalMinutesByLocalDate.values.fold(0, (a, b) => a + b), 210);
    });

    test('180 分钟分给七天 ⇒ 总和精确且极差 ≤ 5', () {
      final plan = _allocate(
        target: 180,
        capacity: {for (var day = 5; day <= 11; day++) _d(10, day): 120},
      );

      final values = plan.additionalMinutesByLocalDate.values.toList();
      expect(values.fold(0, (a, b) => a + b), 180, reason: '不能丢分钟');
      expect(values.length, 7, reason: '七天都该参与');
      final sorted = _sorted(values);
      expect(
        sorted.last - sorted.first,
        lessThanOrEqualTo(5),
        reason: '极差不得超过一个粒度；实际 ${sorted.join("/")}',
      );
    });

    test('参与日期按本地日期升序，与输入顺序无关', () {
      final forward = _allocate(
        target: 100,
        capacity: {for (var day = 8; day <= 11; day++) _d(10, day): 60},
      );
      final reversed = _allocate(
        target: 100,
        capacity: {for (var day = 11; day >= 8; day--) _d(10, day): 60},
      );

      expect(
        reversed.additionalMinutesByLocalDate,
        forward.additionalMinutesByLocalDate,
        reason: 'Map 迭代顺序不得泄漏到结果里（排程要求相同输入相同输出）',
      );
      expect(forward.localDates, [
        _d(10, 8),
        _d(10, 9),
        _d(10, 10),
        _d(10, 11),
      ]);
    });
  });

  group('容量不足时只在有容量的日期之间重分', () {
    test('某天容量为 0 ⇒ 它不参与，也不被补偿', () {
      final plan = _allocate(
        target: 150,
        capacity: {_d(10, 8): 90, _d(10, 9): 0, _d(10, 10): 90, _d(10, 11): 90},
      );

      expect(
        plan.finalMinutesByLocalDate.containsKey(_d(10, 9)),
        isFalse,
        reason: '容量为 0 的日期不进入结果',
      );
      expect(
        plan.additionalMinutesByLocalDate.values.fold(0, (a, b) => a + b),
        150,
      );
      expect(_sorted(plan.additionalMinutesByLocalDate.values.toList()), [
        50,
        50,
        50,
      ], reason: '150 分给其余三天正好各 50');
    });

    test('某天容量 25、其余充足 ⇒ 先用光 25，再均分剩余', () {
      final plan = _allocate(
        target: 210,
        capacity: {
          _d(10, 8): 25,
          _d(10, 9): 200,
          _d(10, 10): 200,
          _d(10, 11): 200,
        },
      );

      expect(
        plan.additionalMinutesByLocalDate[_d(10, 8)],
        25,
        reason: '容量 25 的那天应用满，而不是被跳过',
      );
      expect(plan.shortageMinutes, 0, reason: '总容量足够，不得报容量不足');
      final others = [
        for (final entry in plan.additionalMinutesByLocalDate.entries)
          if (entry.key != _d(10, 8)) entry.value,
      ];
      expect(_sorted(others), [60, 60, 65], reason: '剩余 185 分给三天');
    });

    test('总容量只有 120 ⇒ allocatableMinutes=120 且缺口精确', () {
      final plan = _allocate(
        target: 180,
        capacity: {_d(10, 8): 60, _d(10, 9): 60},
      );

      expect(plan.allocatableMinutes, 120);
      expect(plan.shortageMinutes, 60, reason: '缺口必须等于"需要 − 可排"');
      expect(
        plan.additionalMinutesByLocalDate.values.fold(0, (a, b) => a + b),
        120,
        reason: '能排的部分要全部排掉，不能因为总容量不足就少排',
      );
    });
  });

  group('已锁定／已排分钟', () {
    test('已排 30 分钟计入 finalMinutes 且只要求差额', () {
      final plan = _allocate(
        target: 100,
        capacity: {_d(10, 8): 90, _d(10, 9): 90},
        already: {_d(10, 8): 30},
      );

      expect(
        plan.finalMinutesByLocalDate[_d(10, 8)],
        30 + plan.additionalMinutesByLocalDate[_d(10, 8)]!,
        reason: 'finalMinutes 是该日**最终**总量，含已排部分',
      );
      expect(
        plan.additionalMinutesByLocalDate.values.fold(0, (a, b) => a + b),
        100,
        reason: '目标 100 是"仍需安排"的量，与已排部分无关',
      );
    });

    test('已排分钟占用当日水位：已排 30 的那天不会再多拿一整份', () {
      final plan = _allocate(
        target: 60,
        capacity: {_d(10, 8): 30, _d(10, 9): 30},
        already: {_d(10, 8): 30},
      );

      expect(
        plan.additionalMinutesByLocalDate[_d(10, 8)],
        isNull,
        reason: '那天已被自己的 30 分钟占满，不该再拿',
      );
      expect(plan.additionalMinutesByLocalDate[_d(10, 9)], 30);
      expect(plan.shortageMinutes, 30, reason: '另一天只有 30 分钟容量');
    });
  });

  group('粒度与短余量', () {
    test('目标短于最小片段时照旧分配（不拒绝安排）', () {
      final plan = _allocate(
        target: 12,
        capacity: {_d(10, 8): 60},
        granularity: 5,
        minChunk: 30,
      );

      expect(
        plan.additionalMinutesByLocalDate.values.fold(0, (a, b) => a + b),
        12,
        reason: '余量本身就是最后一段，沿用路线图 Task 12A 的规则',
      );
      expect(plan.shortageMinutes, 0);
    });

    test('目标不是粒度整数倍时不丢分钟', () {
      final plan = _allocate(
        target: 103,
        capacity: {_d(10, 8): 60, _d(10, 9): 60},
        granularity: 5,
      );

      expect(
        plan.additionalMinutesByLocalDate.values.fold(0, (a, b) => a + b),
        103,
        reason:
            '总量必须精确；实际 '
            '${plan.additionalMinutesByLocalDate.values.toList()}',
      );
      expect(plan.shortageMinutes, 0);
    });
  });

  group('日期键的边界', () {
    test('DST 周（2026-03-08 美国切换）前后日期不被合并', () {
      // 用美国夏令时切换那天附近的日期做键：它们是**本地日期**，
      // 均分器只按 (年,月,日) 识别，不做时区换算，因此不该受 DST 影响。
      final plan = _allocate(
        target: 100,
        capacity: {
          DateTime(2026, 3, 7): 60,
          DateTime(2026, 3, 8): 60,
          DateTime(2026, 3, 9): 60,
        },
      );

      expect(plan.finalMinutesByLocalDate.keys, hasLength(3));
      expect(
        plan.additionalMinutesByLocalDate.values.fold(0, (a, b) => a + b),
        100,
      );
    });

    test('月末与年末日期不被错位合并', () {
      final plan = _allocate(
        target: 120,
        capacity: {
          DateTime(2026, 12, 30): 60,
          DateTime(2026, 12, 31): 60,
          DateTime(2027, 1, 1): 60,
          DateTime(2027, 1, 2): 60,
        },
      );

      expect(plan.finalMinutesByLocalDate.keys.toList()..sort(), [
        DateTime(2026, 12, 30),
        DateTime(2026, 12, 31),
        DateTime(2027, 1, 1),
        DateTime(2027, 1, 2),
      ], reason: '跨年时日期键必须逐日区分');
      expect(_sorted(plan.additionalMinutesByLocalDate.values.toList()), [
        30,
        30,
        30,
        30,
      ]);
    });

    test('带时间部分的日期键被归一化到当天', () {
      final plan = _allocate(
        target: 60,
        capacity: {DateTime(2026, 10, 8, 23, 59): 120},
      );

      expect(
        plan.finalMinutesByLocalDate.keys.single,
        DateTime(2026, 10, 8),
        reason: '键必须归一化，否则同一本地日会被拆成两个',
      );
    });
  });

  group('确定性', () {
    test('同一输入连跑二十次逐值相同', () {
      final capacity = {
        _d(10, 8): 90,
        _d(10, 9): 40,
        _d(10, 10): 70,
        _d(10, 11): 90,
      };
      final first = _allocate(target: 210, capacity: capacity);
      for (var run = 0; run < 20; run++) {
        final again = _allocate(target: 210, capacity: capacity);
        expect(
          again.additionalMinutesByLocalDate,
          first.additionalMinutesByLocalDate,
        );
        expect(again.shortageMinutes, first.shortageMinutes);
      }
    });

    test('没有日期或目标为 0 时结果为空且缺口如实', () {
      final none = _allocate(target: 60, capacity: const {});
      expect(none.additionalMinutesByLocalDate, isEmpty);
      expect(none.shortageMinutes, 60);

      final zero = _allocate(target: 0, capacity: {_d(10, 8): 60});
      expect(zero.additionalMinutesByLocalDate, isEmpty);
      expect(zero.shortageMinutes, 0);
    });
  });
}
