// Task 9（课程与保护时间管理修复计划 §2.4）：**保护窗口重叠检测**。
//
// 计划原文："早餐与睡眠、午餐或其它保护窗口重叠时**必须在保存前指出具体重叠区间**；
// 不能静默合并或重复计算保护分钟。"
//
// 这里是纯函数测试：把"哪些组合重叠、重叠多少分钟"逐条钉住，
// 而不必启动界面。跨午夜（睡眠 23:30–08:00）是最容易算错的一种。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/protected_time_overlap.dart';
import 'package:personal_planner/domain/models/time_range.dart';

void main() {
  LocalTimeRange range(String from, String to) =>
      LocalTimeRange(startMinute: _minutes(from), endMinute: _minutes(to));

  ProtectedTimeRule rule(ProtectedTimeKind kind, String from, String to) =>
      ProtectedTimeRule(kind: kind, range: range(from, to));

  test('**早餐 07:30–08:00 与睡眠 23:30–08:00 重叠 30 分钟**（计划原句）', () {
    final overlaps = findProtectedTimeOverlaps(
      kind: ProtectedTimeKind.breakfast,
      range: range('07:30', '08:00'),
      protectedTimes: const [],
      sleepRange: range('23:30', '08:00'),
    );

    expect(overlaps, hasLength(1));
    expect(overlaps.single.otherKind, 'sleep');
    expect(
      overlaps.single.overlapMinutes,
      30,
      reason: '睡眠到 08:00、早餐从 07:30 开始 ⇒ 重叠 07:30–08:00 这半小时',
    );
    expect(
      overlaps.single.describe(),
      '早餐保护 07:30–08:00 与睡眠 23:30–08:00 重叠 30 分钟',
      reason: '用户要看到的是**具体区间与分钟数**，而不是一句"时间冲突"',
    );
  });

  test('早餐与睡眠完全不重叠时不报', () {
    final overlaps = findProtectedTimeOverlaps(
      kind: ProtectedTimeKind.breakfast,
      range: range('07:30', '08:00'),
      protectedTimes: const [],
      sleepRange: range('23:30', '07:00'),
    );

    expect(overlaps, isEmpty, reason: '睡眠 07:00 结束、早餐 07:30 开始 ⇒ 不重叠');
  });

  test('**首尾相接不算重叠**（半开区间）', () {
    final overlaps = findProtectedTimeOverlaps(
      kind: ProtectedTimeKind.breakfast,
      range: range('07:30', '08:00'),
      protectedTimes: const [],
      sleepRange: range('23:30', '07:30'),
    );

    expect(
      overlaps,
      isEmpty,
      reason:
          '睡眠 07:30 结束、早餐 07:30 开始，两个区间**首尾相接**。'
          '把它算重叠会让"刚好接上"这种最常见的排法无法保存',
    );
  });

  test('早餐与午餐重叠时也报（不只是睡眠）', () {
    final overlaps = findProtectedTimeOverlaps(
      kind: ProtectedTimeKind.breakfast,
      range: range('07:30', '12:30'),
      protectedTimes: [rule(ProtectedTimeKind.lunch, '12:00', '13:00')],
      sleepRange: range('23:30', '07:00'),
    );

    expect(overlaps, hasLength(1));
    expect(overlaps.single.otherKind, 'lunch');
    expect(overlaps.single.overlapMinutes, 30);
  });

  test('早餐与午餐**首尾相接**不算重叠', () {
    final overlaps = findProtectedTimeOverlaps(
      kind: ProtectedTimeKind.breakfast,
      range: range('07:30', '12:00'),
      protectedTimes: [rule(ProtectedTimeKind.lunch, '12:00', '13:00')],
      sleepRange: null,
    );

    expect(overlaps, isEmpty);
  });

  test('早餐与午餐首尾相接不算重叠：一侧跨午夜时仍然成立', () {
    // 固定休息 23:00–07:30 跨午夜；早餐 07:30–08:00 与它首尾相接。
    final overlaps = findProtectedTimeOverlaps(
      kind: ProtectedTimeKind.breakfast,
      range: range('07:30', '08:00'),
      protectedTimes: [rule(ProtectedTimeKind.fixedRest, '23:00', '07:30')],
      sleepRange: null,
    );

    expect(overlaps, isEmpty, reason: '跨午夜区间的另一侧端点必须被正确展开，否则"接上"会被误判成重叠');
  });

  test('**早餐完全落在睡眠内部** ⇒ 重叠等于早餐全长', () {
    final overlaps = findProtectedTimeOverlaps(
      kind: ProtectedTimeKind.breakfast,
      range: range('07:00', '07:30'),
      protectedTimes: const [],
      sleepRange: range('23:00', '08:00'),
    );

    expect(overlaps.single.overlapMinutes, 30);
  });

  test('未启用的保护窗口不参与重叠判定', () {
    final overlaps = findProtectedTimeOverlaps(
      kind: ProtectedTimeKind.breakfast,
      range: range('11:30', '12:30'),
      protectedTimes: [
        ProtectedTimeRule(
          kind: ProtectedTimeKind.lunch,
          range: range('12:00', '13:00'),
          enabled: false,
        ),
      ],
      sleepRange: null,
    );

    expect(overlaps, isEmpty, reason: '关掉的规则不占时间，把它算成冲突会让用户无法保存');
  });

  test('有多处重叠时全部报出来（不只第一条）', () {
    final overlaps = findProtectedTimeOverlaps(
      kind: ProtectedTimeKind.breakfast,
      range: range('07:30', '13:00'),
      protectedTimes: [
        rule(ProtectedTimeKind.lunch, '12:00', '13:00'),
        rule(ProtectedTimeKind.dinner, '12:30', '13:30'),
      ],
      sleepRange: range('23:30', '08:00'),
    );

    expect(overlaps.map((o) => o.otherKind).toSet(), {
      'sleep',
      'lunch',
      'dinner',
    }, reason: '只报第一条会让用户改完一条、再保存又发现另一条');
  });

  test('`dayKind` 不同时不比较（工作日睡眠与周末早餐互不影响）', () {
    final overlaps = findProtectedTimeOverlaps(
      kind: ProtectedTimeKind.breakfast,
      range: range('07:30', '08:00'),
      protectedTimes: [
        ProtectedTimeRule(
          kind: ProtectedTimeKind.lunch,
          range: range('07:45', '08:15'),
          dayKind: DayKind.weekend,
        ),
      ],
      sleepRange: null,
      dayKind: DayKind.weekday,
    );

    expect(overlaps, isEmpty, reason: '工作日与周末是两套日程，互相之间不该报冲突');
  });
}

int _minutes(String hhmm) {
  final parts = hhmm.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}
