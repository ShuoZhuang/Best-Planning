import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/today/today_page.dart';

void main() {
  final day = DateTime.utc(2026, 10, 5);

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

    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('固定日程'), findsOneWidget);
    expect(find.text('保护时间'), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('生活'), findsOneWidget);
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
