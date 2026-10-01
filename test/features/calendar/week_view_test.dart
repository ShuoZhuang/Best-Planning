import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/week_view_page.dart';

void main() {
  testWidgets('week view labels item kinds and supports proposal-based moves', (
    tester,
  ) async {
    final start = DateTime.utc(2026, 10, 5);
    final controller = StreamController<List<ScheduleViewItem>>();
    final moves = _MoveController();
    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(controller.stream),
          weekStart: start,
          moveController: moves,
        ),
      ),
    );
    expect(find.text('正在加载七日计划'), findsOneWidget);

    controller.add([
      ScheduleViewItem(
        id: 'research',
        title: '科研实验',
        kind: ScheduleItemKind.task,
        range: TimeRange(
          startUtc: start.add(const Duration(hours: 9)),
          endUtc: start.add(const Duration(hours: 10)),
        ),
      ),
      ScheduleViewItem(
        id: 'social',
        title: '同学聚餐',
        kind: ScheduleItemKind.life,
        range: TimeRange(
          startUtc: start.add(const Duration(days: 1, hours: 18)),
          endUtc: start.add(const Duration(days: 1, hours: 20)),
        ),
      ),
    ]);
    await tester.pump();

    expect(find.text('任务'), findsOneWidget);
    expect(find.text('生活'), findsOneWidget);
    expect(find.byType(LongPressDraggable<ScheduleViewItem>), findsNWidgets(2));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('科研实验')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('week-day-2'))),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(moves.calls, 1);
    expect(moves.lastItem?.id, 'research');
    expect(moves.lastDay, start.add(const Duration(days: 2)));
  });

  testWidgets('week view has an explicit empty state', (tester) async {
    final start = DateTime.utc(2026, 10, 5);
    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(Stream.value(const [])),
          weekStart: start,
          moveController: _MoveController(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未来七天暂无安排'), findsOneWidget);
  });
}

final class _Source implements ScheduleViewSource {
  const _Source(this.stream);
  final Stream<List<ScheduleViewItem>> stream;
  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      stream;
}

final class _MoveController implements WeekMoveController {
  int calls = 0;
  ScheduleViewItem? lastItem;
  DateTime? lastDay;
  @override
  Future<String?> proposeMove(ScheduleViewItem item, DateTime localDay) async {
    calls++;
    lastItem = item;
    lastDay = localDay;
    return 'proposal-1';
  }
}
