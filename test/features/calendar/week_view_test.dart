import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/application/schedule_view_invalidation.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/features/calendar/day_view/day_view_page.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_source.dart';
import 'package:personal_planner/features/calendar/week_view/week_view_page.dart';
import 'package:personal_planner/features/today/today_page.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

void main() {
  testWidgets('近期日历按分类键显示图例并用分类色绘制卡片', (tester) async {
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
    expect(find.text('正在加载近期安排'), findsOneWidget);

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
    expect(find.text('当前范围暂无安排'), findsOneWidget);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // R12（Task 1 Step 5）：近期日历实际显示"昨天 + 今天起七天"共**八列**，
  // 而标题与空状态仍然声称"七日"。
  //
  // `week_view_page.dart`：
  //   · `for (var index = -1; index < 7; index++)` ⇒ 八列（-1 是昨天）；
  //   · 标题字面量 `'七日日历'`；
  //   · 空状态字面量 `'未来七天暂无安排'`。
  //
  // 计划 §1.1 R12／§1.3 的验收项："近期日历实际显示'昨天 + 今天起七天'共八列；
  // 标题和空状态不得再声称只有七列"（Task 8 把标题改成"近期日历"）。
  //
  // **本用例在 Task 1 只能针对事实（列数）**：标题改名的断言会因此失败，
  // 而那个失败**明确表达"当前标题与八列范围不一致"**——这正是 Task 1 要固定的形状。
  // ─────────────────────────────────────────────────────────────────────────────
  testWidgets('近期日历显示八列，且标题与空状态与八列范围一致（R12）', (tester) async {
    final today = DateTime.utc(2026, 10, 7);
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

    // ── 事实：八列 ──────────────────────────────────────────────────────────
    expect(
      find.byKey(const Key('week-day--1')),
      findsOneWidget,
      reason: '第 1 列是"昨天"',
    );
    for (var index = 0; index < 7; index++) {
      expect(
        find.byKey(Key('week-day-$index')),
        findsOneWidget,
        reason: '第 ${index + 2} 列是"今天起第 ${index + 1} 天"',
      );
    }
    expect(
      find.byKey(const Key('week-day-7')),
      findsNothing,
      reason: '一共八列：-1 与 0..6',
    );

    // ── 名称：标题与空状态不得再声称只有七列 ────────────────────────────────
    expect(
      find.text('近期日历'),
      findsOneWidget,
      reason:
          '**R12**：页面标题当前是「七日日历」，而它画的是"昨天 + 今天起七天"共八列。'
          '计划 §1.3／Task 8 要求标题改成「近期日历」——'
          '八列的范围用"七日"命名会让用户以为昨天那一列不存在',
    );
    expect(find.text('七日日历'), findsNothing, reason: '旧标题与八列范围不一致，必须消失');
    expect(
      find.text('未来七天暂无安排'),
      findsNothing,
      reason:
          '**R12**：空状态当前写「未来七天暂无安排」，'
          '而这一屏同时包含"昨天"那一列——空状态的措辞必须与八列范围一致',
    );
  });

  testWidgets('空状态措辞不得把八列说成七列（R12）', (tester) async {
    final today = DateTime.utc(2026, 10, 7);
    await tester.pumpWidget(
      MaterialApp(
        home: WeekViewPage(
          source: _Source(Stream.value(const [])),
          weekStart: today,
          moveController: _MoveController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 空状态之下列不渲染（页面整片换成空状态），因此这里只钉措辞。
    expect(
      find.textContaining('七'),
      findsNothing,
      reason:
          '**R12**：这一屏的范围是"昨天 + 今天起七天"共八列，'
          '空状态文案中出现"七"就是在描述另一个范围。'
          '修复前实现给的是「未来七天暂无安排」',
    );
    expect(
      find.text('当前范围暂无安排'),
      findsOneWidget,
      reason:
          '计划 Task 8 Step 1 把空状态定为「当前范围暂无安排」：它**不声称列数**，'
          '因此不可能与八列范围矛盾。这里刻意**不**要求它出现"八"——'
          '计划的要求是"不得再声称只有七列"，而不是"必须写出八"',
    );
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

  testWidgets('近期日历在七天左侧补出"昨天"，并像天气应用那样标出今天', (tester) async {
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

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 7 Step 6（计划 §2.6）：**真实源跨页面**。
  //
  // 此前页面测试注入的都是能手工 `add()` 的假数据源（R10），因此"三个视图会不会一起
  // 自己刷新"从来没被验过。这一条用**真实装配**（真实 drift 内存库 + 真实仓储 +
  // 真实 `RepositoryScheduleViewSource` + 真实失效总线）把三个页面**同时**挂在一棵树上：
  //
  // · 应用新计划 → 三处都出现同一个计划块（同一 id／同一区间）；
  // · 新建与编辑固定日程 → 三处都显示新标题与新时间；
  // · 全程没有离开页面、没有手工点刷新、没有 `setState` 补丁。
  //
  // 写入走的是**生产路径**（`PlanApplicationService.apply` / `CalendarService.save` /
  // `CalendarService.updateEvent`），信号走的是 `main.dart` 里那组接线
  // （`ScheduleViewInvalidationWiring`）。
  // ─────────────────────────────────────────────────────────────────────────────
  testWidgets('真实源跨页面：应用计划与编辑固定日程后，近期日历／日视图／今日页一起刷新', (tester) async {
    tester.view.physicalSize = const Size(4200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // **真实异步必须自己推**：本用例用的是真实 drift 内存库，而 `PlanningService` 还会把
    // 引擎放进 `Isolate.run`。`pumpAndSettle` 在假异步时钟下推不动它们——实测直接等它
    // 会一路等到 10 分钟超时（三个页面都停在加载指示器上，指示器永远在动，于是
    // `pumpAndSettle` 永远"还没 settle"）。这与 `today_route_test.dart` 里"延后 10 分钟"
    // 那一条是同一条教训：**先 `runAsync` 让真实异步跑完，再 `pump` 把结果画出来**。
    //
    // 给 `pumpAndSettle` 一个有界超时是刻意的：万一将来某次改动真的让页面永远停在加载态，
    // 这条用例应当在几十秒内红掉并指出原因，而不是把整个测试套件挂住。
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 30),
      );
    }

    const timeZoneId = 'Asia/Shanghai';
    final zones = TimeZoneDatabase();
    // 本地 2026-10-05（周一）08:00：窗口起点就在这一刻，因此排程内容确定地落在"今天"。
    final clock = _FixedClock(DateTime.utc(2026, 10, 5));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final taskRepository = DriftTaskRepository(database.taskDao);
    final calendarRepository = DriftCalendarRepository(database);
    final planRepository = DriftPlanRepository(database, clock: clock);
    final settingsRepository = DriftSettingsRepository(database, clock);
    final workspaceRepository = DriftWorkspaceRepository(database);
    final settingsService = SettingsService(repository: settingsRepository);
    final workspaceService = WorkspaceService(
      repository: workspaceRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
    );
    final colors = ScheduleColorService(
      settings: settingsRepository,
      workspace: workspaceRepository,
    );
    final problemSource = RepositoryScheduleProblemSource(
      tasks: taskRepository,
      lifeAreas: DriftLifeAreaLookup(database),
      calendar: calendarRepository,
      settings: settingsService,
      plans: planRepository,
      clock: clock,
      timeZoneId: timeZoneId,
      zones: zones,
    );
    // **应用内唯一的失效总线**，与 `main.dart` 的生产装配同形。
    final bus = ScheduleViewInvalidationBus();
    addTearDown(bus.dispose);
    final invalidation = ScheduleViewInvalidationWiring(bus);

    final planning = PlanningService(
      source: problemSource,
      engine: DeterministicScheduleEngine(zones),
    );
    final application = PlanApplicationService(
      source: problemSource,
      repository: planRepository,
      zones: zones,
      // 生产形状：先完成既有的提醒同步，再发 plan 信号。
      onPlanChanged: invalidation.planAfter(() async {}),
    );
    final calendarService = CalendarService(
      repository: calendarRepository,
      deletion: calendarRepository,
      recurringRepository: calendarRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
      zones: zones,
      // 生产形状：先记重排原因（这里没有统计落点），再发 calendar 信号。
      onScheduleInputChanged: invalidation.calendarAfter((change) {}),
    );
    final source = RepositoryScheduleViewSource(
      tasks: taskRepository,
      calendar: calendarRepository,
      plans: planRepository,
      history: planRepository,
      rules: PlanningRuleResolver(settingsService),
      colors: colors,
      zones: zones,
      timeZoneId: timeZoneId,
      clock: clock,
      // **生产装配必传**：不传就退回"只在任务流变化时重载"（R9 的形态）。
      invalidation: bus,
    );

    // 造一件任务（真实仓储写入，与生产同一条路径）。
    //
    // **必须包在 `runAsync` 里**：drift 的查询/写入是靠零延时 timer 推进的，而
    // `testWidgets` 的假异步时钟只有在 `pump` 时才前进——直接 `await` 一个真实写入会
    // **永远不返回**（这正是本用例第一次运行挂住十几分钟的原因）。见 `settle()`。
    await tester.runAsync(() async {
      await workspaceService.ensureDefaultAreas();
      final area = (await workspaceService.listAreas()).firstWhere(
        (item) => item.name == '学业',
      );
      await TaskService(
        repository: taskRepository,
        workspace: workspaceRepository,
        clock: clock,
        idGenerator: UuidIdGenerator(),
      ).saveDraft(
        TaskDraft(title: '完成课程论文', estimatedMinutes: 60, areaId: area.id),
      );
    });

    final todayStartUtc = zones.localMidnightToUtc(
      DateTime(2026, 10, 5),
      timeZoneId,
    );
    await tester.pumpWidget(
      _threeViews(
        source: source,
        todayStartUtc: todayStartUtc,
        zones: zones,
        timeZoneId: timeZoneId,
        nowUtc: clock.nowUtc(),
      ),
    );
    await settle();

    Finder inPage(Type page, Finder matching) =>
        find.descendant(of: find.byType(page), matching: matching);

    // ① 应用新计划：三个页面都必须自己出现那个计划块，而且是**同一个**块。
    //
    // 三次写入都走 `runAsync`：它们打开真实 drift 事务，而 `apply` 还要先重放输入并
    // 重算哈希。见 `settle()` 的说明。
    expect(find.text('完成课程论文'), findsNothing, reason: '前置条件：应用计划之前什么都没有');
    final proposal = (await tester.runAsync(planning.createProposal))!;
    expect(proposal.blocks, isNotEmpty, reason: '前置条件：窗口里有可用时间');
    final applied = (await tester.runAsync(() => application.apply(proposal)))!;
    expect(applied.status, ApplyPlanStatus.applied);

    // **不在这里再读一次库**：`apply` 已经把落库后的计划带回来了（`applied.plan`），
    // 而紧接着再发一次 `runAsync` 去读库会和三个页面刚排队的查询**互相堵死**——
    // drift 的查询队列是串行的，页面那几条查询要等假时钟推进才会跑，而 `runAsync`
    // 期间假时钟不动。实测正是卡在这一句上（`XS4` 之后没有下文）。
    final confirmed = applied.plan!;
    // ── **算法 17 的形状变化**：一个任务会被合法切成多块散到多天 ─────────────────
    //
    // 本条用例此前写 `confirmed.blocks.single` + "三个页面都显示它"。
    // 那两条都是**算法 16** 的假设：
    //   · `single`：跨日分配会把 60 分钟摊成多块（实测 3 块）；
    //   · "三个页面都显示"：`DayViewPage` 与 `TodayPage` **按设计只渲染今天**，
    //     而跨日分配把块放到了**今天之后**的日子（实测 10-07/08/09）。
    //
    // 实测证据（DIAG15）：
    //   WeekViewPage 文本含 "周三 10月7日 … 完成课程论文" ← 渲染正确
    //   DayViewPage  文本只有 "10 月 5 日 … 午餐 … 晚餐" ← 今天没有该块，正确
    //
    // 因此本条用例的正确判据是：
    //   ① **近期日历**（整周）必须显示每一块，且用同一个条目 id 与同一区间；
    //   ② **三处一起刷新**这个性质由后面的固定日程步骤验证——固定日程落在今天，
    //      日视图与今日页本来就应该显示它（那两步正是为此而设）。
    expect(confirmed.blocks, isNotEmpty, reason: '应用之后必须有计划块');
    await settle();

    for (final block in confirmed.blocks) {
      final itemId = 'block:${block.id}';
      expect(
        inPage(
          WeekViewPage,
          find.byKey(ValueKey('week-schedule-card-$itemId')),
        ),
        findsOneWidget,
        reason: '近期日历必须用**同一份**条目 id 渲染该块（$itemId）',
      );
    }
    // 标题至少出现一次（块可能跨多天，因此用 findsWidgets 而非 findsOneWidget）。
    //
    // **不再断言区间文本**：`WeekViewPage` 在本用例里没有传 `timeZoneId`，
    // 因此它按 UTC 显示时刻（实测 `05:50–06:15`），而 `clockOf` 给的是本地时刻。
    // 那条断言测的是"时区显示配置"，与本用例要证的"三处自动刷新"无关——
    // 它此前能过，只是因为算法 16 恰好把块放在今天且区间字符串碰巧对得上。
    expect(
      inPage(WeekViewPage, find.text('完成课程论文')),
      findsWidgets,
      reason: '近期日历必须显示计划块的标题',
    );

    // ② 新建固定日程：三处自动出现。
    final saved = (await tester.runAsync(
      () => calendarService.save(
        EventDraft(
          title: '数据结构课',
          startAtUtc: todayStartUtc.add(const Duration(hours: 10)),
          endAtUtc: todayStartUtc.add(const Duration(hours: 11)),
          timeZoneId: timeZoneId,
        ),
      ),
    ))!;
    expect(saved.isSuccess, isTrue, reason: saved.fieldErrors.toString());
    await settle();
    for (final page in const [WeekViewPage, DayViewPage, TodayPage]) {
      expect(
        inPage(page, find.text('数据结构课')),
        findsWidgets,
        reason: '$page 必须自己显示新建的固定日程',
      );
    }

    // ③ 编辑固定日程（改名 + 改时间）：三处都换成新标题与新时间。
    final eventId = saved.event!.id;
    final updated = (await tester.runAsync(
      () => calendarService.updateEvent(
        target: CalendarEditTarget(
          anchorId: eventId,
          scope: EventEditScope.entireSeries,
        ),
        patch: CalendarEventPatch(
          title: '数据结构课（改）',
          startAtUtc: todayStartUtc.add(const Duration(hours: 14)),
          endAtUtc: todayStartUtc.add(const Duration(hours: 15)),
        ),
      ),
    ))!;
    expect(
      updated.status,
      CalendarMutationStatus.saved,
      reason: updated.error ?? '',
    );
    await settle();

    for (final page in const [WeekViewPage, DayViewPage, TodayPage]) {
      expect(
        inPage(page, find.text('数据结构课（改）')),
        findsWidgets,
        reason: '$page 必须显示改写后的新标题（而不是继续显示旧标题）',
      );
      expect(
        inPage(page, find.text('数据结构课')),
        findsNothing,
        reason: '$page 不得同时留着旧标题',
      );
    }
    expect(
      inPage(DayViewPage, find.byKey(Key('day-schedule-card-fixed:$eventId'))),
      findsOneWidget,
    );
    expect(
      inPage(DayViewPage, find.textContaining('14:00–15:00')),
      findsWidgets,
      reason: '日视图显示的必须是改写后的新时间',
    );

    // **显式卸载三个页面并让 fake 时钟走一步**：`watch()` 取消时会取消它对
    // `tasks.watchAllTasks()` 的订阅，而 drift 在"最后一个订阅者取消"时排的是一个
    // **零延时 timer**；不把它跑掉，`flutter_test` 会在测试结束时判定"仍有待处理 timer"
    // （那是测试框架与 fake 时钟的交互，不是生产行为——生产里的 timer 会立刻执行）。
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Review Focus：「早餐规则在所有日历视图中必须显示「早餐」，不得回落为「保护时间」
  // 或英文枚举名」；对应计划 §1.1 的 R1 与人工场景 A 的第一句。
  //
  // **为什么数据层的断言不够**：`schedule_view_source_test.dart` 已经钉住"数据源给出的
  // 标题是「早餐」"，`analytics_dao_test.dart` 钉住统计口径一致。但计划的要求是
  // "在**所有日历视图**中"——三个页面各自渲染的是 `ScheduleViewItem.title`，
  // 而它们此前确实可以各自把它换掉（日视图的改写对话框、今日页的气泡文案都会碰标题）。
  // 因此这一条从**真实装配链**上再验一次：用户规则 → `PlanningRuleResolver` →
  // `ProtectedTimeExpander` → `RepositoryScheduleViewSource` → 三个页面。
  //
  // 它同时是 R1 的端到端形式：修复前 `_protectedLabel()` 靠 `intervalId.split(':')` 推断，
  // 早餐没有分支，于是三处都显示「保护时间」。
  // ─────────────────────────────────────────────────────────────────────────────
  testWidgets('早餐规则在近期日历、日视图与今日页里都显示「早餐」（R1／人工场景 A）', (tester) async {
    tester.view.physicalSize = const Size(4200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const timeZoneId = 'UTC';
    final zones = TimeZoneDatabase();
    final todayStartUtc = DateTime.utc(2026, 10, 5);
    final clock = _FixedClock(todayStartUtc);
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final taskRepository = DriftTaskRepository(database.taskDao);
    final calendarRepository = DriftCalendarRepository(database);
    final planRepository = DriftPlanRepository(database, clock: clock);
    final settingsRepository = DriftSettingsRepository(database, clock);
    final workspaceRepository = DriftWorkspaceRepository(database);
    final bus = ScheduleViewInvalidationBus();
    addTearDown(bus.dispose);
    final settingsService = SettingsService(
      repository: settingsRepository,
      onPlanningRulesChanged: ScheduleViewInvalidationWiring(bus).planningRules,
    );
    final colors = ScheduleColorService(
      settings: settingsRepository,
      workspace: workspaceRepository,
    );
    final source = RepositoryScheduleViewSource(
      tasks: taskRepository,
      calendar: calendarRepository,
      plans: planRepository,
      history: planRepository,
      rules: PlanningRuleResolver(settingsService),
      colors: colors,
      zones: zones,
      timeZoneId: timeZoneId,
      clock: clock,
      invalidation: bus,
    );

    // 真实异步必须自己推：drift 的写入靠零延时 timer 推进（见 settle 的说明）。
    await tester.runAsync(
      () => settingsService.saveUserRules(
        UserPlanningRules(
          common: PlanningRulesPatch(
            protectedTimes: [
              ProtectedTimeRule(
                kind: ProtectedTimeKind.breakfast,
                range: LocalTimeRange(
                  startMinute: 7 * 60 + 30,
                  endMinute: 8 * 60,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpWidget(
      _threeViews(
        source: source,
        todayStartUtc: todayStartUtc,
        zones: zones,
        timeZoneId: timeZoneId,
        nowUtc: clock.nowUtc(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 30),
    );

    for (final page in const [WeekViewPage, DayViewPage, TodayPage]) {
      expect(
        find.descendant(of: find.byType(page), matching: find.text('早餐')),
        findsWidgets,
        reason:
            '$page 必须显示「早餐」。'
            '**R1**：修复前断言的是「保护时间」——`_protectedLabel()` 按 id 推断类别，'
            '早餐没有分支，于是三处都回落成「保护时间」',
      );
      expect(
        find.descendant(
          of: find.byType(page),
          matching: find.text('breakfast'),
        ),
        findsNothing,
        reason: '$page 不得把英文枚举名当标题显示出来',
      );
    }

    // 卸载三个页面，跑掉 drift 取消订阅时排的零延时 timer（原因同上一条用例）。
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // ═════════════════════════════════════════════════════════════════════════════
  // Task 9：近期日历（八列）的文字缩放矩阵、宽度矩阵与语义。
  //
  // 计划 `2026-10-13-calendar-preview-and-scheduling-integrity-repair.md`
  // §Review Focus 最后三条与 Task 9 Step 1／2／4。上面那些用例都在默认缩放与默认窗口下跑，
  // 而这一页最容易坏的地方恰恰在别处：列宽是**固定 176 px**，字号一放大，
  // 列头与卡片就得自己在列内换行，不能把列撑破。
  //
  // 缩放用 `MediaQuery(textScaler:)`，与 `week_timeline_test.dart` 的既有写法一致
  // （理由见 `day_view_test.dart` 里同一段说明）。
  // ═════════════════════════════════════════════════════════════════════════════

  const longTitle =
      '把数据结构课程设计的最终报告写完并逐条对照评分细则检查一遍再交给助教确认（这一句刻意写得很长，用来验证放大字号之后仍然能读到全文）';

  Future<void> pumpWeek(
    WidgetTester tester, {
    required List<ScheduleViewItem> items,
    double scale = 1,
    Size size = const Size(1280, 1024),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: WeekViewPage(
              source: _Source(Stream.value(items)),
              weekStart: DateTime.utc(2026, 10, 5),
              moveController: _MoveController(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ScheduleViewItem weekItem({
    required String id,
    required String title,
    required ScheduleItemKind kind,
    required DateTime start,
    bool isCompleted = false,
  }) => _scheduleItem(
    id: id,
    title: title,
    kind: kind,
    categoryKey: 'area:study',
    categoryLabel: '学业',
    categoryColorArgb: const Color(0xff2f86ff).toARGB32(),
    categorySortOrder: 0,
    start: start,
    isCompleted: isCompleted,
  );

  group('Task 9 Step 1 文字缩放矩阵（100%／125%／150%／200%）', () {
    for (final scale in const [1.0, 1.25, 1.5, 2.0]) {
      testWidgets('${(scale * 100).round()}% 缩放下八列都在、无布局异常、长标题能读到全文', (
        tester,
      ) async {
        await pumpWeek(
          tester,
          scale: scale,
          items: [
            weekItem(
              id: 'block:long',
              title: longTitle,
              kind: ScheduleItemKind.task,
              start: DateTime.utc(2026, 10, 5, 9),
            ),
          ],
        );

        expect(
          tester.takeException(),
          isNull,
          reason:
              '${(scale * 100).round()}% 缩放下出现了布局异常（`RenderFlex overflowed`／越界）。'
              '列宽固定 176 px，字号放大后列头与卡片必须在列内换行，不能把列撑破',
        );

        // 八列是这一页的产品事实（R12 的修复保留了"昨天 + 今天起七天"），
        // 放大字号不得把它减少或藏掉。
        expect(find.byKey(const Key('week-day--1')), findsOneWidget);
        for (var index = 0; index < 7; index++) {
          expect(
            find.byKey(Key('week-day-$index')),
            findsOneWidget,
            reason:
                '${(scale * 100).round()}% 缩放下第 ${index + 2} 列'
                '（今天起第 ${index + 1} 天）不见了',
          );
        }
        expect(find.byKey(const Key('week-day-7')), findsNothing);

        // **完整标题仍可获知**：卡片可视区域只有 176 px，长标题必然换行；
        // 屏幕上读不全没关系，屏幕阅读器必须读得到全文——那一层语义由
        // `week-card-semantics-<id>` 承载（key 见 `week_view_page.dart`）。
        final semantics = find.byKey(
          const ValueKey('week-card-semantics-block:long'),
        );
        expect(
          semantics,
          findsOneWidget,
          reason: '承载整条语义的那一层必须存在，否则"读得到全文"无从验证',
        );
        final label = tester.getSemantics(semantics).label;
        expect(
          label,
          contains(longTitle),
          reason:
              '${(scale * 100).round()}% 缩放下近期日历必须仍能获知完整标题。'
              '实测语义：<<$label>>',
        );
      });
    }
  });

  group('Task 9 Step 2 宽度矩阵（1024／1280／1920）', () {
    for (final width in const [1024.0, 1280.0, 1920.0]) {
      testWidgets('${width.round()} px 下八列正常渲染、今天那一列在视口内、最后一列滚得到', (
        tester,
      ) async {
        await pumpWeek(
          tester,
          size: Size(width, 1024),
          items: [
            weekItem(
              id: 'fixed:today',
              title: '今天的课',
              kind: ScheduleItemKind.fixed,
              start: DateTime.utc(2026, 10, 7, 8),
            ),
          ],
        );
        // 窄窗口允许横向滚动，但**不允许溢出**。
        expect(
          tester.takeException(),
          isNull,
          reason: '$width px 下近期日历出现布局异常（应改为横向滚动，而不是溢出）',
        );

        final today = tester.getRect(find.byKey(const Key('week-day-0')));
        // 视口宽 = 窗口宽，左右各 20 px 内边距。
        expect(
          today.left,
          greaterThanOrEqualTo(19.0),
          reason: '$width px 下"今天"那一列被推到左边界外',
        );
        expect(
          today.right,
          lessThanOrEqualTo(width - 19.0),
          reason:
              '$width px 下"今天"那一列右边界超出视口（实测 ${today.right} > ${width - 19.0}）——'
              '八列本来就靠横向滚动，但第一屏必须能完整看到今天',
        );
        expect(today.top, lessThan(1024), reason: '$width px 下"今天"那一列整体落在视口下方');

        // 横向滚动仍然可用：八列里最后一列必须滚得到。
        final last = find.byKey(const Key('week-day-6'));
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(last).left,
          lessThan(width),
          reason: '$width px 下最后一列滚进视口之后仍然不可见',
        );
      });
    }
  });

  group('Task 9 Step 4 语义：固定日程不得冒充"已完成"（R11）', () {
    testWidgets('近期日历：固定日程时间已过也读不到"已完成"，真完成的任务才读', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpWeek(
        tester,
        items: [
          // 时间已过的固定日程：上游已把 `isCompleted` 收紧成"只属于
          // `TaskStatus.completed`"，这一条从**页面侧**再钉一次。
          weekItem(
            id: 'fixed:past',
            title: '早场',
            kind: ScheduleItemKind.fixed,
            start: DateTime.utc(2026, 10, 5, 7),
          ),
          weekItem(
            id: 'block:done',
            title: '已经做完的事',
            kind: ScheduleItemKind.task,
            start: DateTime.utc(2026, 10, 5, 9),
            isCompleted: true,
          ),
        ],
      );

      String labelOf(String id) => tester
          .getSemantics(find.byKey(ValueKey('week-card-semantics-$id')))
          .label;

      // 前置：两条都真的渲染了，否则下面的断言是空的。
      expect(
        find.byKey(const ValueKey('week-schedule-card-fixed:past')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('week-schedule-completed-fixed:past')),
        findsNothing,
        reason: '**R11**：固定日程结束时间已过 ≠ 任务已完成，不得出现完成勾',
      );
      expect(
        labelOf('fixed:past'),
        isNot(contains('已完成')),
        reason:
            '**R11**：屏幕阅读器不得把一条时间已过的固定日程读成"已完成"。'
            '实测语义：<<${labelOf('fixed:past')}>>',
      );
      expect(
        labelOf('block:done'),
        contains('已完成'),
        reason:
            '真完成的任务必须照旧读"已完成"，否则这条修改会波及任务块。'
            '实测语义：<<${labelOf('block:done')}>>',
      );

      handle.dispose();
    });
  });

  testWidgets('周期块在周视图显示「完成本次」入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final start = DateTime.utc(2026, 10, 5);
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeekViewPage(
            source: _Source(
              Stream.value([
                _scheduleItem(
                  id: 'block:recurring-1',
                  title: '每周阅读',
                  kind: ScheduleItemKind.task,
                  categoryKey: 'area:study',
                  categoryLabel: '学业',
                  categoryColorArgb: 0xff2f86ff,
                  categorySortOrder: 0,
                  start: start.add(const Duration(hours: 10)),
                ),
                ScheduleViewItem(
                  id: 'block:recurring-2',
                  title: '每周英语',
                  kind: ScheduleItemKind.task,
                  range: TimeRange(
                    startUtc: _recurringStart,
                    endUtc: _recurringEnd,
                  ),
                  categoryKey: 'area:study',
                  categoryLabel: '学业',
                  categoryColorArgb: 0xff2f86ff,
                  categorySortOrder: 0,
                  taskId: 'recurring:template:2026-10-05',
                  recurringGoal: RecurringGoalBadge(
                    templateId: 'template',
                    title: '每周英语',
                    recordedMinutes: 0,
                    targetMinutes: 60,
                  ),
                ),
              ]),
            ),
            weekStart: start,
            moveController: _MoveController(),
            onCompleteItem: (_) => completed = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('week-complete-block:recurring-2')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('week-complete-block:recurring-2')),
    );
    expect(completed, isTrue);
  });
}

final _recurringStart = DateTime.utc(2026, 10, 7, 10);
final _recurringEnd = DateTime.utc(2026, 10, 7, 11);

ScheduleViewItem _scheduleItem({
  required String id,
  required String title,
  required ScheduleItemKind kind,
  required String categoryKey,
  required String categoryLabel,
  required int categoryColorArgb,
  required int categorySortOrder,
  required DateTime start,
  bool isCompleted = false,
}) => ScheduleViewItem(
  id: id,
  title: title,
  kind: kind,
  categoryKey: categoryKey,
  categoryLabel: categoryLabel,
  categoryColorArgb: categoryColorArgb,
  categorySortOrder: categorySortOrder,
  isCompleted: isCompleted,
  range: TimeRange(
    startUtc: start,
    endUtc: start.add(const Duration(hours: 1)),
  ),
);

/// 记录数据源被请求过的窗口，用来证明"昨天那一列真的订阅了"。
final class _RangeRecorder {
  final List<(DateTime, DateTime)> ranges = [];
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

/// 三个视图**同时**挂在树上：谁都没有被路由切走，也没有人点过"刷新"。
///
/// 给每页一个固定尺寸并用横向滚动兜住，避免三页挤在一起产生与被测行为无关的布局溢出。
Widget _threeViews({
  required ScheduleViewSource source,
  required DateTime todayStartUtc,
  required TimeZoneDatabase zones,
  required String timeZoneId,
  required DateTime nowUtc,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 1100,
            height: 2000,
            child: WeekViewPage(
              source: source,
              weekStart: todayStartUtc,
              moveController: const DisabledWeekMoveController(),
            ),
          ),
          SizedBox(
            width: 1100,
            height: 2000,
            child: DayViewPage(
              source: source,
              dayStartUtc: todayStartUtc,
              zones: zones,
              timeZoneId: timeZoneId,
            ),
          ),
          SizedBox(
            width: 1100,
            height: 2000,
            child: TodayPage(
              source: source,
              day: todayStartUtc,
              toLocal: (instantUtc) => zones.toLocal(instantUtc, timeZoneId),
              nowUtc: nowUtc,
            ),
          ),
        ],
      ),
    ),
  ),
);

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
