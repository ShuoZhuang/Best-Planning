// R3/FR-CAL-03：日视图。
//
// 与周视图共用同一个 `ScheduleViewSource`，差别是**按本机时区显示时刻**——周视图的卡片
// 只给类型与标题。因此这里最要紧的断言不是"渲染了几个卡片"，而是"时刻按给定时区换算"，
// 以及"类型不只靠颜色区分"（需求 §12）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/calendar/day_view/day_view_page.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';

/// 只返回落在窗口内的条目：真实数据源就是这么做的，而日视图的正确性依赖"窗口=一天"。
final class _Items implements ScheduleViewSource {
  _Items(this.items);
  final List<ScheduleViewItem> items;

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) async* {
    final window = TimeRange(startUtc: startUtc, endUtc: endUtc);
    yield items.where((item) => item.range.overlaps(window)).toList();
  }
}

ScheduleViewItem _item({
  required String id,
  required String title,
  required ScheduleItemKind kind,
  required int startHourUtc,
  int durationHours = 1,
}) => ScheduleViewItem(
  id: id,
  title: title,
  kind: kind,
  range: TimeRange(
    startUtc: DateTime.utc(2026, 10, 5, startHourUtc),
    endUtc: DateTime.utc(2026, 10, 5, startHourUtc + durationHours),
  ),
);

final _dayStartUtc = DateTime.utc(2026, 10, 5);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<ScheduleViewItem> items,
    String timeZoneId = 'UTC',
  }) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DayViewPage(
            source: _Items(items),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: timeZoneId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('按给定时区显示时刻与类型，类型不只靠颜色区分', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed-1',
          title: '数据结构课',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
        _item(
          id: 'task-1',
          title: '写方案',
          kind: ScheduleItemKind.task,
          startHourUtc: 14,
        ),
      ],
    );

    expect(find.textContaining('09:00–10:00'), findsOneWidget);
    expect(find.textContaining('14:00–15:00'), findsOneWidget);
    // 类型以文字给出，而不是只靠卡片底色。
    expect(find.textContaining('固定日程'), findsOneWidget);
    expect(find.textContaining('任务'), findsOneWidget);
    expect(find.text('写方案'), findsOneWidget);
  });

  testWidgets('换一个时区，同一批 UTC 条目显示为不同时刻', (tester) async {
    final items = [
      _item(
        id: 'fixed-1',
        title: '数据结构课',
        kind: ScheduleItemKind.fixed,
        startHourUtc: 9,
      ),
    ];

    // 东八区：09:00Z 是当地 17:00。用 UTC 做断言就抓不到"忘记换算"这个错误。
    await pump(tester, items: items, timeZoneId: 'Asia/Shanghai');

    expect(find.textContaining('17:00–18:00'), findsOneWidget);
    expect(find.textContaining('09:00–10:00'), findsNothing);
  });

  testWidgets('这一天没有安排时说明"空"是什么意思', (tester) async {
    await pump(tester, items: const []);

    expect(find.text('这一天没有固定日程、保护时间或已确认的计划块。'), findsOneWidget);
  });

  testWidgets('从周视图可以切到日视图', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(timeZoneId: 'Asia/Shanghai', 
          settingsRepository: settings,
          scheduleSource: _Items(const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    expect(find.text('七日日历'), findsOneWidget);

    final openDay = find.byKey(const Key('open-day-view'));
    expect(openDay, findsOneWidget);
    await tester.ensureVisible(openDay);
    await tester.tap(openDay);
    await tester.pumpAndSettle();

    // 日视图与周视图互为切换，因此两者都可达且不占导航项。
    expect(find.byType(DayViewPage), findsOneWidget);
    expect(find.byKey(const Key('open-week-view')), findsOneWidget);
  });
}
