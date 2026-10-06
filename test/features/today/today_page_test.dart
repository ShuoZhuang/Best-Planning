import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/today/today_page.dart';

void main() {
  testWidgets('今日时间线和容量排除明天的任务', (tester) async {
    final today = DateTime.utc(2026, 10, 5);
    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(
          source: _Source(
            Stream.value([
              _item('today', '今天完成', ScheduleItemKind.task, today, 9),
              _item(
                'tomorrow',
                '明天完成',
                ScheduleItemKind.task,
                today.add(const Duration(days: 1)),
                9,
              ),
            ]),
          ),
          day: today,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('今天完成'), findsWidgets);
    expect(find.text('明天完成'), findsNothing);
    expect(find.textContaining('共安排 1 小时'), findsOneWidget);
  });
  final day = DateTime.utc(2026, 10, 5);

  testWidgets('图例按类型列出四项（与卡片取色同一套口径）', (tester) async {
    // 曾短暂改成"按领域 + 保护"，但整屏卡片各按领域上色后观感明显变差，已按用户要求
    // 恢复到按类型着色；图例必须与卡片取色是同一套口径，否则它就是在说错误信息。
    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(source: _Source(Stream.value(const [])), day: day),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('固定'), findsOneWidget);
    expect(find.text('保护'), findsOneWidget);
    expect(find.text('可移动任务'), findsOneWidget);
    expect(find.text('生活'), findsOneWidget);
    // 领域名不该出现在图例里。
    expect(find.text('学业'), findsNothing);
    expect(find.text('科研'), findsNothing);
  });

  testWidgets('today page renders its UTC window in the selected local zone', (
    tester,
  ) async {
    final utcDayStart = DateTime.utc(2026, 10, 4, 16);
    final lunch = ScheduleViewItem(
      id: 'lunch',
      title: '午餐时间',
      kind: ScheduleItemKind.protectedTime,
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 5, 4),
        endUtc: DateTime.utc(2026, 10, 5, 5),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(
          source: _Source(Stream.value([lunch])),
          day: utcDayStart,
          toLocal: (value) => value.add(const Duration(hours: 8)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('10月5日 · 星期一'), findsOneWidget);
    expect(find.text('12:00–13:00 · 保护时间'), findsWidgets);
  });

  testWidgets('wide today page presents a timeline and planning rail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(
          source: _Source(
            Stream.value([
              _item('class', '高等数学', ScheduleItemKind.fixed, day, 8),
              _item('research', '整理实验', ScheduleItemKind.task, day, 14),
              _item('movie', '看电影', ScheduleItemKind.life, day, 19),
            ]),
          ),
          day: day,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today-wide-layout')), findsOneWidget);
    expect(find.text('今日时间线'), findsOneWidget);
    expect(find.text('当前安排'), findsOneWidget);
    expect(find.text('今日容量'), findsOneWidget);
    expect(find.text('共安排 3 小时'), findsOneWidget);
  });

  testWidgets('wide today page scrolls a long timeline in a short window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(
          source: _Source(
            Stream.value([
              for (var hour = 8; hour <= 16; hour += 2)
                _item(
                  'task-$hour',
                  '任务 $hour',
                  ScheduleItemKind.task,
                  day,
                  hour,
                ),
            ]),
          ),
          day: day,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today-wide-layout')), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('today-timeline-scroll')), findsOneWidget);
  });

  testWidgets('compact today page keeps the planning summary below timeline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(760, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(
          source: _Source(
            Stream.value([
              _item('research', '整理实验', ScheduleItemKind.task, day, 14),
            ]),
          ),
          day: day,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today-compact-layout')), findsOneWidget);
    expect(find.text('今日时间线'), findsOneWidget);
    expect(find.text('今日容量'), findsOneWidget);
  });

  testWidgets('compact today page tolerates 150 percent text scaling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(760, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: TodayPage(
            source: _Source(
              Stream.value([
                _item('research', '整理实验', ScheduleItemKind.task, day, 14),
              ]),
            ),
            day: day,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today-compact-layout')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('today page covers loading, empty and content states', (
    tester,
  ) async {
    final controller = StreamController<List<ScheduleViewItem>>();
    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(source: _Source(controller.stream), day: day),
      ),
    );
    expect(find.text('正在加载今日安排'), findsOneWidget);

    controller.add(const []);
    await tester.pump();
    expect(find.text('今天暂无安排'), findsOneWidget);

    controller.add([
      _item('class', '高等数学', ScheduleItemKind.fixed, day, 8),
      _item('lunch', '午餐保护', ScheduleItemKind.protectedTime, day, 12),
      _item('research', '整理实验', ScheduleItemKind.task, day, 14),
      _item('movie', '看电影', ScheduleItemKind.life, day, 19),
    ]);
    await tester.pump();

    expect(find.text('高等数学'), findsWidgets);
    // 今日容量按类型给出分组标题。
    expect(find.text('固定日程'), findsOneWidget);
    expect(find.text('保护时间'), findsOneWidget);
    expect(find.text('任务与生活'), findsOneWidget);
    // 图例回到按类型的四项（与卡片取色同一套口径）。
    expect(find.text('可移动任务'), findsOneWidget);
    expect(find.text('生活'), findsOneWidget);
    expect(find.text('保护'), findsOneWidget);
  });

  testWidgets('today page error is recoverable', (tester) async {
    final first = StreamController<List<ScheduleViewItem>>();
    final source = _SequenceSource([
      first.stream,
      Stream.value(const <ScheduleViewItem>[]),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(source: source, day: day),
      ),
    );
    first.addError(StateError('offline'));
    await tester.pump();

    expect(find.text('暂时无法加载今日安排'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('今天暂无安排'), findsOneWidget);
    expect(source.calls, 2);
  });
}

ScheduleViewItem _item(
  String id,
  String title,
  ScheduleItemKind kind,
  DateTime day,
  int hour,
) => ScheduleViewItem(
  id: id,
  title: title,
  kind: kind,
  range: TimeRange(
    startUtc: day.add(Duration(hours: hour)),
    endUtc: day.add(Duration(hours: hour + 1)),
  ),
);

final class _Source implements ScheduleViewSource {
  const _Source(this.stream);
  final Stream<List<ScheduleViewItem>> stream;
  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      stream;
}

final class _SequenceSource implements ScheduleViewSource {
  _SequenceSource(this.streams);
  final List<Stream<List<ScheduleViewItem>>> streams;
  int calls = 0;
  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      streams[calls++];
}
