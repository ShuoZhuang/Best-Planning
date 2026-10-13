// R3/FR-CAL-03：日视图。
//
// 与周视图共用同一个 `ScheduleViewSource`，差别是**按本机时区显示时刻**——周视图的卡片
// 只给类型与标题。因此这里最要紧的断言不是"渲染了几个卡片"，而是"时刻按给定时区换算"，
// 以及"类型不只靠颜色区分"（需求 §12）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/calendar_event_edit.dart';
import 'package:personal_planner/features/calendar/day_view/day_view_page.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
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

final class _StreamItems implements ScheduleViewSource {
  const _StreamItems(this.stream);
  final Stream<List<ScheduleViewItem>> stream;

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      stream;
}

ScheduleViewItem _item({
  required String id,
  required String title,
  required ScheduleItemKind kind,
  required int startHourUtc,
  int durationHours = 1,
  String? categoryKey,
  String? categoryLabel,
  int? categoryColorArgb,
  int? categorySortOrder,
  String notes = '',
  // **默认 `true`**：这一页多数用例关心的是"三个范围选项各自走哪条路"，
  // 而范围选项只在重复事项上出现。一次性事项那一条另有专门用例。
  bool repeats = true,
}) => ScheduleViewItem(
  id: id,
  title: title,
  kind: kind,
  categoryKey: categoryKey ?? 'test:${kind.name}',
  categoryLabel: categoryLabel ?? kind.label,
  categoryColorArgb: categoryColorArgb ?? 0xff456789,
  categorySortOrder: categorySortOrder ?? kind.index,
  notes: notes,
  repeats: repeats,
  range: TimeRange(
    startUtc: DateTime.utc(2026, 10, 5, startHourUtc),
    endUtc: DateTime.utc(2026, 10, 5, startHourUtc + durationHours),
  ),
);

/// 把一次改写请求摊成测试关心的三件事：**锚点、范围、改成了什么样**。
///
/// 用记录而不是 `(id, start, end, title)` 那样的元组：范围是这一批新增的判据，
/// 而元组的位置参数一多，"第几个是什么"就得靠数——那正是最容易断言错的地方。
final class EditRecord {
  const EditRecord(this.request);
  final OccurrenceEditRequest request;

  String get anchorId => request.anchorId;
  EventEditScope get scope => request.scope;
  CalendarEventEditDraft get draft => request.draft;
  String get title => request.draft.title;
  String get notes => request.draft.notes;
  DateTime get startUtc => request.draft.startAtUtc;
  DateTime get endUtc => request.draft.endAtUtc;
}

final _dayStartUtc = DateTime.utc(2026, 10, 5);

