// 计划 Task 2 —— 时间轴**只做一次**时区转换。
//
// 修复前的缺陷（设计规范 §2.1）：`TimelineDayColumn` 先把 UTC 转成本地分钟算出位置，
// 随后又把这个"本地分钟"包装成 `DateTime.utc` 调一次 `_local` 去格式化文字。Asia/Shanghai
// 下文字因此再偏 8 小时。此前的 `week_timeline_test.dart` 注入的是**恒等转换**
// （`toLocal: (value) => value`），所以真实时区下的二次转换从来没被覆盖。
//
// 本文件**一律使用真实 IANA 时区与真实 `TimeZoneDatabase`**，注入恒等函数就等于把这条
// 缺陷重新藏起来。断言覆盖四处必须一致的值：位置、卡片文字、悬浮提示、无障碍语义
// （规范 §4.2：位置与文字一致）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_timeline_plan.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/timeline_layout.dart';
import 'package:personal_planner/features/calendar/week_view/week_view_page.dart';

import '../../fixtures/core_workflow_repair_scenarios.dart';

/// 与 `week_view_page.dart` 的私有常量保持一致：每像素 48/60 分钟。
const double _pixelsPerMinute = 48 / 60;

/// 与 `week_view_page.dart` 的私有常量保持一致：极短块的最小高度。
const double _minimumBlockHeight = 18;

final class _Source implements ScheduleViewSource {
  const _Source(this.items);
  final List<ScheduleViewItem> items;

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      Stream.value(items);
}

ScheduleViewItem _item(
  String id,
  String title, {
  required DateTime startUtc,
  required DateTime endUtc,
}) => ScheduleViewItem(
  id: id,
  title: title,
  kind: ScheduleItemKind.fixed,
  categoryKey: 'special:unassignedFixed',
  categoryLabel: '未归属',
  categoryColorArgb: 0xff2f86ff,
  categorySortOrder: 0,
  range: TimeRange(startUtc: startUtc, endUtc: endUtc),
);

