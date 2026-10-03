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

    // **放手后先问一次"是否锁定"，此时还没有提交**（FR-CAL-05 的"可选择锁定"）。
    // 这条断言是判别性的：去掉确认对话框后控制器会被立刻调用，`calls` 会在这里就是 1。
    expect(moves.calls, 0);
    expect(find.text('把「科研实验」移到 10 月 7 日'), findsOneWidget);

    await tester.tap(find.byKey(const Key('move-confirm')));
    await tester.pumpAndSettle();

    expect(moves.calls, 1);
    expect(moves.lastItem?.id, 'research');
    expect(moves.lastDay, start.add(const Duration(days: 2)));
    // 默认勾选"锁定"：手动放置是显式指令，默认不让后续自动调整挪走它。
    expect(moves.lastLock, isTrue);
  });

  testWidgets('在移动确认框里取消勾选"锁定"，控制器收到的就是未锁定', (tester) async {
    final start = DateTime.utc(2026, 10, 5);
    final moves = _MoveController();
    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(
            Stream.value([
              ScheduleViewItem(
                id: 'block:b1',
                title: '写方案',
                kind: ScheduleItemKind.task,
                range: TimeRange(
                  startUtc: start.add(const Duration(hours: 9)),
                  endUtc: start.add(const Duration(hours: 10)),
                ),
              ),
            ]),
          ),
          weekStart: start,
          moveController: moves,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 长按拖动：`LongPressDraggable` 需要按下并保持，瞬时 `drag` 不足以触发它。
    final gesture = await tester.startGesture(tester.getCenter(find.text('写方案')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('week-day-1'))),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('move-lock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('move-confirm')));
    await tester.pumpAndSettle();

    expect(moves.calls, 1);
    expect(moves.lastLock, isFalse);
  });

  testWidgets('在移动确认框里点"取消"，不产生任何移动', (tester) async {
    final start = DateTime.utc(2026, 10, 5);
    final moves = _MoveController();
    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(
            Stream.value([
              ScheduleViewItem(
                id: 'block:b1',
                title: '写方案',
                kind: ScheduleItemKind.task,
                range: TimeRange(
                  startUtc: start.add(const Duration(hours: 9)),
                  endUtc: start.add(const Duration(hours: 10)),
                ),
              ),
            ]),
          ),
          weekStart: start,
          moveController: moves,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(find.text('写方案')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('week-day-1'))),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('move-cancel')));
    await tester.pumpAndSettle();

    expect(moves.calls, 0);
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

  test('只有可移动的任务块能被拖动，固定日程与保护时间不是', () {
    ScheduleViewItem item(String id, ScheduleItemKind kind) => ScheduleViewItem(
      id: id,
      title: 'x',
      kind: kind,
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 5),
        endUtc: DateTime.utc(2026, 10, 5, 1),
      ),
    );

    expect(movableTaskBlockId(item('block:b1', ScheduleItemKind.task)), 'b1');
    // 固定日程与保护时间是硬约束：拖动它们不是"移动计划"，而是改另一份数据。
    expect(
      movableTaskBlockId(item('fixed:e1', ScheduleItemKind.fixed)),
      isNull,
    );
    expect(
      movableTaskBlockId(item('protected:lunch:1', ScheduleItemKind.protectedTime)),
      isNull,
    );
    // 形状不对的 id 也不能猜：宁可拖不动，也不要钉到一个不存在的位置上。
    expect(movableTaskBlockId(item('research', ScheduleItemKind.task)), isNull);
    expect(movableTaskBlockId(item('block:', ScheduleItemKind.task)), isNull);
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
  bool? lastLock;
  @override
  Future<String?> proposeMove(
    ScheduleViewItem item,
    DateTime localDay, {
    bool lock = true,
  }) async {
    calls++;
    lastItem = item;
    lastDay = localDay;
    lastLock = lock;
    return 'proposal-1';
  }
}
