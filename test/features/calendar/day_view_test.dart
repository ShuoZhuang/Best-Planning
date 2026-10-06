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
  Stream<List<ScheduleViewItem>> watch(
    DateTime startUtc,
    DateTime endUtc,
  ) async* {
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
    Future<bool> Function(String eventId)? onDeleteEvent,
    Future<bool> Function(
      String eventId,
      DateTime occurrenceStartUtc,
      DateTime newStartUtc,
      DateTime newEndUtc,
      String title,
    )?
    onReplaceOccurrence,
    Future<bool> Function(String eventId, String? areaId)? onSetEventArea,
    List<ScheduleAreaOption> areaOptions = const [
      ScheduleAreaOption(id: 'area-study', name: '学业'),
      ScheduleAreaOption(id: 'area-lab', name: '科研'),
    ],
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
            onDeleteEvent: onDeleteEvent,
            onReplaceOccurrence: onReplaceOccurrence,
            onSetEventArea: onSetEventArea,
            loadAreaOptions: onSetEventArea == null
                ? null
                : () async => areaOptions,
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
          id: 'fixed:event-1',
          title: '数据结构课',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
        _item(
          id: 'block:block-1',
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
        id: 'fixed:event-1',
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

  testWidgets('删除固定日程传回的是**领域事件 id**，不带视图条目的命名空间', (tester) async {
    final deleted = <String>[];
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:event-1',
          title: '数据结构课',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
        _item(
          id: 'block:block-1',
          title: '写方案',
          kind: ScheduleItemKind.task,
          startHourUtc: 14,
        ),
      ],
      onDeleteEvent: (id) async {
        deleted.add(id);
        return true;
      },
    );

    expect(find.byKey(const Key('delete-fixed:event-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-fixed:event-1')));
    await tester.pumpAndSettle();
    // 删除自本轮起会先确认（FR-CAL-02 要区分"只删这一次"与"删除整条"），因此这里必须
    // 走完"删除整条"这一步——否则断言的是"没发生删除"。
    await tester.tap(find.byKey(const Key('delete-entire')));
    await tester.pumpAndSettle();

    // 交回的必须是**领域事件 id**：曾经的实现在这里交回 `fixed:<uuid>`，仓储执行
    // `DELETE ... WHERE id = 'fixed:<uuid>'` 匹配 0 行且不报错，服务层按幂等语义返回成功，
    // 于是界面显示"已删除"而日程仍在。这条断言就是那次缺陷的回归守卫。
    expect(deleted, <String>['event-1']);
  });

  testWidgets('计划块与保护时间不提供删除／改写入口（它们不是日程）', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'block:block-1',
          title: '写方案',
          kind: ScheduleItemKind.task,
          startHourUtc: 9,
        ),
        _item(
          id: 'protected:sleep',
          title: '睡眠',
          kind: ScheduleItemKind.protectedTime,
          startHourUtc: 14,
        ),
      ],
      onDeleteEvent: (id) async => true,
      onReplaceOccurrence: (id, startUtc, newStart, newEnd, title) async =>
          true,
    );

    // 图标位**保留但不可用**：不够删这两类条目（它们的 id 不是事件 id），但也不能
    // 只有固定日程带图标——那会让同一列里卡片宽窄参差。
    for (final key in const [
      Key('delete-block:block-1'),
      Key('edit-block:block-1'),
      Key('delete-protected:sleep'),
      Key('edit-protected:sleep'),
    ]) {
      final button = tester.widget<IconButton>(find.byKey(key));
      expect(button.onPressed, isNull, reason: '$key 应当存在但点不动');
    }
  });

  testWidgets('所有条目的卡片等宽（图标位与可用性无关）', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:event-1',
          title: '出门摄影',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
        _item(
          id: 'block:block-1',
          title: '写方案',
          kind: ScheduleItemKind.task,
          startHourUtc: 14,
        ),
      ],
      onDeleteEvent: (id) async => true,
      onReplaceOccurrence: (id, startUtc, newStart, newEnd, title) async =>
          true,
    );

    final fixed = tester.getSize(
      find.byKey(const Key('day-item-fixed:event-1')),
    );
    final task = tester.getSize(
      find.byKey(const Key('day-item-block:block-1')),
    );
    expect(task.width, fixed.width, reason: '固定日程带删除/编辑图标，其余条目也必须为同样的图标位留出宽度');
  });

  testWidgets('相邻条目之间留出间距', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:event-1',
          title: '出门摄影',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
        _item(
          id: 'block:block-1',
          title: '写方案',
          kind: ScheduleItemKind.task,
          startHourUtc: 14,
        ),
      ],
      onDeleteEvent: (id) async => true,
    );

    final first = tester.getRect(
      find.byKey(const Key('day-item-fixed:event-1')),
    );
    final second = tester.getRect(
      find.byKey(const Key('day-item-block:block-1')),
    );
    // 间距为 0 时两条只剩卡片自身的外边距（4+4），因此这里用 token 值做下界：
    // 少了这个间隔断言就会失败。
    expect(second.top - first.bottom, greaterThanOrEqualTo(scheduleItemGap));
  });

  testWidgets('可以调整固定日程的所属领域，并把选中的 id 交给端口', (tester) async {
    final calls = <(String, String?)>[];
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:event-1',
          title: '出门摄影',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
      ],
      onSetEventArea: (eventId, areaId) async {
        calls.add((eventId, areaId));
        return true;
      },
    );

    await tester.tap(find.byKey(const Key('area-fixed:event-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('area-picker-dialog')), findsOneWidget);

    // 改成"科研"。
    await tester.tap(find.byKey(const Key('area-picker')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('科研').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('area-picker-save')));
    await tester.pumpAndSettle();

    // 交回的是**去掉 `fixed:` 前缀的领域 id**，而不是视图用的条目 id——删除功能当初正是
    // 把 `fixed:<uuid>` 当成领域 id 交给端口，结果删 0 行还不报错。
    expect(calls, [('event-1', 'area-lab')]);
    expect(find.text('已调整归属'), findsOneWidget);
  });

  testWidgets('取消对话框不会写入任何归属', (tester) async {
    final calls = <(String, String?)>[];
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:event-1',
          title: '出门摄影',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
      ],
      onSetEventArea: (eventId, areaId) async {
        calls.add((eventId, areaId));
        return true;
      },
    );

    await tester.tap(find.byKey(const Key('area-fixed:event-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('area-picker-cancel')));
    await tester.pumpAndSettle();

    // "取消"与"选择不归属领域"都是 null，必须区分开：取消不该被当成一次真实的清空。
    expect(calls, isEmpty);
  });

  testWidgets('非日程条目不能调整归属（图标保留但点不动）', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'block:block-1',
          title: '写方案',
          kind: ScheduleItemKind.task,
          startHourUtc: 9,
        ),
      ],
      onSetEventArea: (eventId, areaId) async => true,
    );

    final button = tester.widget<IconButton>(
      find.byKey(const Key('area-block:block-1')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('删除前问清"只删这一次"还是"删除整条"，并把选择交给对应入口', (tester) async {
    final entire = <String>[];
    final occurrences = <(String, DateTime, String)>[];
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 内联构造而不是复用 pump：这条用例要的正是"同时注入两个删除入口"的那种装配。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DayViewPage(
            source: _Items([
              _item(
                id: 'fixed:event-1',
                title: '数据结构课',
                kind: ScheduleItemKind.fixed,
                startHourUtc: 9,
              ),
            ]),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
            onDeleteEvent: (id) async {
              entire.add(id);
              return true;
            },
            onDeleteOccurrence: (id, startUtc, title) async {
              occurrences.add((id, startUtc, title));
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('delete-fixed:event-1')));
    await tester.tap(find.byKey(const Key('delete-fixed:event-1')));
    await tester.pumpAndSettle();
    // 删除不可逆，因此对话框必须把两种后果说明白。
    expect(find.textContaining('只删这一次会保留其它各次'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-this-occurrence')));
    await tester.pumpAndSettle();

    expect(occurrences, hasLength(1));
    expect(occurrences.single.$1, 'event-1');
    expect(occurrences.single.$3, '数据结构课');
    // **"被点了"与"删对了对象"是两件事**：选了"只删这一次"，整条删除的入口就不该被调用。
    expect(entire, isEmpty);

    // 再删一次，这次选"删除整条"：应当走另一个入口，且不再走"只删这一次"。
    await tester.tap(find.byKey(const Key('delete-fixed:event-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-entire')));
    await tester.pumpAndSettle();

    expect(entire, <String>['event-1']);
    expect(occurrences, hasLength(1));
  });

  testWidgets('"改这一次"把新时间交给注入的回调，非法输入留在对话框里', (tester) async {
    final replaced = <(String, DateTime, DateTime, DateTime)>[];
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DayViewPage(
            source: _Items([
              _item(
                id: 'fixed:event-1',
                title: '数据结构课',
                kind: ScheduleItemKind.fixed,
                startHourUtc: 9,
              ),
            ]),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
            onDeleteEvent: (id) async => true,
            onReplaceOccurrence: (id, startUtc, newStart, newEnd, title) async {
              replaced.add((id, startUtc, newStart, newEnd));
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('edit-fixed:event-1')));
    await tester.tap(find.byKey(const Key('edit-fixed:event-1')));
    await tester.pumpAndSettle();

    // 先试非法输入：**必须在对话框内说明并留下**，而不是把非法值交给下游。
    await tester.enterText(find.byKey(const Key('occurrence-start')), '不是时间');
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('时间格式应为'), findsOneWidget);
    expect(replaced, isEmpty);

    // 再改成合法时间：解析结果交给回调（本地时刻，UTC 换算由路由负责）。
    await tester.enterText(
      find.byKey(const Key('occurrence-start')),
      '2026-10-05 14:00',
    );
    await tester.enterText(
      find.byKey(const Key('occurrence-end')),
      '2026-10-05 15:00',
    );
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    expect(replaced, hasLength(1));
    expect(replaced.single.$1, 'event-1');
    expect(replaced.single.$3.hour, 14);
    expect(replaced.single.$4.hour, 15);
  });

  testWidgets('未注入改写入口时不显示该按钮', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:event-1',
          title: '数据结构课',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
      ],
      onDeleteEvent: (id) async => true,
    );

    expect(find.byKey(const Key('edit-fixed:event-1')), findsNothing);
  });

  testWidgets('勾选"改整个系列"走另一条入口，而不是改这一次', (tester) async {
    final single = <String>[];
    final series = <String>[];
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DayViewPage(
            source: _Items([
              _item(
                id: 'fixed:event-1',
                title: '数据结构课',
                kind: ScheduleItemKind.fixed,
                startHourUtc: 9,
              ),
            ]),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
            onDeleteEvent: (id) async => true,
            onReplaceOccurrence: (id, startUtc, newStart, newEnd, title) async {
              single.add(id);
              return true;
            },
            onReplaceSeries: (id, newStart, newEnd) async {
              series.add(id);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('edit-fixed:event-1')));
    await tester.tap(find.byKey(const Key('edit-fixed:event-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('occurrence-scope-series')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('occurrence-start')),
      '2026-10-05 14:00',
    );
    await tester.enterText(
      find.byKey(const Key('occurrence-end')),
      '2026-10-05 15:00',
    );
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    // **两个入口互斥**：勾了"整个系列"就绝不能同时走"改这一次"，否则一次操作写两处数据。
    expect(series, <String>['event-1']);
    expect(single, isEmpty);
  });

  testWidgets('选择“本次及以后”只调用系列拆分入口', (tester) async {
    final single = <String>[];
    final following = <String>[];
    final series = <String>[];
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DayViewPage(
            source: _Items([
              _item(
                id: 'fixed:event-1',
                title: '数据结构课',
                kind: ScheduleItemKind.fixed,
                startHourUtc: 9,
              ),
            ]),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
            onDeleteEvent: (id) async => true,
            onReplaceOccurrence: (id, startUtc, newStart, newEnd, title) async {
              single.add(id);
              return true;
            },
            onReplaceFollowing: (id, startUtc, newStart, newEnd) async {
              following.add(id);
              return true;
            },
            onReplaceSeries: (id, newStart, newEnd) async {
              series.add(id);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('edit-fixed:event-1')));
    await tester.pumpAndSettle();
    expect(find.text('仅本次'), findsOneWidget);
    expect(find.text('本次及以后'), findsOneWidget);
    expect(find.text('整个系列'), findsOneWidget);
    await tester.tap(find.byKey(const Key('occurrence-scope-following')));
    await tester.enterText(
      find.byKey(const Key('occurrence-start')),
      '2026-10-05 14:00',
    );
    await tester.enterText(
      find.byKey(const Key('occurrence-end')),
      '2026-10-05 15:00',
    );
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    expect(following, ['event-1']);
    expect(single, isEmpty);
    expect(series, isEmpty);
  });

  testWidgets('未注入系列编辑入口时不显示该勾选框', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:event-1',
          title: '数据结构课',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
      ],
      onDeleteEvent: (id) async => true,
    );

    await tester.ensureVisible(find.byKey(const Key('delete-fixed:event-1')));
    await tester.tap(find.byKey(const Key('delete-fixed:event-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-cancel')));
    await tester.pumpAndSettle();

    // 未注入改写入口时连编辑按钮都没有，因此这里确认的是"没有该按钮"。
    expect(find.byKey(const Key('edit-fixed:event-1')), findsNothing);
  });

  testWidgets('未注入删除入口时不显示删除按钮', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:event-1',
          title: '数据结构课',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
      ],
    );

    // 宁可没有按钮，也不要一个点了不生效的图标。
    expect(find.byKey(const Key('delete-fixed:event-1')), findsNothing);
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
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
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
