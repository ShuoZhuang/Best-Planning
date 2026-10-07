import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/week_view_page.dart';

void main() {
  testWidgets('七日日历按分类键显示图例并用分类色绘制卡片', (tester) async {
    final start = DateTime.utc(2026, 10, 5);
    const studyColor = Color(0xff2f86ff);
    const unassignedTaskColor = Color(0xff7f92b2);
    const unassignedFixedColor = Color(0xffa8b86f);
    final items = [
      _scheduleItem(
        id: 'fixed:class',
        title: '数据结构课',
        kind: ScheduleItemKind.fixed,
        categoryKey: 'area:study',
        categoryLabel: '学业',
        categoryColorArgb: studyColor.toARGB32(),
        categorySortOrder: 0,
        start: start.add(const Duration(hours: 8)),
      ),
      _scheduleItem(
        id: 'block:homework',
        title: '算法作业',
        kind: ScheduleItemKind.task,
        categoryKey: 'area:study',
        categoryLabel: '学业',
        categoryColorArgb: studyColor.toARGB32(),
        categorySortOrder: 0,
        start: start.add(const Duration(hours: 10)),
      ),
      _scheduleItem(
        id: 'block:loose',
        title: '零散任务',
        kind: ScheduleItemKind.task,
        categoryKey: 'special:unassigned-task',
        categoryLabel: '未分类任务',
        categoryColorArgb: unassignedTaskColor.toARGB32(),
        categorySortOrder: 10001,
        start: start.add(const Duration(hours: 14)),
      ),
      _scheduleItem(
        id: 'fixed:loose',
        title: '临时会议',
        kind: ScheduleItemKind.fixed,
        categoryKey: 'special:unassigned-fixed',
        categoryLabel: '未分类固定日程',
        categoryColorArgb: unassignedFixedColor.toARGB32(),
        categorySortOrder: 10002,
        start: start.add(const Duration(hours: 16)),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(Stream.value(items)),
          weekStart: start,
          moveController: _MoveController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('schedule-category-area:study')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('schedule-category-special:unassigned-task')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('schedule-category-special:unassigned-fixed')),
      findsOneWidget,
    );
    Card cardFor(String id) =>
        tester.widget<Card>(find.byKey(Key('week-schedule-card-$id')));
    RoundedRectangleBorder shapeFor(String id) =>
        cardFor(id).shape! as RoundedRectangleBorder;

    // 卡片颜色**只能**来自共享派生器：填充是不透明深色，描边是低亮派生色。
    // 这里逐值对比而不是只对"比之前深"，否则把公式调回半透明时测试照样会绿。
    void expectCard(String id, Color categoryColor, IconData expectedIcon) {
      final expected = scheduleCategoryCardStyle(categoryColor);
      expect(cardFor(id).color, expected.fill, reason: '$id 的填充不是共享派生色');
      expect(
        shapeFor(id).side.color,
        expected.border,
        reason: '$id 的描边不是共享派生色',
      );
      expect(
        cardFor(id).color!.toARGB32() >>> 24,
        0xff,
        reason: '$id 的填充必须是完全不透明色，否则玻璃背景会把它冲淡',
      );
      expect(cardFor(id).surfaceTintColor, Colors.transparent);
      // 领域原色只保留在小面积强调上（图标）。
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(Key('week-schedule-card-$id')),
                matching: find.byIcon(expectedIcon),
              ),
            )
            .color,
        expected.accent,
        reason: '$id 的图标必须用分类原色，而不是填充色',
      );
    }

    // 同一领域下的固定日程与可移动任务必须同色：类型差异只由图标表达。
    expectCard('fixed:class', studyColor, Icons.event);
    expectCard('block:homework', studyColor, Icons.task_alt);
    expectCard('block:loose', unassignedTaskColor, Icons.task_alt);
    expectCard('fixed:loose', unassignedFixedColor, Icons.event);
    expect(
      cardFor('fixed:class').color,
      cardFor('block:homework').color,
      reason: '同学业的固定日程与任务必须同色',
    );
    expect(find.text('学业'), findsNWidgets(3));
    expect(find.text('任务'), findsNothing);
    expect(find.text('固定日程'), findsNothing);
    expect(find.byIcon(Icons.task_alt), findsNWidgets(2));
    expect(find.byIcon(Icons.event), findsNWidgets(2));
  });

  testWidgets('七日历的学业、生活、保护时间与无领域任务各用共享深色卡片', (tester) async {
    final start = DateTime.utc(2026, 10, 5);
    const studyColor = Color(0xff2f86ff);
    const lifeColor = Color(0xffb391d3);
    const protectedColor = Color(0xff5ec8e5);
    const unassignedColor = Color(0xff7f92b2);
    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(
            Stream.value([
              _scheduleItem(
                id: 'fixed:class',
                title: '数据结构课',
                kind: ScheduleItemKind.fixed,
                categoryKey: 'area:study',
                categoryLabel: '学业',
                categoryColorArgb: studyColor.toARGB32(),
                categorySortOrder: 0,
                start: start.add(const Duration(hours: 8)),
              ),
              _scheduleItem(
                id: 'block:homework',
                title: '算法作业',
                kind: ScheduleItemKind.task,
                categoryKey: 'area:study',
                categoryLabel: '学业',
                categoryColorArgb: studyColor.toARGB32(),
                categorySortOrder: 0,
                start: start.add(const Duration(hours: 10)),
              ),
              _scheduleItem(
                id: 'block:movie',
                title: '看电影',
                kind: ScheduleItemKind.life,
                categoryKey: 'area:life',
                categoryLabel: '生活',
                categoryColorArgb: lifeColor.toARGB32(),
                categorySortOrder: 4,
                start: start.add(const Duration(hours: 12)),
              ),
              _scheduleItem(
                id: 'protected:lunch:1',
                title: '午餐时间',
                kind: ScheduleItemKind.protectedTime,
                categoryKey: 'special:protected',
                categoryLabel: '保护时间',
                categoryColorArgb: protectedColor.toARGB32(),
                categorySortOrder: 10000,
                start: start.add(const Duration(hours: 13)),
              ),
              _scheduleItem(
                id: 'block:loose',
                title: '零散任务',
                kind: ScheduleItemKind.task,
                categoryKey: 'special:unassigned-task',
                categoryLabel: '未分类任务',
                categoryColorArgb: unassignedColor.toARGB32(),
                categorySortOrder: 10001,
                start: start.add(const Duration(hours: 15)),
              ),
            ]),
          ),
          weekStart: start,
          moveController: _MoveController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final (id, color, icon) in <(String, Color, IconData)>[
      ('fixed:class', studyColor, Icons.event),
      ('block:homework', studyColor, Icons.task_alt),
      ('block:movie', lifeColor, Icons.self_improvement),
      ('protected:lunch:1', protectedColor, Icons.shield_outlined),
      ('block:loose', unassignedColor, Icons.task_alt),
    ]) {
      final expected = scheduleCategoryCardStyle(color);
      final card = tester.widget<Card>(
        find.byKey(Key('week-schedule-card-$id')),
      );
      expect(card.color, expected.fill, reason: '$id 的填充');
      expect(
        (card.shape! as RoundedRectangleBorder).side.color,
        expected.border,
        reason: '$id 的描边',
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(Key('week-schedule-card-$id')),
                matching: find.byIcon(icon),
              ),
            )
            .color,
        expected.accent,
        reason: '$id 的图标强调色',
      );
    }

    // 类型不再参与配色：同学业的固定日程与任务同色，只由图标区分。
    expect(
      tester
          .widget<Card>(find.byKey(const Key('week-schedule-card-fixed:class')))
          .color,
      tester
          .widget<Card>(
            find.byKey(const Key('week-schedule-card-block:homework')),
          )
          .color,
    );
    // 跨页面一致性：今日、七日历、单日详情对同一个分类色（学业蓝 `#2f86ff`）必须得到同一组
    // ARGB。三个页面的测试各自钉住这三个字面值，任何一处自己另算一遍都会在那里红掉。
    final shared = scheduleCategoryCardStyle(studyColor);
    expect(shared.accent.toARGB32(), 0xff2f86ff);
    expect(shared.fill.toARGB32(), 0xff17345b);
    expect(shared.border.toARGB32(), 0xff20487f);
    expect(
      tester
          .widget<Card>(find.byKey(const Key('week-schedule-card-fixed:class')))
          .color,
      shared.fill,
    );
    // 卡片正文只显示分类标签，不显示类型。
    expect(find.text('固定日程'), findsNothing);
    expect(find.text('任务'), findsNothing);
  });

  testWidgets('七日卡片为已完成条目显示完成标记', (tester) async {
    final start = DateTime.utc(2026, 10, 5);
    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(
            Stream.value([
              ScheduleViewItem(
                id: 'block:done',
                title: '已经做完的事',
                kind: ScheduleItemKind.task,
                categoryKey: 'area:study',
                categoryLabel: '学业',
                categoryColorArgb: 0xff2f86ff,
                categorySortOrder: 0,
                isCompleted: true,
                range: TimeRange(
                  startUtc: start.add(const Duration(hours: 9)),
                  endUtc: start.add(const Duration(hours: 10)),
                ),
              ),
              ScheduleViewItem(
                id: 'block:open',
                title: '还没做的事',
                kind: ScheduleItemKind.task,
                categoryKey: 'area:study',
                categoryLabel: '学业',
                categoryColorArgb: 0xff2f86ff,
                categorySortOrder: 0,
                range: TimeRange(
                  startUtc: start.add(const Duration(hours: 11)),
                  endUtc: start.add(const Duration(hours: 12)),
                ),
              ),
            ]),
          ),
          weekStart: start,
          moveController: _MoveController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 标记不改标题、也不改分类——这正是"勾完之后卡片变成已安排任务"那次缺陷的反面。
    expect(find.text('已经做完的事'), findsOneWidget);
    expect(
      find.byKey(const Key('week-schedule-completed-block:done')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('week-schedule-completed-block:open')),
      findsNothing,
    );
    // 完成与未完成同领域 → 同色：完成不该改变分类色。
    expect(
      tester
          .widget<Card>(find.byKey(const Key('week-schedule-card-block:done')))
          .color,
      tester
          .widget<Card>(find.byKey(const Key('week-schedule-card-block:open')))
          .color,
    );
  });

  testWidgets('课表导入入口调用导航回调', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(Stream.value(const [])),
          weekStart: DateTime.utc(2026, 10, 5),
          moveController: _MoveController(),
          onImportTimetable: () => opened = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final action = find.byKey(const Key('import-timetable'));
    expect(action, findsOneWidget);
    await tester.tap(action);
    expect(opened, isTrue);
  });

  testWidgets('点击日程气泡打开对应一天并在七日历显示具体时间', (tester) async {
    final start = DateTime.utc(2026, 10, 5);
    DateTime? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(
            Stream.value([
              ScheduleViewItem(
                id: 'block:test',
                title: '周二实验',
                kind: ScheduleItemKind.task,
                categoryKey: 'area:study',
                categoryLabel: '学业',
                categoryColorArgb: 0xff2f86ff,
                categorySortOrder: 0,
                range: TimeRange(
                  startUtc: DateTime.utc(2026, 10, 6, 9),
                  endUtc: DateTime.utc(2026, 10, 6, 10, 30),
                ),
              ),
            ]),
          ),
          weekStart: start,
          moveController: _MoveController(),
          onOpenDay: (day) => opened = day,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('09:00–10:30'), findsOneWidget);
    await tester.tap(find.text('周二实验'));
    await tester.pumpAndSettle();
    expect(opened, DateTime.utc(2026, 10, 6));
  });
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
        categoryKey: 'area:research',
        categoryLabel: '科研',
        categoryColorArgb: 0xff53c7a5,
        categorySortOrder: 1,
        range: TimeRange(
          startUtc: start.add(const Duration(hours: 9)),
          endUtc: start.add(const Duration(hours: 10)),
        ),
      ),
      ScheduleViewItem(
        id: 'social',
        title: '同学聚餐',
        kind: ScheduleItemKind.life,
        categoryKey: 'area:life',
        categoryLabel: '生活',
        categoryColorArgb: 0xffb391d3,
        categorySortOrder: 4,
        range: TimeRange(
          startUtc: start.add(const Duration(days: 1, hours: 18)),
          endUtc: start.add(const Duration(days: 1, hours: 20)),
        ),
      ),
    ]);
    await tester.pump();

    expect(find.text('科研'), findsNWidgets(2));
    expect(find.text('生活'), findsNWidgets(2));
    expect(find.text('任务'), findsNothing);
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
                categoryKey: 'area:work',
                categoryLabel: '工作',
                categoryColorArgb: 0xfff06f7a,
                categorySortOrder: 3,
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
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('写方案')),
    );
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
                categoryKey: 'area:work',
                categoryLabel: '工作',
                categoryColorArgb: 0xfff06f7a,
                categorySortOrder: 3,
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

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('写方案')),
    );
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
      categoryKey: 'test:${kind.name}',
      categoryLabel: kind.label,
      categoryColorArgb: 0xff456789,
      categorySortOrder: kind.index,
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
      movableTaskBlockId(
        item('protected:lunch:1', ScheduleItemKind.protectedTime),
      ),
      isNull,
    );
    // 形状不对的 id 也不能猜：宁可拖不动，也不要钉到一个不存在的位置上。
    expect(movableTaskBlockId(item('research', ScheduleItemKind.task)), isNull);
    expect(movableTaskBlockId(item('block:', ScheduleItemKind.task)), isNull);
  });

  testWidgets('七日日历在七天左侧补出"昨天"，并像天气应用那样标出今天', (tester) async {
    // 用户 2026-10-07："七日日历可以再'今天起 7 天'的基础上加上昨天，就像手机上的天气预报一样"。
    // 起点是**今天**（路由器传 `todayStartUtc`），所以七天里本来没有昨天——这不是重复列。
    final today = DateTime.utc(2026, 10, 7); // 2026-10-07 是周三
    final recorder = _RangeRecorder();
    final yesterdayItem = _scheduleItem(
      id: 'fixed:yesterday',
      title: '昨天的事',
      kind: ScheduleItemKind.fixed,
      categoryKey: 'area:study',
      categoryLabel: '学业',
      categoryColorArgb: const Color(0xff2f86ff).toARGB32(),
      categorySortOrder: 0,
      start: today
          .subtract(const Duration(days: 1))
          .add(const Duration(hours: 8)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(Stream.value([yesterdayItem]), recorder: recorder),
          weekStart: today,
          moveController: _MoveController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 八列：-1（昨天）+ 0..6（今天起七天）。
    expect(find.byKey(const Key('week-day--1')), findsOneWidget);
    for (var index = 0; index < 7; index++) {
      expect(find.byKey(Key('week-day-$index')), findsOneWidget);
    }
    expect(find.byKey(const Key('week-day-7')), findsNothing);

    // 列头标出相对日；其余显示星期。周三是"今天"，所以周三不再单独出现。
    expect(find.text('昨天'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('明天'), findsOneWidget);
    // 最近的第三天起改用星期几：今天(周三)、明天(周四) 都不再以星期出现。
    expect(find.text('周三'), findsNothing);
    expect(find.text('周四'), findsNothing);
    expect(find.text('周五'), findsOneWidget);
    expect(find.text('周二'), findsOneWidget); // 十天里的最后一列（10-13）

    // **昨天真的被订阅了**：少订阅一天的话这一列会永远空白，看起来像"昨天没有安排"。
    expect(recorder.ranges, isNotEmpty);
    expect(
      recorder.ranges.first.$1,
      today.subtract(const Duration(days: 1)),
      reason: '订阅窗口必须从昨天开始',
    );
    expect(recorder.ranges.first.$2, today.add(const Duration(days: 7)));
    // 而且昨天的条目确实渲染在昨天那一列里。
    expect(
      find.descendant(
        of: find.byKey(const Key('week-day--1')),
        matching: find.text('昨天的事'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('今天那一列被高亮，八列里一眼能找到', (tester) async {
    final today = DateTime.utc(2026, 10, 7);
    // **必须至少给一条安排**：一条都没有时页面走空状态、整片列都不渲染（"这几天暂无安排"），
    // 那样就无从检查高亮了。第一版传了空列表，测试当场报 `Bad state: No element`。
    final item = _scheduleItem(
      id: 'fixed:today',
      title: '今天的课',
      kind: ScheduleItemKind.fixed,
      categoryKey: 'area:study',
      categoryLabel: '学业',
      categoryColorArgb: const Color(0xff2f86ff).toARGB32(),
      categorySortOrder: 0,
      start: today.add(const Duration(hours: 8)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(Stream.value([item])),
          weekStart: today,
          moveController: _MoveController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    BorderSide borderOf(String key) {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      return ((container.decoration! as BoxDecoration).border! as Border).top;
    }

    final theme = Theme.of(tester.element(find.byKey(const Key('week-day-0'))));
    expect(borderOf('week-day-0').color, theme.colorScheme.primary);
    expect(borderOf('week-day-0').width, greaterThan(1));
    // 昨天与明天都是普通描边，只有今天被标出来。
    expect(borderOf('week-day--1').color, theme.colorScheme.outlineVariant);
    expect(borderOf('week-day-1').color, theme.colorScheme.outlineVariant);
  });
}

ScheduleViewItem _scheduleItem({
  required String id,
  required String title,
  required ScheduleItemKind kind,
  required String categoryKey,
  required String categoryLabel,
  required int categoryColorArgb,
  required int categorySortOrder,
  required DateTime start,
}) => ScheduleViewItem(
  id: id,
  title: title,
  kind: kind,
  categoryKey: categoryKey,
  categoryLabel: categoryLabel,
  categoryColorArgb: categoryColorArgb,
  categorySortOrder: categorySortOrder,
  range: TimeRange(
    startUtc: start,
    endUtc: start.add(const Duration(hours: 1)),
  ),
);

/// 记录数据源被请求过的窗口，用来证明"昨天那一列真的订阅了"。
final class _RangeRecorder {
  final List<(DateTime, DateTime)> ranges = [];
}

final class _Source implements ScheduleViewSource {
  const _Source(this.stream, {this.recorder});
  final Stream<List<ScheduleViewItem>> stream;
  final _RangeRecorder? recorder;

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) {
    recorder?.ranges.add((startUtc, endUtc));
    return stream;
  }
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