/// 用日期选择器把"改这一次"对话框里的结束日期改成 [day] 号。
///
/// **必须真的走选择器**：1.8.0 起对话框用 `PlannerDateField`（规范 §8.2：与固定日程编辑器
/// 复用同一组件），文本输入那条路已经不存在。测试若还能"输入日期"，说明实现没换。
Future<void> _setOccurrenceEndDate(WidgetTester tester, int day) async {
  await tester.tap(find.byKey(const Key('occurrence-end-date-box')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('$day').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<ScheduleViewItem> items,
    String timeZoneId = 'UTC',
    Future<bool> Function(String eventId)? onDeleteEvent,
    Future<OccurrenceEditOutcome> Function(OccurrenceEditRequest request)?
    onEditEvent,
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
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: DayViewPage(
            source: _Items(items),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: timeZoneId,
            onDeleteEvent: onDeleteEvent,
            onEditEvent: onEditEvent,
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

  testWidgets('按给定时区显示时刻与分类，类型由图标和语义保留', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:event-1',
          title: '数据结构课',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
          categoryKey: 'area:study',
          categoryLabel: '学业',
          categoryColorArgb: 0xff2f86ff,
          categorySortOrder: 0,
        ),
        _item(
          id: 'block:block-1',
          title: '写方案',
          kind: ScheduleItemKind.task,
          startHourUtc: 14,
          categoryKey: 'area:study',
          categoryLabel: '学业',
          categoryColorArgb: 0xff2f86ff,
          categorySortOrder: 0,
        ),
      ],
    );

    expect(find.textContaining('09:00–10:00'), findsOneWidget);
    expect(find.textContaining('14:00–15:00'), findsOneWidget);
    expect(find.textContaining('学业'), findsNWidgets(3));
    expect(find.textContaining('固定日程'), findsNothing);
    expect(find.textContaining('任务'), findsNothing);
    expect(find.byIcon(Icons.event), findsOneWidget);
    expect(find.byIcon(Icons.task_alt), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const Key('day-item-fixed:event-1')))
          .label,
      contains('固定日程'),
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('day-item-block:block-1')))
          .label,
      contains('任务'),
    );
    expect(find.text('写方案'), findsOneWidget);
  });

  testWidgets('单日卡片使用分类色且数据刷新后立即更新', (tester) async {
    const firstColor = Color(0xff2f86ff);
    const secondColor = Color(0xfff06f7a);
    final controller = StreamController<List<ScheduleViewItem>>();
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(controller.close);
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: DayViewPage(
            source: _StreamItems(controller.stream),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
          ),
        ),
      ),
    );

    ScheduleViewItem item(int color, String label) => _item(
      id: 'block:refresh',
      title: '整理资料',
      kind: ScheduleItemKind.task,
      startHourUtc: 9,
      categoryKey: 'area:current',
      categoryLabel: label,
      categoryColorArgb: color,
      categorySortOrder: 0,
    );

    controller.add([item(firstColor.toARGB32(), '学业')]);
    await tester.pump();
    // 卡片颜色只能来自共享派生器：不透明深色填充 + 低亮描边。
    void expectCardColor(Color categoryColor) {
      final expected = scheduleCategoryCardStyle(categoryColor);
      final card = tester.widget<Card>(
        find.byKey(const Key('day-schedule-card-block:refresh')),
      );
      expect(card.color, expected.fill);
      expect(
        (card.shape! as RoundedRectangleBorder).side.color,
        expected.border,
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(const Key('day-schedule-card-block:refresh')),
                matching: find.byIcon(Icons.task_alt),
              ),
            )
            .color,
        expected.accent,
      );
    }

    expectCardColor(firstColor);
    expect(
      find.descendant(
        of: find.byKey(const Key('day-schedule-card-block:refresh')),
        matching: find.textContaining('学业'),
      ),
      findsOneWidget,
    );

    controller.add([item(secondColor.toARGB32(), '竞赛')]);
    await tester.pump();
    expectCardColor(secondColor);
    expect(
      find.descendant(
        of: find.byKey(const Key('day-schedule-card-block:refresh')),
        matching: find.textContaining('竞赛'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('day-schedule-card-block:refresh')),
        matching: find.textContaining('学业'),
      ),
      findsNothing,
    );
  });

  testWidgets('单日详情的学业、生活、保护时间与无领域任务各用共享深色卡片', (tester) async {
    const studyColor = Color(0xff2f86ff);
    const lifeColor = Color(0xffb391d3);
    const protectedColor = Color(0xff5ec8e5);
    const unassignedColor = Color(0xff7f92b2);
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:class',
          title: '数据结构课',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 8,
          categoryKey: 'area:study',
          categoryLabel: '学业',
          categoryColorArgb: studyColor.toARGB32(),
          categorySortOrder: 0,
        ),
        _item(
          id: 'block:homework',
          title: '算法作业',
          kind: ScheduleItemKind.task,
          startHourUtc: 10,
          categoryKey: 'area:study',
          categoryLabel: '学业',
          categoryColorArgb: studyColor.toARGB32(),
          categorySortOrder: 0,
        ),
        _item(
          id: 'block:movie',
          title: '看电影',
          kind: ScheduleItemKind.life,
          startHourUtc: 12,
          categoryKey: 'area:life',
          categoryLabel: '生活',
          categoryColorArgb: lifeColor.toARGB32(),
          categorySortOrder: 4,
        ),
        _item(
          id: 'protected:lunch:1',
          title: '午餐时间',
          kind: ScheduleItemKind.protectedTime,
          startHourUtc: 13,
          categoryKey: 'special:protected',
          categoryLabel: '保护时间',
          categoryColorArgb: protectedColor.toARGB32(),
          categorySortOrder: 10000,
        ),
        _item(
          id: 'block:loose',
          title: '零散任务',
          kind: ScheduleItemKind.task,
          startHourUtc: 15,
          categoryKey: 'special:unassigned-task',
          categoryLabel: '未分类任务',
          categoryColorArgb: unassignedColor.toARGB32(),
          categorySortOrder: 10001,
        ),
      ],
    );

    for (final (id, color, icon) in <(String, Color, IconData)>[
      ('fixed:class', studyColor, Icons.event),
      ('block:homework', studyColor, Icons.task_alt),
      ('block:movie', lifeColor, Icons.self_improvement),
      ('protected:lunch:1', protectedColor, Icons.shield_outlined),
      ('block:loose', unassignedColor, Icons.task_alt),
    ]) {
      final expected = scheduleCategoryCardStyle(color);
      final card = tester.widget<Card>(
        find.byKey(Key('day-schedule-card-$id')),
      );
      expect(card.color, expected.fill, reason: '$id 的填充');
      expect(card.color!.toARGB32() >>> 24, 0xff, reason: '$id 的填充必须不透明');
      expect(card.surfaceTintColor, Colors.transparent);
      expect(
        (card.shape! as RoundedRectangleBorder).side.color,
        expected.border,
        reason: '$id 的描边',
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(Key('day-schedule-card-$id')),
                matching: find.byIcon(icon),
              ),
            )
            .color,
        expected.accent,
        reason: '$id 的图标强调色',
      );
    }

    // 同学业的固定日程与任务同色，只由图标区分；类型标签不进卡片正文。
    expect(
      tester
          .widget<Card>(find.byKey(const Key('day-schedule-card-fixed:class')))
          .color,
      tester
          .widget<Card>(
            find.byKey(const Key('day-schedule-card-block:homework')),
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
          .widget<Card>(find.byKey(const Key('day-schedule-card-fixed:class')))
          .color,
      shared.fill,
    );
  });

  testWidgets('单日详情为已完成条目显示完成标记', (tester) async {
    await pump(
      tester,
      items: [
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
            startUtc: DateTime.utc(2026, 10, 5, 9),
            endUtc: DateTime.utc(2026, 10, 5, 10),
          ),
        ),
        _item(
          id: 'block:open',
          title: '还没做的事',
          kind: ScheduleItemKind.task,
          startHourUtc: 11,
          categoryKey: 'area:study',
          categoryLabel: '学业',
          categoryColorArgb: 0xff2f86ff,
          categorySortOrder: 0,
        ),
      ],
    );

    // 标记不取代操作入口，也不改标题与分类。
    expect(find.text('已经做完的事'), findsOneWidget);
    expect(
      find.byKey(const Key('day-schedule-completed-block:done')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('day-schedule-completed-block:open')),
      findsNothing,
    );
    expect(
      tester.getSemantics(find.byKey(const Key('day-item-block:done'))).label,
      contains('已完成'),
    );
    // 完成与未完成同领域 → 同色。
    expect(
      tester
          .widget<Card>(find.byKey(const Key('day-schedule-card-block:done')))
          .color,
      tester
          .widget<Card>(find.byKey(const Key('day-schedule-card-block:open')))
          .color,
    );
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
      onEditEvent: (request) async => OccurrenceEditOutcome.saved,
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

  testWidgets('自定义保护时间**可以**改与删（规范 §9.3）', (tester) async {
    // 与上一条的区别在 id 的前缀：上一条的 `protected:sleep` 是**规则来源**的保护时间，
    // 库里有没对应行；这一条的 `fixed:<eventId>` 是用户自己建的一条 `CalendarEvent`
    // （`kind: protected`），它与固定日程共用同一套"仅本次／此次及以后／整个系列"语义。
    // 只认 `fixed` 会让保护时间建完之后在日视图里**没有任何入口**去改它。
    final deleted = <String>[];
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:evt-protected',
          title: '每周二下午保护',
          kind: ScheduleItemKind.protectedTime,
          startHourUtc: 14,
        ),
      ],
      onDeleteEvent: (id) async {
        deleted.add(id);
        return true;
      },
      onEditEvent: (request) async => OccurrenceEditOutcome.saved,
    );

    await tester.ensureVisible(
      find.byKey(const Key('edit-fixed:evt-protected')),
    );
    await tester.tap(find.byKey(const Key('edit-fixed:evt-protected')));
    await tester.pumpAndSettle();
    expect(
      find.text('改「每周二下午保护」的这一次'),
      findsOneWidget,
      reason: '保护时间的改写入口必须打开同一个对话框',
    );
    await tester.tap(find.byKey(const Key('occurrence-cancel')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('delete-fixed:evt-protected')),
    );
    await tester.tap(find.byKey(const Key('delete-fixed:evt-protected')));
    await tester.pumpAndSettle();
    // 删除要先问范围。
    expect(find.textContaining('删除'), findsWidgets);
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
      onEditEvent: (request) async => OccurrenceEditOutcome.saved,
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
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
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
    final replaced = <EditRecord>[];
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
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
            onEditEvent: (request) async {
              replaced.add(EditRecord(request));
              return OccurrenceEditOutcome.saved;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('edit-fixed:event-1')));
    await tester.tap(find.byKey(const Key('edit-fixed:event-1')));
    await tester.pumpAndSettle();

    // 先试非法输入：**必须在对话框内说明并留下**，而不是把非法区间交给下游。
    //
    // 1.8.0 起对话框用选择器字段（规范 §8.2：复用同一组件和校验），**文本输入这条路
    // 已经不存在**——"输入非法值"在界面上无从发生。因此这里验证剩下那条真的可能出错的
    // 输入：**结束日期落在开始之前**。它必须被对话框挡住并说明。
    await _setOccurrenceEndDate(tester, 4);
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('occurrence-error')), findsOneWidget);
    expect(replaced, isEmpty);

    // 再改成合法时间：结果交给回调（本地时刻，UTC 换算由路由负责）。
    await _setOccurrenceEndDate(tester, 6);
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    expect(replaced, hasLength(1));
    expect(replaced.single.anchorId, 'event-1');
    // **按 UTC 断言，不按 `.day`**：这一页用 `timeZoneId: 'UTC'` 渲染，而回调收到的是
    // **UTC** 时刻——`.day` 在两种口径下会差一天（本地 10-06 18:00 = UTC 10-06 10:00，
    // 而同一天的起点 UTC 09:00 的 `.day` 是 05）。原用例同样按 UTC 比（14:00/15:00）。
    expect(replaced.single.startUtc, DateTime.utc(2026, 10, 5, 9));
    expect(
      replaced.single.endUtc,
      DateTime.utc(2026, 10, 6, 10),
      reason: '结束日期改到次日 ⇒ 结束时刻整体后移一天',
    );
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
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
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
            onEditEvent: (request) async {
              if (request.scope == EventEditScope.entireSeries) {
                series.add(request.anchorId);
              } else {
                single.add(request.anchorId);
              }
              return OccurrenceEditOutcome.saved;
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
    // 1.8.0 起这里**不接受文本输入**（规范 §8.1：不给输入非法值的可能），
    // 因此不再"输入时间"，而是改结束日期为次日来推进这次改写。
    await _setOccurrenceEndDate(tester, 6);
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
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
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
            onEditEvent: (request) async {
              switch (request.scope) {
                case EventEditScope.singleOccurrence:
                  single.add(request.anchorId);
                case EventEditScope.followingOccurrences:
                  following.add(request.anchorId);
                case EventEditScope.entireSeries:
                  series.add(request.anchorId);
              }
              return OccurrenceEditOutcome.saved;
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
    // 1.8.0 起这里**不接受文本输入**（规范 §8.1：不给输入非法值的可能），
    // 因此不再"输入时间"，而是改结束日期为次日来推进这次改写。
    await _setOccurrenceEndDate(tester, 6);
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

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 1（课程与保护时间管理修复计划 §1.2）：**"改这一次"必须能改标题与备注**
  //
  // 现状：对话框只有日期与时间；保存时把原 `item.title` **原样传回**
  // （见 `_editOccurrence` 的最后一次调用）。因此用户**无法改名**。
  //
  // 计划 §2.3 要求三种范围都允许修改标题、备注、日期与时间。这一组把
  // "预填 + 回传新标题"钉住。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**改写对话框预填当前标题与备注**（不是空框、也不是只读）', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: DayViewPage(
            source: _Items([
              _item(
                id: 'fixed:evt-protected',
                title: '午休保护',
                kind: ScheduleItemKind.protectedTime,
                startHourUtc: 4,
              ),
            ]),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
            onDeleteEvent: (id) async => true,
            onEditEvent: (request) async => OccurrenceEditOutcome.saved,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('edit-fixed:evt-protected')));
    await tester.pumpAndSettle();

    final title = find.byKey(const Key('occurrence-title'));
    expect(
      title,
      findsOneWidget,
      reason: '计划 §2.3："三种范围都允许修改标题、备注、日期与时间"——标题是其中第一项',
    );
    expect(
      tester.widget<TextField>(title).controller!.text,
      '午休保护',
      reason: '必须**预填**当前值：空框会让用户以为原标题丢了，从而重新输入一遍',
    );
    expect(
      find.byKey(const Key('occurrence-notes')),
      findsOneWidget,
      reason: '备注也是 §2.3 列出的可改字段',
    );
  });

  testWidgets('**改标题后回调收到新标题**，而不是旧的 `item.title`', (tester) async {
    final titles = <String>[];
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: DayViewPage(
            source: _Items([
              _item(
                id: 'fixed:evt-protected',
                title: '午休保护',
                kind: ScheduleItemKind.protectedTime,
                startHourUtc: 4,
              ),
            ]),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
            onDeleteEvent: (id) async => true,
            onEditEvent: (request) async {
              titles.add(request.draft.title);
              return OccurrenceEditOutcome.saved;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('edit-fixed:evt-protected')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('occurrence-title')), '看医生');
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    expect(
      titles,
      ['看医生'],
      reason:
          '修复前这里回传的是 `item.title`（原样传回），于是"改名"这件事在界面上'
          '根本无从发生——用户改了框里的字，保存之后一切照旧',
    );
  });

  testWidgets('**一次性事项不显示三个同义选项**（计划 Task 8 Step 3）', (tester) async {
    // 一条没有重复规则的保护时间上，三个范围是同一件事。摆出来会让用户以为
    // "仅本次"与"整个系列"不同，从而在选择上犹豫——而选哪个结果都一样。
    final records = <EditRecord>[];
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:evt-once',
          title: '看医生',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
          repeats: false,
        ),
      ],
      onEditEvent: (request) async {
        records.add(EditRecord(request));
        return OccurrenceEditOutcome.saved;
      },
    );

    await tester.tap(find.byKey(const Key('edit-fixed:evt-once')));
    await tester.pumpAndSettle();

    expect(find.text('仅本次'), findsNothing);
    expect(find.text('本次及以后'), findsNothing, reason: '没有规则就无从"从这一次起拆分"');
    expect(find.text('整个系列'), findsNothing);

    // 表单照常可用，保存**仍然走得通**（只是没有范围可选，隐含"就改这一条"）。
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    expect(
      records.single.scope,
      EventEditScope.singleOccurrence,
      reason: '没有范围可选时隐含的就是"改这一条"，而不是"什么都不做"',
    );
  });

  testWidgets('**备注被带到写入请求里**（此前对话框收得到、回调没有位置放）', (tester) async {
    final records = <EditRecord>[];
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:evt-protected',
          title: '午休保护',
          kind: ScheduleItemKind.protectedTime,
          startHourUtc: 4,
          notes: '原备注',
        ),
      ],
      onEditEvent: (request) async {
        records.add(EditRecord(request));
        return OccurrenceEditOutcome.saved;
      },
    );

    await tester.tap(find.byKey(const Key('edit-fixed:evt-protected')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('occurrence-notes')), '带医保卡');
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    expect(
      records.single.notes,
      '带医保卡',
      reason: '修复前 `OccurrenceEditResult.notes` 收到了却没人用，保存后备注消失',
    );
    expect(
      records.single.draft.kind,
      CalendarEventKind.protected,
      reason:
          '**类别不能丢**：保护时间被改写成固定日程之后会进入投入统计'
          '（规范 §9.1 明确保护时间不计入任何投入）',
    );
  });

  testWidgets('**改写失败时如实提示**，不假装成功', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:evt-protected',
          title: '午休保护',
          kind: ScheduleItemKind.protectedTime,
          startHourUtc: 4,
        ),
      ],
      onEditEvent: (request) async => OccurrenceEditOutcome.failed,
    );

    await tester.tap(find.byKey(const Key('edit-fixed:evt-protected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('occurrence-edit-failed')), findsOneWidget);
  });

  testWidgets('**数据过期时说"重新打开"而不是"重试"**', (tester) async {
    // 两种失败要用户做的事完全不同：`failed` 可以重试，`stale` 重试永远不会成功
    // ——必须先关掉重开。把它们说成同一句会让用户反复点同一个按钮。
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:evt-protected',
          title: '午休保护',
          kind: ScheduleItemKind.protectedTime,
          startHourUtc: 4,
        ),
      ],
      onEditEvent: (request) async => OccurrenceEditOutcome.stale,
    );

    await tester.tap(find.byKey(const Key('edit-fixed:evt-protected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('occurrence-edit-stale')), findsOneWidget);
    expect(
      find.textContaining('重新打开'),
      findsOneWidget,
      reason: 'stale 要用户做的事是重新打开，而不是重试',
    );
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
    // 首次教程闸门与首次引导是同一条套路（设置键 + 版本比较）。不喂这一条，
    // 整应用 pump 出来的会是教程页而不是主界面——教程自身的用例在 test/features/tutorial/。
    // ignore: unused_local_variable
    await settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
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