final class _TimelineHarness {
  static Future<void> pump(
    WidgetTester tester, {
    required List<ScheduleViewItem> items,
    required DateTime weekStartUtc,
    required DateTime Function(DateTime) toLocal,
    ValueChanged<ScheduleViewItem>? onOpenItem,
    Size size = const Size(1600, 1000),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeekViewPage(
            source: _Source(items),
            weekStart: weekStartUtc,
            moveController: const DisabledWeekMoveController(),
            toLocal: toLocal,
            onOpenItem: onOpenItem,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
    await tester.pumpAndSettle();
  }
}

/// 用与页面同一份纯函数算出时间轴的分列计划。
///
/// 刻意**不**在测试里重写一遍窗口计算：那样只是把实现抄第二遍，页面改错了测试也可能
/// 跟着错。这里要求的是"页面渲染出的几何 == 纯函数算出的几何"。
WeeklyTimelinePlan _planFor({
  required List<ScheduleViewItem> items,
  required DateTime weekStartUtc,
  required DateTime Function(DateTime) toLocal,
}) {
  final weekStartLocal = toLocal(weekStartUtc);
  return weeklyTimelinePlan(
    items: items,
    days: [
      for (var index = -1; index < 7; index++)
        DateTime(
          weekStartLocal.year,
          weekStartLocal.month,
          weekStartLocal.day + index,
        ),
    ],
    toLocal: toLocal,
  );
}

({
  int startMinute,
  int endMinute,
  double top,
  double height,
  int windowStartMinute,
  int windowEndMinute,
})
_expectedTop({
  required ScheduleViewItem item,
  required DateTime weekStartUtc,
  required DateTime Function(DateTime) toLocal,
}) {
  final plan = _planFor(
    items: [item],
    weekStartUtc: weekStartUtc,
    toLocal: toLocal,
  );
  final window = timelineWindowFor(plan.ranges);
  final metrics = TimelineMetrics(
    windowStartMinute: window.start,
    windowEndMinute: window.end,
    pixelsPerMinute: _pixelsPerMinute,
    minimumBlockHeight: _minimumBlockHeight,
  );
  final entry = plan.days
      .expand((day) => day.entries)
      .firstWhere((entry) => entry.item.id == item.id);
  return (
    startMinute: entry.startMinute,
    endMinute: entry.endMinute,
    top: metrics.topFor(entry.startMinute),
    height: metrics.heightFor(entry.endMinute - entry.startMinute),
    windowStartMinute: window.start,
    windowEndMinute: window.end,
  );
}

void main() {
  final scenarios = CoreWorkflowRepairScenarios();
  final zones = scenarios.zones;

  group('上海时区：位置与文字来自同一个本地分钟', () {
    testWidgets('UTC 04:00–05:00 的卡片在 12 点，且四处文字都是 12:00–13:00', (
      tester,
    ) async {
      final lunch = scenarios.shanghaiLunch();
      await _TimelineHarness.pump(
        tester,
        items: [
          _item('lunch', '午餐', startUtc: lunch.startUtc, endUtc: lunch.endUtc),
        ],
        weekStartUtc: lunch.startUtc,
        toLocal: (instant) => zones.toLocal(instant, RepairZones.shanghai),
      );

      // ── 位置：12:00 也就是本地分钟 720。
      //
      // 期望值不是猜的数字：先用与页面**同一份**纯函数（[weeklyTimelinePlan] +
      // [timelineWindowFor] + [TimelineMetrics]）把 12:00 应当落在哪算出来，再要求
      // 渲染出来的 `Positioned.top` 与之相等。这样断言的是"页面真的按单一时间源排版"，
      // 而不是把某一个像素值写死在测试里。
      final expected = _expectedTop(
        item: _item(
          'lunch',
          '午餐',
          startUtc: lunch.startUtc,
          endUtc: lunch.endUtc,
        ),
        weekStartUtc: lunch.startUtc,
        toLocal: (instant) => zones.toLocal(instant, RepairZones.shanghai),
      );
      expect(
        expected.startMinute,
        12 * 60,
        reason: '纯函数层必须先给出 720；它若不对，页面断言就没有意义',
      );

      final positioned = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('week-timeline-card-lunch')),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(
        positioned.top,
        closeTo(expected.top, 0.01),
        reason:
            '位置必须与本地分钟一致。修复前文字偏 8 小时，位置却是对的——因此'
            '"位置对"本身不足以证明混合来源已经消除，这条与下面的文字断言必须同时成立',
      );
      expect(
        positioned.height,
        closeTo(expected.height - 1, 0.01),
        reason: '高度按真实时长成比例；-1 是页面刻意留的 1 像素缝',
      );

      // ── 卡片文字
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('week-timeline-range-lunch')),
            )
            .data,
        '12:00–13:00',
      );

      // ── 悬浮提示与卡片文字用同一个标签
      final tooltip = tester.widget<Tooltip>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('week-timeline-title-lunch')),
              matching: find.byType(Tooltip),
            )
            .first,
      );
      expect(tooltip.message, '午餐\n12:00–13:00');

      // ── 无障碍语义。**不注入 onOpenItem 时卡片外层没有 Semantics**
      //    （`_TimelineCard` 只在可点时包一层），因此这里单独渲染一次带回调的卡片，
      //    并显式开启语义树——否则 `getSemantics` 拿到的是空标签，看起来像"语义没接上"。
      final handle = tester.ensureSemantics();
      await _TimelineHarness.pump(
        tester,
        items: [
          _item('lunch', '午餐', startUtc: lunch.startUtc, endUtc: lunch.endUtc),
        ],
        weekStartUtc: lunch.startUtc,
        toLocal: (instant) => zones.toLocal(instant, RepairZones.shanghai),
        onOpenItem: (_) {},
      );
      // 语义标签以"标题，起止"开头——工具提示那两行会被合并进同一节点，因此用前缀断言。
      // 关键是那串时间：它必须来自与位置同一个本地分钟区间。
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('week-timeline-card-lunch')),
            )
            .label,
        startsWith('午餐，12:00–13:00'),
      );
      handle.dispose();
    });

    testWidgets('紧凑模式与时间轴显示同一时间（12:00–13:00）', (tester) async {
      final lunch = scenarios.shanghaiLunch();
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekViewPage(
              source: _Source([
                _item(
                  'lunch',
                  '午餐',
                  startUtc: lunch.startUtc,
                  endUtc: lunch.endUtc,
                ),
              ]),
              weekStart: lunch.startUtc,
              moveController: const DisabledWeekMoveController(),
              toLocal: (instant) =>
                  zones.toLocal(instant, RepairZones.shanghai),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 紧凑模式：卡片上的区间文字。
      expect(
        find.text('12:00–13:00'),
        findsWidgets,
        reason: '紧凑模式本来就用真实时区换算，它是对的；时间轴必须与它一致',
      );

      await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('week-timeline-range-lunch')),
            )
            .data,
        '12:00–13:00',
      );
    });
  });

  group('跨午夜：23:30–00:30 分成两段，各落在自己那一天', () {
    testWidgets('两段的文字分别是 23:30–24:00 与 00:00–00:30', (tester) async {
      final segments = scenarios.shanghaiCrossMidnight();
      final first = segments.first;
      final second = segments.last;

      DateTime toLocal(DateTime instant) =>
          zones.toLocal(instant, RepairZones.shanghai);
      final item = _item(
        'overnight',
        '清扫',
        startUtc: first.startUtc,
        endUtc: second.endUtc,
      );

      // ── 第一层：纯函数把跨午夜的一段切成了两段，且**各自的区间值正确**。
      //
      // 跨午夜的卡片只有 30 分钟高，`_TimelineCard` 会按"空间不够就让位给标题"
      // （§9 的既有行为）隐藏区间文字。因此这里先钉住**显示源**的值，再钉渲染层
      // 确实按那份值把两段分开画。
      final plan = _planFor(
        items: [item],
        weekStartUtc: first.startUtc,
        toLocal: toLocal,
      );
      final splitEntries = plan.days
          .expand((day) => day.entries)
          .where((entry) => entry.item.id == 'overnight')
          .toList();
      expect(splitEntries, hasLength(2), reason: '跨午夜必须切成两段，各落在自己那一天');
      // `plan.days` 的顺序是昨天、今天、…，跨午夜的两段分别在今天与明天。
      final todayIndex = plan.days.indexWhere((day) => day.index == 0);
      expect(
        plan.days[todayIndex].entries.single.label,
        '23:30–24:00',
        reason: '区间终点必须显示成 24:00，不能回绕成 00:00——那会丢掉"跨日"的含义',
      );
      expect(plan.days[todayIndex + 1].entries.single.label, '00:00–00:30');

      // ── 第二层：渲染出来确实是两张卡片，且各自的悬浮提示带着自己那一段的时间。
      await _TimelineHarness.pump(
        tester,
        items: [item],
        weekStartUtc: first.startUtc,
        toLocal: toLocal,
      );
      expect(
        find.byKey(const ValueKey('week-timeline-card-overnight')),
        findsNWidgets(2),
        reason: '两段各画一张卡片；只画一张就是没有按本地日切片',
      );
      final tooltips = tester
          .widgetList<Tooltip>(
            find.ancestor(
              of: find.byKey(const ValueKey('week-timeline-title-overnight')),
              matching: find.byType(Tooltip),
            ),
          )
          .map((tooltip) => tooltip.message)
          .toList();
      expect(tooltips, contains('清扫\n23:30–24:00'));
      expect(tooltips, contains('清扫\n00:00–00:30'));
    });
  });

  group('Europe/Berlin 夏令时切换日', () {
    testWidgets('切换日 03:00–04:00 显示为 03:00–04:00（不是 UTC 的 01:00）', (
      tester,
    ) async {
      final scenario = scenarios.berlinSpringForward();
      await _TimelineHarness.pump(
        tester,
        items: [
          _item(
            'dst',
            '课程',
            startUtc: scenario.startUtc,
            endUtc: scenario.endUtc,
          ),
        ],
        weekStartUtc: scenario.startUtc,
        toLocal: (instant) => zones.toLocal(instant, RepairZones.berlin),
      );

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('week-timeline-range-dst')))
            .data,
        '03:00–04:00',
      );
    });

    testWidgets('切换日的 01:00–03:00 本地时长是 60 分钟，与次日 01:00–03:00 的 120 分钟不同', (
      tester,
    ) async {
      final switchLocalDate = DateTime(2026, 3, 29);
      final normalLocalDate = DateTime(2026, 3, 30);

      DateTime at(DateTime localDate, int minute) =>
          zones.localDateTimeToUtc(localDate, minute, RepairZones.berlin);

      await _TimelineHarness.pump(
        tester,
        items: [
          _item(
            'switch',
            '切换日',
            startUtc: at(switchLocalDate, 60),
            endUtc: at(switchLocalDate, 180),
          ),
          _item(
            'normal',
            '次日',
            startUtc: at(normalLocalDate, 60),
            endUtc: at(normalLocalDate, 180),
          ),
        ],
        weekStartUtc: at(switchLocalDate, 0),
        toLocal: (instant) => zones.toLocal(instant, RepairZones.berlin),
      );

      // 两段的**文字**都是 01:00–03:00：本地钟点由各自那一天的墙上时间决定。
      final switchRange = tester.widget<Text>(
        find.byKey(const ValueKey('week-timeline-range-switch')),
      );
      final normalRange = tester.widget<Text>(
        find.byKey(const ValueKey('week-timeline-range-normal')),
      );
      expect(switchRange.data, '01:00–03:00');
      expect(normalRange.data, '01:00–03:00');

      // 而**高度**必须差一倍：位置与文字共用同一个本地分钟区间，本地分钟区间反映的是
      // 墙上时间的跨度，因此这里两者都是 120 分钟——真正不同的是它们对应的 UTC 时长。
      // 用 UTC 时长证明夹具确实跨过了切换点，否则这条用例什么都没测。
      expect(
        at(normalLocalDate, 180).difference(at(normalLocalDate, 60)).inMinutes,
        120,
      );
      expect(
        at(switchLocalDate, 180).difference(at(switchLocalDate, 60)).inMinutes,
        60,
        reason: '2026-03-29 02:00 本地时间柏林跳时，01:00–03:00 实际只有 60 分钟',
      );
    });
  });
}
