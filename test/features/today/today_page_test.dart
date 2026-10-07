import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
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

  testWidgets('图例只显示当天可见的领域和特殊分类', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(
          source: _Source(
            Stream.value([
              _item(
                'study',
                '算法作业',
                ScheduleItemKind.task,
                day,
                9,
                categoryKey: 'area:study',
                categoryLabel: '学业',
                categoryColorArgb: 0xff2f86ff,
                categorySortOrder: 0,
              ),
              _item(
                'lunch',
                '午餐时间',
                ScheduleItemKind.protectedTime,
                day,
                12,
                categoryKey: 'special:protected',
                categoryLabel: '保护时间',
                categoryColorArgb: 0xff5ec8e5,
                categorySortOrder: 10000,
              ),
            ]),
          ),
          day: day,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('schedule-category-area:study')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('schedule-category-special:protected')),
      findsOneWidget,
    );
    expect(find.text('固定'), findsNothing);
    expect(find.text('可移动任务'), findsNothing);
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
      categoryKey: 'special:protected',
      categoryLabel: '保护时间',
      categoryColorArgb: 0xff5ec8e5,
      categorySortOrder: 10000,
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
    // 今日容量和图例都按动态分类展示。
    expect(find.text('任务与生活'), findsNothing);
    expect(
      find.byKey(const Key('today-capacity-category-test:fixed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('today-capacity-category-test:protectedTime')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('today-capacity-category-test:task')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('today-capacity-category-test:life')),
      findsOneWidget,
    );
    expect(find.text('可移动任务'), findsNothing);
  });

  testWidgets('卡片颜色来自分类且正文只显示分类名称', (tester) async {
    const categoryColor = Color(0xfff06f7a);
    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(
          source: _Source(
            Stream.value([
              _item(
                'contest',
                '准备竞赛',
                ScheduleItemKind.task,
                day,
                9,
                categoryKey: 'area:contest',
                categoryLabel: '竞赛',
                categoryColorArgb: categoryColor.toARGB32(),
                categorySortOrder: 2,
              ),
            ]),
          ),
          day: day,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final card = tester.widget<Container>(
      find.byKey(const Key('today-schedule-card-contest')),
    );
    final decoration = card.decoration! as BoxDecoration;
    final border = decoration.border! as Border;
    final expected = scheduleCategoryCardStyle(categoryColor);
    // 卡片填充必须是共享派生器的不透明深色——旧版这里是 `alpha: 0.10`，比七日历还浅。
    expect(decoration.color, expected.fill);
    expect(decoration.color!.toARGB32() >>> 24, 0xff);
    expect(border.top.color, expected.border);
    // 左侧强调条与分类图标保留分类原色，只用于小面积强调。
    expect(
      tester
          .widget<ColoredBox>(
            find.byKey(const Key('today-schedule-accent-contest')),
          )
          .color,
      expected.accent,
    );
    expect(
      tester
          .widget<Icon>(find.byKey(const Key('today-schedule-icon-contest')))
          .color,
      expected.accent,
    );
    // 珊瑚色的验收常量（与实现文档的八色表逐格一致）：写死数值，这样"把公式调回半透明"
    // 会在这里红掉，而不是只对比一个同样被改过的对象。
    expect(expected.fill.toARGB32(), 0xff62191f);
    expect(expected.border.toARGB32(), 0xff88222b);
    expect(find.text('09:00–10:00 · 竞赛'), findsWidgets);
    expect(find.text('09:00–10:00 · 任务'), findsNothing);
    expect(
      tester
          .getSemantics(find.byKey(const Key('today-schedule-contest')))
          .label,
      contains('任务'),
    );
  });

  testWidgets('容量条在有安排时真的画得出来，各段铺满高度', (tester) async {
    // 这条和"左侧强调条"是同一类缺陷：`Row` 默认居中对齐 + 无子节点的 `ColoredBox` = 0 高，
    // 控件树里有、颜色也对，屏幕上什么都没有。区别是它的**空态**反而一直可见（那是个普通
    // `Container(height: 7)`），所以现象是"有数据时容量条消失"，很容易被当成设计如此。
    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(
          source: _Source(
            Stream.value([
              _item(
                'study',
                '算法作业',
                ScheduleItemKind.task,
                day,
                9,
                categoryKey: 'area:study',
                categoryLabel: '学业',
                categoryColorArgb: const Color(0xff2f86ff).toARGB32(),
                categorySortOrder: 0,
              ),
            ]),
          ),
          day: day,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final bar = find.byKey(const Key('today-capacity-bar'));
    expect(bar, findsOneWidget);
    final segments = find.descendant(
      of: bar,
      matching: find.byType(ColoredBox),
    );
    expect(segments, findsWidgets, reason: '容量条应当按分类切成若干段');
    for (var index = 0; index < segments.evaluate().length; index++) {
      final size = tester.getSize(segments.at(index));
      expect(size.height, greaterThan(0), reason: '第 $index 段容量条高度为 0，画不出来');
      expect(
        size.height,
        closeTo(7, 0.5),
        reason: '第 $index 段容量条没有铺满容器给的 7 像素高度',
      );
    }
  });

  testWidgets('今日的领域任务、保护时间与无领域任务各用共享深色卡片', (tester) async {
    const studyColor = Color(0xff2f86ff);
    const protectedColor = Color(0xff5ec8e5);
    const unassignedColor = Color(0xff7f92b2);
    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(
          source: _Source(
            Stream.value([
              _item(
                'study',
                '算法作业',
                ScheduleItemKind.task,
                day,
                9,
                categoryKey: 'area:study',
                categoryLabel: '学业',
                categoryColorArgb: studyColor.toARGB32(),
                categorySortOrder: 0,
              ),
              _item(
                'lunch',
                '午餐时间',
                ScheduleItemKind.protectedTime,
                day,
                12,
                categoryKey: 'special:protected',
                categoryLabel: '保护时间',
                categoryColorArgb: protectedColor.toARGB32(),
                categorySortOrder: 10000,
              ),
              _item(
                'loose',
                '零散任务',
                ScheduleItemKind.task,
                day,
                15,
                categoryKey: 'special:unassigned-task',
                categoryLabel: '未分类任务',
                categoryColorArgb: unassignedColor.toARGB32(),
                categorySortOrder: 10001,
              ),
            ]),
          ),
          day: day,
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final (id, color, icon) in <(String, Color, IconData)>[
      ('study', studyColor, Icons.task_alt),
      ('lunch', protectedColor, Icons.shield_outlined),
      ('loose', unassignedColor, Icons.task_alt),
    ]) {
      final expected = scheduleCategoryCardStyle(color);
      final decoration =
          tester
                  .widget<Container>(find.byKey(Key('today-schedule-card-$id')))
                  .decoration!
              as BoxDecoration;
      expect(decoration.color, expected.fill, reason: '$id 的填充');
      expect(
        (decoration.border! as Border).top.color,
        expected.border,
        reason: '$id 的完整边框',
      );
      expect(decoration.color!.toARGB32() >>> 24, 0xff, reason: '$id 必须不透明');
      // 左侧强调条、分类图标与时间轴圆点保留分类原色，只用于小面积强调。
      expect(
        tester
            .widget<ColoredBox>(find.byKey(Key('today-schedule-accent-$id')))
            .color,
        expected.accent,
      );
      // **只断言颜色是不够的**：这条竖条曾经"存在但画不出来"——行内默认居中对齐 + 无子节点的
      // `ColoredBox` 会被量成 0 高，于是 `tester.widget<ColoredBox>(...).color` 照样通过，屏幕上
      // 却什么都没有（用户就是这么发现的）。因此这里断言它**真的有面积**，而且铺满卡片内区。
      //
      // 参照值不写死：卡片的 `getSize` 含外边距，内区高度 = 盒高 − 外边距 − 上下边框。把它从卡片
      // 自己的 `margin` / `border` 推出来，改内边距或外边距时这条断言不会变成无意义的常数比较。
      final stripSize = tester.getSize(
        find.byKey(Key('today-schedule-accent-$id')),
      );
      expect(stripSize.height, greaterThan(0), reason: '$id 的左侧强调条高度为 0，画不出来');
      expect(stripSize.width, greaterThan(0), reason: '$id 的左侧强调条宽度为 0');

      final card = tester.widget<Container>(
        find.byKey(Key('today-schedule-card-$id')),
      );
      final cardBox = tester.getSize(
        find.byKey(Key('today-schedule-card-$id')),
      );
      final cardMargin = (card.margin! as EdgeInsets).vertical;
      final cardBorder = (card.decoration! as BoxDecoration).border! as Border;
      final cardInnerHeight =
          cardBox.height -
          cardMargin -
          cardBorder.top.width -
          cardBorder.bottom.width;
      expect(
        stripSize.height,
        closeTo(cardInnerHeight, 0.5),
        reason:
            '$id 的左侧强调条没有铺满卡片内区（内区 $cardInnerHeight，竖条 ${stripSize.height}）',
      );
      expect(
        tester.widget<Icon>(find.byKey(Key('today-schedule-icon-$id'))).color,
        expected.accent,
      );
      expect(
        tester.widget<Icon>(find.byKey(Key('today-schedule-icon-$id'))).icon,
        icon,
      );
      final dot =
          tester
                  .widget<Container>(
                    find.descendant(
                      of: find.byKey(ValueKey('today-schedule-$id')),
                      matching: find.byWidgetPredicate(
                        (widget) =>
                            widget is Container &&
                            widget.decoration is BoxDecoration &&
                            (widget.decoration! as BoxDecoration).shape ==
                                BoxShape.circle,
                      ),
                    ),
                  )
                  .decoration!
              as BoxDecoration;
      expect(dot.color, expected.accent, reason: '$id 的时间轴圆点必须用小面积强调色');
    }

    // 跨页面一致性：今日、七日历、单日详情对同一个分类色（学业蓝 `#2f86ff`）必须得到同一组
    // ARGB。三个页面的测试各自钉住这三个字面值，任何一处自己另算一遍都会在那里红掉。
    final shared = scheduleCategoryCardStyle(studyColor);
    expect(shared.accent.toARGB32(), 0xff2f86ff);
    expect(shared.fill.toARGB32(), 0xff17345b);
    expect(shared.border.toARGB32(), 0xff20487f);
    expect(
      (tester
                  .widget<Container>(
                    find.byKey(const Key('today-schedule-card-study')),
                  )
                  .decoration!
              as BoxDecoration)
          .color,
      shared.fill,
    );

    // 卡片正文只显示分类标签；类型仍由图标与语义表达。
    expect(find.textContaining('· 学业'), findsWidgets);
    expect(find.textContaining('· 保护时间'), findsWidgets);
    expect(find.textContaining('· 未分类任务'), findsWidgets);
  });

  testWidgets('已完成的条目显示完成标记，未完成的不显示', (tester) async {
    // 标记的两个来源：任务被勾选完成、固定日程结束时间已过。这里只验证渲染，
    // 判定来源由 `schedule_view_source_test.dart` 守着。
    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(
          source: _Source(
            Stream.value([
              ScheduleViewItem(
                id: 'done',
                title: '已完成的事',
                kind: ScheduleItemKind.task,
                categoryKey: 'area:study',
                categoryLabel: '学业',
                categoryColorArgb: 0xff2f86ff,
                categorySortOrder: 0,
                isCompleted: true,
                range: TimeRange(
                  startUtc: day.add(const Duration(hours: 9)),
                  endUtc: day.add(const Duration(hours: 10)),
                ),
              ),
              _item('open', '未完成的事', ScheduleItemKind.task, day, 11),
            ]),
          ),
          day: day,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('today-schedule-completed-done')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('today-schedule-completed-open')),
      findsNothing,
    );
    // 标记要进无障碍语义：看不见图标的用户也要能知道它已完成。
    expect(
      tester.getSemantics(find.byKey(const Key('today-schedule-done'))).label,
      contains('已完成'),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('today-schedule-open'))).label,
      isNot(contains('已完成')),
    );
  });

  testWidgets('跨午夜日程按当天片段汇总并保留分类元数据', (tester) async {
    final overnight = ScheduleViewItem(
      id: 'overnight',
      title: '跨夜整理',
      kind: ScheduleItemKind.task,
      categoryKey: 'area:research',
      categoryLabel: '科研',
      categoryColorArgb: 0xff53c7a5,
      categorySortOrder: 1,
      range: TimeRange(
        startUtc: day.subtract(const Duration(minutes: 30)),
        endUtc: day.add(const Duration(minutes: 45)),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TodayPage(source: _Source(Stream.value([overnight])), day: day),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('00:00–00:45 · 科研'), findsWidgets);
    expect(find.text('45 分钟'), findsWidgets);
    expect(
      find.byKey(const Key('schedule-category-area:research')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('today-capacity-category-area:research')),
      findsOneWidget,
    );
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
  int hour, {
  String? categoryKey,
  String? categoryLabel,
  int? categoryColorArgb,
  int? categorySortOrder,
}) => ScheduleViewItem(
  id: id,
  title: title,
  kind: kind,
  categoryKey: categoryKey ?? 'test:${kind.name}',
  categoryLabel: categoryLabel ?? kind.label,
  categoryColorArgb: categoryColorArgb ?? 0xff456789,
  categorySortOrder: categorySortOrder ?? kind.index,
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
