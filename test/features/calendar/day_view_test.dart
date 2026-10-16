// R3/FR-CAL-03：日视图。
//
// 与周视图共用同一个 `ScheduleViewSource`，差别是**按本机时区显示时刻**——周视图的卡片
// 只给类型与标题。因此这里最要紧的断言不是"渲染了几个卡片"，而是"时刻按给定时区换算"，
// 以及"类型不只靠颜色区分"（需求 §12）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/design/planner_localization.dart';
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
  bool fromRules = false,
  bool isCompleted = false,
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
  fromRules: fromRules,
  isCompleted: isCompleted,
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

  /// **patch 而不是草稿**（计划 §2.0.1）：请求里只有用户真的改过的字段，
  /// 因此"这一次改写会不会顺手清掉地点／领域／项目／类别"这件事在这里就已经答完了。
  CalendarEventPatch get patch => request.patch;
  String get title => request.patch.title;
  String get notes => request.patch.notes;
  DateTime get startUtc => request.patch.startAtUtc;
  DateTime get endUtc => request.patch.endAtUtc;

  /// 地点这一项**根本没有进请求**（保留语义），因此它应当是 `null`／`KeepField`。
  bool get keepsLocation => request.patch.location == null;
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

/// 日视图卡片上四种动作的 key 前缀（计划 §2.7）。
///
/// 与**旧图标按钮同名**：Task 3 把它们从 `IconButton` 挪到了 `PopupMenuItem` 上，
/// 名字不变，于是"哪一条的哪一个动作"这套定位方式不必重学。
const _dayItemActions = <String>['edit', 'area', 'delete', 'settings'];

/// 打开某一条的更多菜单，点选 [action]（`edit`／`area`／`delete`／`settings`）。
///
/// Task 3（计划 §2.7）把"每类各自渲染几枚图标按钮"换成了**每行一个** `more_vert` 菜单，
/// 因此"点删除"这件事在界面上变成两步：先打开菜单，再点菜单项。
/// 这个助手把两步收在一处，既有的 48 处交互只换路径、不改断言。
Future<void> _openActions(
  WidgetTester tester,
  String itemId,
  String action,
) async {
  final trigger = find.byKey(Key('actions-$itemId'));
  await tester.ensureVisible(trigger);
  await tester.pumpAndSettle();
  await tester.tap(trigger);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('$action-$itemId')));
  await tester.pumpAndSettle();
}

/// 打开某一条的更多菜单，返回菜单里**实际出现**的动作（按 [_dayItemActions] 的顺序）。
///
/// 用于断言能力表：菜单**只列可执行动作**，不多也不少。
Future<List<String>> _openActionsMenu(
  WidgetTester tester,
  String itemId,
) async {
  final trigger = find.byKey(Key('actions-$itemId'));
  await tester.ensureVisible(trigger);
  await tester.pumpAndSettle();
  await tester.tap(trigger);
  await tester.pumpAndSettle();
  final present = _dayItemActions
      .where(
        (action) => find.byKey(Key('$action-$itemId')).evaluate().isNotEmpty,
      )
      .toList();
  // 关掉菜单，别让下一条断言在"上一条的菜单还开着"的状态下跑。
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
  return present;
}

/// 断言某一条的菜单里**没有** [action] 这一项。
///
/// 没有菜单（动作数为 0 ⇒ 等宽空槽）同样算通过：这一批断言要表达的是
/// "用户点不到这个动作"，而不是"菜单必须存在"——§2.7 恰恰要求没有可执行动作时
/// 不渲染菜单，更不渲染一枚点不动的灰色图标（U5）。
Future<void> _expectNoAction(
  WidgetTester tester,
  String itemId,
  String action,
) async {
  expect(find.byKey(Key('$action-$itemId')), findsNothing);
  final trigger = find.byKey(Key('actions-$itemId'));
  if (trigger.evaluate().isEmpty) return;
  await tester.ensureVisible(trigger);
  await tester.pumpAndSettle();
  await tester.tap(trigger);
  await tester.pumpAndSettle();
  expect(find.byKey(Key('$action-$itemId')), findsNothing);
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

// ─────────────────────────────────────────────────────────────────────────────
// Task 9 的共享工具（语义树的真实读取、键盘焦点定位）。
//
// 与 `test/app/accessibility_semantics_test.dart` 的同名工具**同一套做法**：
// 读的是**实跑出来的语义树**，而不是 widget 树里的 `Semantics` 配置。
// 只看源码会以为"label 已经写好了"，而只有把树读出来才知道它有没有被子节点覆盖、
// 有没有被 `excludeSemantics` 吃掉——这一页的卡片恰恰是后者。
// ─────────────────────────────────────────────────────────────────────────────

/// 语义树里第一个满足 [matches] 的节点数据；没有就返回 `null`。
SemanticsData? _semanticsData(
  WidgetTester tester,
  bool Function(SemanticsData data) matches,
) {
  // `binding.pipelineOwner` 在 3.10 之后被标记为弃用，但它仍是此处唯一能拿到
  // 当前测试树语义根的入口（改 `rootPipelineOwner` 会遍历不到节点）。
  // ignore: deprecated_member_use
  final owner = tester.binding.pipelineOwner.semanticsOwner;
  final root = owner?.rootSemanticsNode;
  if (root == null) return null;
  SemanticsData? found;
  void walk(SemanticsNode node) {
    if (found != null) return;
    final data = node.getSemanticsData();
    if (matches(data)) {
      found = data;
      return;
    }
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return found;
}

/// 当前键盘焦点是否落在 [finder] 命中的那棵子树里。
///
/// 不能只比 `primaryFocus.context == 元素`：焦点挂在 `InkWell` / `PopupMenuButton`
/// 内部的 `Focus` 上，而断言要问的是"焦点在这一行的更多按钮上吗"。
bool _focusInside(WidgetTester tester, Finder finder) {
  final element = tester.binding.focusManager.primaryFocus?.context;
  if (element is! Element) return false;
  final roots = finder.evaluate();
  if (roots.isEmpty) return false;
  final root = roots.first;
  if (identical(element, root)) return true;
  var inside = false;
  element.visitAncestorElements((ancestor) {
    if (identical(ancestor, root)) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

/// 反复按 Tab（有界）直到焦点落进 [finder]；返回是否到达。
///
/// **有界**是刻意的：写死"按 N 次 Tab"会把一次无关的焦点重排变成红，
/// 而这条用例真正要证明的是"Tab 最终能走到这个控件上"。
Future<bool> _tabUntilFocused(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    if (_focusInside(tester, finder)) return true;
  }
  return false;
}

/// 焦点当前所在的条目 id（只认 `actions-<id>` 这个触发按钮）；不在任何触发按钮上时为 `null`。
String? _focusedActionItemId(WidgetTester tester) {
  final element = tester.binding.focusManager.primaryFocus?.context;
  if (element is! Element) return null;
  String? id;
  var isTrigger = false;
  element.visitAncestorElements((ancestor) {
    final key = ancestor.widget.key;
    if (key is ValueKey<String> && key.value.startsWith('actions-')) {
      // 最内层那个才是这一行的触发按钮；继续往上会走到 ListView。
      id = key.value.substring('actions-'.length);
      isTrigger = true;
      return false;
    }
    return true;
  });
  return isTrigger ? id : null;
}

/// 焦点当前所在菜单项的可读文字（用于断言"方向键停在「编辑」上"）。
String? _focusedActionButtonLabel(WidgetTester tester) {
  final element = tester.binding.focusManager.primaryFocus?.context;
  if (element is! Element) return null;
  String? label;
  void visit(Element node) {
    if (label != null) return;
    final widget = node.widget;
    if (widget is Text && widget.data != null) {
      label = widget.data;
      return;
    }
    node.visitChildren(visit);
  }

  element.visitChildren(visit);
  return label;
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
    VoidCallback? onOpenProtectedTimeSettings,
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
            onOpenProtectedTimeSettings: onOpenProtectedTimeSettings,
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

  // ─────────────────────────────────────────────────────────────────────────────
  // R11（Task 1 Step 5）：固定日程的钟点过去了，**不得**出现完成标记。
  //
  // 上游数据源已经把 `isCompleted` 收紧成"只属于 `TaskStatus.completed`"；这一条
  // 从页面侧钉住同一件事：一条 `kind: fixed` 且 `isCompleted: false` 的条目（时间
  // 已经过去的那种）不能渲染 `day-schedule-completed-*`。
  //
  // 上游那一条断言在 `schedule_view_source_test.dart`（R11 的根因），这里断言的是
  // "页面不会自己再算一遍完成"——两处都错才会让用户看到那个完成勾。
  // ─────────────────────────────────────────────────────────────────────────────
  testWidgets('固定日程时间已过（上游 isCompleted=false）不出现 day-schedule-completed（R11）', (
    tester,
  ) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'fixed:past',
          title: '早场',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 7,
          durationHours: 1,
          isCompleted: false,
        ),
        // 反面：任务真的完成了，标记必须照旧出现。
        _item(
          id: 'block:done',
          title: '已经做完的事',
          kind: ScheduleItemKind.task,
          startHourUtc: 9,
          durationHours: 1,
          isCompleted: true,
        ),
      ],
    );

    expect(
      find.byKey(const Key('day-schedule-card-fixed:past')),
      findsOneWidget,
      reason: '夹具必须真的渲染出那条固定日程',
    );
    expect(
      find.byKey(const Key('day-schedule-completed-fixed:past')),
      findsNothing,
      reason:
          '**R11**：固定日程结束时间已过 ≠ 任务已完成。'
          '完成标记只属于 `TaskStatus.completed`，页面不得自行按钟点补一个',
    );
    // 语义标签里也不能出现"已完成"。
    expect(
      tester.getSemantics(find.byKey(const Key('day-item-fixed:past'))).label,
      isNot(contains('已完成')),
    );
    expect(
      find.byKey(const Key('day-schedule-completed-block:done')),
      findsOneWidget,
      reason: '真完成的任务照旧带标记——这条改动不该波及任务块',
    );
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

    expect(
      find.byKey(const Key('actions-fixed:event-1')),
      findsOneWidget,
      reason: '§2.7 起删除收进单个更多菜单：入口是 `actions-<id>`，不再是 `delete-<id>`',
    );
    await _openActions(tester, 'fixed:event-1', 'delete');
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

    // 这两类条目**一个可执行动作都没有**：计划块属于计划（该撤销计划，而不是删一条
    // 日程），`protected:sleep` 也拿不到领域事件 id。按 §2.7 它们渲染**等宽空槽**：
    // 既没有菜单，也没有菜单项。
    //
    // 旧断言是"图标在但点不动"——它要表达的正是"用户点不到"。新形态用"根本没有这个
    // 动作"表达同一件事，而且不再给屏幕阅读器一个"这里有操作"的假信号（U5）。
    for (final itemId in const ['block:block-1', 'protected:sleep']) {
      expect(
        find.byKey(Key('actions-$itemId')),
        findsNothing,
        reason: '$itemId 没有可执行动作 ⇒ 只渲染等宽空槽，不渲染菜单',
      );
      for (final action in _dayItemActions) {
        expect(
          find.byKey(Key('$action-$itemId')),
          findsNothing,
          reason: '**U5**：$itemId 不该出现「$action」入口',
        );
      }
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

    await _openActions(tester, 'fixed:evt-protected', 'edit');
    expect(
      find.text('改「每周二下午保护」的这一次'),
      findsOneWidget,
      reason: '保护时间的改写入口必须打开同一个对话框',
    );
    await tester.tap(find.byKey(const Key('occurrence-cancel')));
    await tester.pumpAndSettle();

    await _openActions(tester, 'fixed:evt-protected', 'delete');
    // 删除要先问范围。
    expect(find.textContaining('删除'), findsWidgets);
  });

  testWidgets('菜单只列**可执行**动作：固定日程三项，自定义保护时间两项（计划 §2.7）', (tester) async {
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
          id: 'fixed:evt-protected',
          title: '每周二下午保护',
          kind: ScheduleItemKind.protectedTime,
          startHourUtc: 14,
        ),
      ],
      onDeleteEvent: (id) async => true,
      onEditEvent: (request) async => OccurrenceEditOutcome.saved,
      onSetEventArea: (eventId, areaId) async => true,
      onOpenProtectedTimeSettings: () {},
    );

    // 四个端口全开时，菜单里出现的应当**只有**这一类条目真能执行的动作：
    // 领域只属于固定日程（保护时间在数据里没有 `areaId` 这一栏），
    // 而「去设置」只属于规则来源的保护时间。
    expect(
      await _openActionsMenu(tester, 'fixed:event-1'),
      unorderedEquals(<String>['edit', 'area', 'delete']),
      reason: '固定日程：编辑、调整所属领域、删除',
    );
    expect(
      await _openActionsMenu(tester, 'fixed:evt-protected'),
      unorderedEquals(<String>['edit', 'delete']),
      reason: '自定义保护时间：编辑、删除——**不给**"调整所属领域"',
    );
  });

  testWidgets('所有条目的卡片等宽：每行都留出**固定 48 px** 的操作槽（与可用性无关）', (tester) async {
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

    // 固定日程带三项动作、任务块一项都没有；两者的卡片宽度必须**完全一样**——
    // 图标位的宽度与"这条能不能删"无关（计划 §1.1 R2 / §2.7）。
    final fixed = tester.getRect(
      find.byKey(const Key('day-schedule-card-fixed:event-1')),
    );
    final task = tester.getRect(
      find.byKey(const Key('day-schedule-card-block:block-1')),
    );
    expect(task.width, fixed.width, reason: '固定日程带删除/编辑/归属，其余条目也必须为同样的操作槽留出宽度');

    // 而且这个宽度是**固定的 48 px**：卡片右边界到列表右边界之间恒为槽宽。
    // 只断言"两者相等"还不够——把两个槽一起改成 0 也会相等，那时右边界齐了，
    // 但"更多"按钮会紧贴卡片边缘、没有可点区域。
    final list = tester.getRect(find.byType(ListView));
    expect(
      list.right - fixed.right,
      moreOrLessEquals(48, epsilon: 0.01),
      reason: '有动作的行右侧必须是 48 px 操作槽',
    );
    expect(
      list.right - task.right,
      moreOrLessEquals(48, epsilon: 0.01),
      reason: '没有动作的行右侧同样留出 48 px 空槽，否则卡片会比别人宽',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // R2（Task 1 Step 5）：**四类卡片的右边界必须完全一致**。
  //
  // `_DayItemTile` 外部的操作按钮数量随条目类型变化，而卡片又包在 `Expanded` 里：
  //   任务        → delete + area + edit（3 个）
  //   固定日程    → delete + area + edit（3 个）
  //   自定义保护  → delete + area + edit（3 个）
  //   **规则保护** → delete + **settings** + area + edit（4 个）
  // 于是规则保护时间那一行的卡片比其它三行**窄 48 px**，整列右边界参差 —— 用户报的
  // 正是这个（计划 §1.1 R2 / §2.7：所有行都有固定 48 px 操作槽）。
  //
  // 断言用 `getTopLeft/getTopRight` 的**横坐标**而不是宽度：宽度只说明"大小相同"，
  // 而用户看到的是"右边界在不在同一条竖线上"。
  // ─────────────────────────────────────────────────────────────────────────────
  testWidgets('任务、固定日程、自定义保护时间、规则保护时间四类卡片右边界完全一致（R2）', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'block:task-1',
          title: '写方案',
          kind: ScheduleItemKind.task,
          startHourUtc: 8,
        ),
        _item(
          id: 'fixed:event-1',
          title: '数据结构课',
          kind: ScheduleItemKind.fixed,
          startHourUtc: 9,
        ),
        _item(
          id: 'fixed:evt-protected',
          title: '自定义保护',
          kind: ScheduleItemKind.protectedTime,
          startHourUtc: 10,
        ),
        _item(
          id: 'protected:breakfast:2026-10-05:450',
          title: '早餐',
          kind: ScheduleItemKind.protectedTime,
          startHourUtc: 11,
          fromRules: true,
        ),
      ],
      // 四个入口全开：这正是"规则来源保护时间多一枚 settings 按钮"的前提。
      onDeleteEvent: (id) async => true,
      onEditEvent: (request) async => OccurrenceEditOutcome.saved,
      onSetEventArea: (eventId, areaId) async => true,
      onOpenProtectedTimeSettings: () {},
    );

    const ids = [
      'block:task-1',
      'fixed:event-1',
      'fixed:evt-protected',
      'protected:breakfast:2026-10-05:450',
    ];

    final rights = <String, double>{};
    final lefts = <String, double>{};
    for (final id in ids) {
      final rect = tester.getRect(find.byKey(Key('day-schedule-card-$id')));
      rights[id] = rect.right;
      lefts[id] = rect.left;
    }

    for (final id in ids.skip(1)) {
      expect(lefts[id], lefts[ids.first], reason: '四类卡片的左边界也必须一致（它们在同一列里）');
      expect(
        rights[id],
        rights[ids.first],
        reason:
            '**R2**：$id 的右边界与 ${ids.first} 不相等'
            '（实测 ${rights[id]} vs ${rights[ids.first]}）。'
            '原因是规则来源的保护时间多一枚 settings 按钮，把卡片挤窄了 48 px。'
            '计划 §2.7 要求每行都是「卡片占满剩余宽度 + 固定 48 px 操作槽」',
      );
    }

    // 四类都必须真的渲染出来，否则上面的循环会"因为找不到元素而失败"，
    // 那条失败说明的是夹具问题而不是布局问题。
    for (final id in ids) {
      expect(
        find.byKey(Key('day-schedule-card-$id')),
        findsOneWidget,
        reason: '夹具必须真的渲染出 $id',
      );
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // U5（Task 1 Step 5）：**不可用的操作不得以三枚灰色图标占位**。
  //
  // 计划 §2.7 的固定形态：没有可执行动作时用等宽空槽，不显示灰色按钮；
  // 规则来源的保护时间只显示"去设置"。三枚 `onPressed: null` 的图标既占宽度
  // 又给屏幕阅读器一个"这里有操作"的假信号。
  // ─────────────────────────────────────────────────────────────────────────────
  testWidgets('规则保护时间只有"去设置"一个可用操作，不出现不可点击的删除/归属/编辑三连（U5）', (tester) async {
    await pump(
      tester,
      items: [
        _item(
          id: 'protected:breakfast:2026-10-05:450',
          title: '早餐',
          kind: ScheduleItemKind.protectedTime,
          startHourUtc: 8,
          fromRules: true,
        ),
      ],
      onDeleteEvent: (id) async => true,
      onEditEvent: (request) async => OccurrenceEditOutcome.saved,
      onSetEventArea: (eventId, areaId) async => true,
      onOpenProtectedTimeSettings: () {},
    );

    const itemId = 'protected:breakfast:2026-10-05:450';

    // 1. 规则来源的保护时间**有一个**可执行动作，因此有更多菜单。
    final trigger = find.byKey(const Key('actions-$itemId'));
    expect(trigger, findsOneWidget, reason: '唯一可执行的入口是「去设置」，它必须能被点到');

    // 2. 打开它：菜单里**恰好只有**「去设置」一项。
    await tester.ensureVisible(trigger);
    await tester.pumpAndSettle();
    await tester.tap(trigger);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings-$itemId')),
      findsOneWidget,
      reason: '规则来源的保护时间必须能"去设置"',
    );
    for (final action in const ['delete', 'area', 'edit']) {
      expect(
        find.byKey(Key('$action-$itemId')),
        findsNothing,
        reason:
            '**U5**：「$action」对规则来源的保护时间不可执行'
            '（它既删不掉、也改不了，更不能调整归属——库里没有对应的锚点行）。'
            '计划 §2.7 要求"菜单只列可执行动作"，因此它连菜单项都不该出现。',
      );
    }
    expect(
      find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      findsOneWidget,
      reason: '规则来源的保护时间只有一个动作 ⇒ 菜单里恰好一项',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 3. U5 的**真正判据**：整页不存在任何 `onPressed: null` 的 `IconButton`。
    //
    // 三枚灰色图标既占宽度又给屏幕阅读器一个"这里有操作"的假信号；这一条把它整体禁掉，
    // 比"逐个点名那三枚图标"更能防回归——以后任何人再加一枚点不动的图标，这里都会红。
    final disabled = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .where((button) => button.onPressed == null)
        .toList();
    expect(
      disabled,
      isEmpty,
      reason:
          '**U5**：页面上有 ${disabled.length} 枚 `onPressed: null` 的灰色图标。'
          '计划 §2.7 要求"没有动作时用等宽空槽，不显示灰色按钮"。',
    );
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

    await _openActions(tester, 'fixed:event-1', 'area');
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

    await _openActions(tester, 'fixed:event-1', 'area');
    await tester.tap(find.byKey(const Key('area-picker-cancel')));
    await tester.pumpAndSettle();

    // "取消"与"选择不归属领域"都是 null，必须区分开：取消不该被当成一次真实的清空。
    expect(calls, isEmpty);
  });

  testWidgets('非日程条目不能调整归属（任务块那一行根本没有菜单）', (tester) async {
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

    // 旧断言是"归属图标在但点不动"（`onPressed == null`）——它要表达的正是
    // "用户点不到"。§2.7 下同一件事由"任务块一个可执行动作都没有"来表达：
    // 整行只有一个等宽空槽，没有菜单，也就没有「调整所属领域」这一项。
    // 区别是屏幕阅读器不会再把这一行读成"这里有操作"。
    expect(
      find.byKey(const Key('actions-block:block-1')),
      findsNothing,
      reason: '任务块没有可执行动作 ⇒ 只渲染等宽空槽',
    );
    await _expectNoAction(tester, 'block:block-1', 'area');
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

    await _openActions(tester, 'fixed:event-1', 'delete');
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
    await _openActions(tester, 'fixed:event-1', 'delete');
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

    await _openActions(tester, 'fixed:event-1', 'edit');

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

  testWidgets('未注入改写入口时菜单里不出现「编辑」', (tester) async {
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

    // 这一条注入了删除、没注入改写，因此菜单**在**，只是里面不该有「编辑」：
    // 宁可没有这一项，也不要一个点了不生效的图标。
    await _expectNoAction(tester, 'fixed:event-1', 'edit');
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

    await _openActions(tester, 'fixed:event-1', 'edit');
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

    await _openActions(tester, 'fixed:event-1', 'edit');
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

    await _openActions(tester, 'fixed:event-1', 'delete');
    await tester.tap(find.byKey(const Key('delete-cancel')));
    await tester.pumpAndSettle();

    // 未注入改写入口时连菜单里都没有「编辑」。
    await _expectNoAction(tester, 'fixed:event-1', 'edit');
  });

  testWidgets('未注入删除入口时菜单里不出现「删除」', (tester) async {
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

    // 一个回调都没注入 ⇒ 这一条**一个动作都没有**，因此连菜单都不渲染（等宽空槽）。
    // 宁可没有入口，也不要一个点了不生效的图标。
    expect(
      find.byKey(const Key('actions-fixed:event-1')),
      findsNothing,
      reason: '没有可执行动作 ⇒ 只渲染等宽空槽，不渲染一个空菜单',
    );
    await _expectNoAction(tester, 'fixed:event-1', 'delete');
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

    await _openActions(tester, 'fixed:evt-protected', 'edit');

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
              titles.add(request.patch.title);
              return OccurrenceEditOutcome.saved;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openActions(tester, 'fixed:evt-protected', 'edit');
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

    await _openActions(tester, 'fixed:evt-once', 'edit');

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

    await _openActions(tester, 'fixed:evt-protected', 'edit');
    await tester.enterText(find.byKey(const Key('occurrence-notes')), '带医保卡');
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    expect(
      records.single.notes,
      '带医保卡',
      reason: '修复前 `OccurrenceEditResult.notes` 收到了却没人用，保存后备注消失',
    );
    // **类别与地点不在请求里**（计划 §2.0.1／CE2）：保护时间被改写成固定日程之后会进入
    // 投入统计（规范 §9.1 明确保护时间不计入任何投入）。这条安全属性现在由
    // **写入端**保证——patch 里没有 `kind`／`areaId`／`projectId` 的入口，
    // 仓储只能从锚点保留它们。因此这里断言的是"请求没有越权携带这些字段"，
    // 而"落库后类别仍是 protected"由 `recurrence_exception_test.dart` 的真实仓储用例守着。
    expect(
      records.single.keepsLocation,
      isTrue,
      reason: '日视图不展示地点：它必须以"保持原值"表达，而不是被写成空串',
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

    await _openActions(tester, 'fixed:evt-protected', 'edit');
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

    await _openActions(tester, 'fixed:evt-protected', 'edit');
    await tester.tap(find.byKey(const Key('occurrence-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('occurrence-edit-stale')), findsOneWidget);
    expect(
      find.textContaining('重新打开'),
      findsOneWidget,
      reason: 'stale 要用户做的事是重新打开，而不是重试',
    );
  });

  testWidgets('**规则来源的保护时间给「去设置」，自定义的给「编辑／删除」**', (tester) async {
    // 两类保护时间在界面上必须区别对待：**自定义的**（有 `CalendarEvent` 锚点）
    // 能改名、能删；**规则来源的**（睡眠／早餐／午餐／晚餐／固定休息）没有锚点，
    // 只能在设置页改规则。计划 §2.3 末段写明了这个区别。
    var openedSettings = 0;
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: DayViewPage(
            source: _Items([
              _item(
                id: 'fixed:evt-custom',
                title: '自定义保护',
                kind: ScheduleItemKind.protectedTime,
                startHourUtc: 4,
              ),
              // 规则来源的那一条：显式标记 `fromRules`。
              _item(
                id: 'protected:lunch:2026-10-05:1',
                title: '午餐保护',
                kind: ScheduleItemKind.protectedTime,
                startHourUtc: 12,
                fromRules: true,
              ),
            ]),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
            onDeleteEvent: (id) async => true,
            onEditEvent: (request) async => OccurrenceEditOutcome.saved,
            onOpenProtectedTimeSettings: () => openedSettings++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 自定义的那一条：菜单里有编辑与删除，**没有**「去设置」。
    await tester.ensureVisible(
      find.byKey(const Key('actions-fixed:evt-custom')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('actions-fixed:evt-custom')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-fixed:evt-custom')), findsOneWidget);
    expect(find.byKey(const Key('delete-fixed:evt-custom')), findsOneWidget);
    expect(
      find.byKey(const Key('settings-fixed:evt-custom')),
      findsNothing,
      reason: '「去设置」只属于规则来源的保护时间——自定义的那一条在这一页就能改',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 规则来源的那一条：没有编辑入口（改不了），但有「去设置」，而且只有它。
    final settingsTrigger = find.byKey(
      const Key('actions-protected:lunch:2026-10-05:1'),
    );
    expect(
      settingsTrigger,
      findsOneWidget,
      reason:
          '不给入口等于告诉用户这条东西没法改，而它其实改得了——'
          '只是要在设置页改规则',
    );
    await tester.ensureVisible(settingsTrigger);
    await tester.pumpAndSettle();
    await tester.tap(settingsTrigger);
    await tester.pumpAndSettle();

    for (final action in const ['edit', 'delete', 'area']) {
      expect(
        find.byKey(Key('$action-protected:lunch:2026-10-05:1')),
        findsNothing,
        reason: '规则来源的保护时间「$action」不了，菜单里就不该有这一项',
      );
    }
    final settings = find.byKey(
      const Key('settings-protected:lunch:2026-10-05:1'),
    );
    expect(settings, findsOneWidget);
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(openedSettings, 1);
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
    expect(find.text('近期日历'), findsOneWidget);

    final openDay = find.byKey(const Key('open-day-view'));
    expect(openDay, findsOneWidget);
    await tester.ensureVisible(openDay);
    await tester.tap(openDay);
    await tester.pumpAndSettle();

    // 日视图与周视图互为切换，因此两者都可达且不占导航项。
    expect(find.byType(DayViewPage), findsOneWidget);
    expect(find.byKey(const Key('open-week-view')), findsOneWidget);
  });

  // ═════════════════════════════════════════════════════════════════════════════
  // Task 9：文字缩放矩阵、窗口宽度矩阵与键盘路径。
  //
  // 计划 `2026-10-13-calendar-preview-and-scheduling-integrity-repair.md` 的
  // §Review Focus 最后三条与 Task 9 Step 1～3。上面那些用例证明的是"在 1000×1600、
  // 100% 缩放下行为正确"，而用户报的三件事恰恰都发生在**别的形状**下：
  // 放大字之后长标题看不全、窄窗口里操作被挤掉、以及只能用键盘时寸步难行。
  //
  // **缩放为什么用 `MediaQuery(textScaler:)` 而不是
  // `tester.platformDispatcher.textScaleFactorTestValue`**：本仓库既有的缩放门禁
  // （`test/features/tasks/task_type_chooser_test.dart`、
  // `test/features/planning/recurring_shortfall_preview_test.dart`、
  // `test/features/calendar/week_timeline_test.dart`）全部用前者，本页测试因此沿用同一写法。
  // 两者在**文字度量**上等价，但前者还额外钉住了一件本仓库真的会碰到的行为：
  // `lib/features/today/today_page.dart` 与 `week_view/timeline_day_column.dart` 会读
  // `MediaQuery.textScalerOf(context)` 来自己决定高度/封顶，而它们读的正是这个 `MediaQuery`。
  // 用 `platformDispatcher` 那条路时页面内既有的 `MediaQuery` 会被整体替换，
  // 这两种实现差异就测不出来了。
  // ═════════════════════════════════════════════════════════════════════════════

  /// 一条长到必然换行的标题。**写死字面量**：它要在断言里逐字比对。
  const longTitle =
      '把数据结构课程设计的最终报告写完并逐条对照评分细则检查一遍再交给助教确认（这一句刻意写得很长，用来验证放大字号之后仍然能读到全文）';

  /// 日视图的一整天：一条长标题任务块、一条固定日程、一条规则来源的保护时间。
  ///
  /// 三类一次到齐是因为它们的**操作槽宽度相同而动作数量不同**（0／3／1）：
  /// 计划 §2.7 的不变量正是"宽度与可用性无关"，缩放后最容易坏的就是这一处。
  List<ScheduleViewItem> matrixItems() => [
    _item(
      id: 'block:long',
      title: longTitle,
      kind: ScheduleItemKind.task,
      startHourUtc: 8,
    ),
    _item(
      id: 'fixed:course-1',
      title: '数据结构课',
      kind: ScheduleItemKind.fixed,
      startHourUtc: 10,
    ),
    _item(
      id: 'protected:breakfast:2026-10-05:450',
      title: '早餐',
      kind: ScheduleItemKind.protectedTime,
      startHourUtc: 12,
      fromRules: true,
    ),
  ];

  /// 按给定缩放与视口泵出日视图；四个操作端口全开（"规则保护时间只有去设置"的前提）。
  Future<void> pumpDayView(
    WidgetTester tester, {
    double scale = 1,
    Size size = const Size(1024, 1600),
    VoidCallback? onOpenProtectedTimeSettings,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: DayViewPage(
              source: _Items(matrixItems()),
              dayStartUtc: _dayStartUtc,
              zones: TimeZoneDatabase(),
              timeZoneId: 'UTC',
              onDeleteEvent: (id) async => true,
              onEditEvent: (request) async => OccurrenceEditOutcome.saved,
              onSetEventArea: (eventId, areaId) async => true,
              onOpenProtectedTimeSettings: onOpenProtectedTimeSettings ?? () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Task 9 Step 1 文字缩放矩阵（100%／125%／150%／200%）', () {
    for (final scale in const [1.0, 1.25, 1.5, 2.0]) {
      testWidgets('${(scale * 100).round()}% 缩放下无布局异常，且长标题仍可获知全文', (
        tester,
      ) async {
        await pumpDayView(tester, scale: scale);

        // ① 布局异常：溢出与越界都以异常形式从渲染管线抛出来，
        //    `takeException()` 是唯一能把它读出来的入口。
        //
        // **必须叫出它抓的是哪一类**：这一页现在没有别的异常源，因此"非空"就是
        // `RenderFlex overflowed`（横向或纵向）或渲染越界；以后再冒出别的异常，
        // 失败信息里的真实异常类型会指出它不是布局问题。
        expect(
          tester.takeException(),
          isNull,
          reason:
              '${(scale * 100).round()}% 缩放下出现了布局异常。'
              '`RenderFlex overflowed`／越界都由渲染管线以异常形式抛出，'
              '用户看到的是卡片里的字被切掉或整列错位',
        );

        // ② 三类条目都真的渲染了：溢出断言在"什么都没画"时也会绿。
        for (final id in const [
          'block:long',
          'fixed:course-1',
          'protected:breakfast:2026-10-05:450',
        ]) {
          expect(
            find.byKey(Key('day-schedule-card-$id')),
            findsOneWidget,
            reason: '夹具必须真的渲染出 $id，否则上面的"无异常"是空断言',
          );
        }

        // ③ **长标题的完整内容仍可获知**。这一页的卡片把子语义整棵排除
        //    （`_DayItemTile` 的 `excludeSemantics: true`），因此"读得到全文"只有一条路：
        //    那个容器语义节点的 label 里必须**逐字**含完整标题。
        //    只断言 `find.text(longTitle)` 会漏掉真正的缺陷——文字被裁掉时
        //    widget 树里那句 `Text` 依然在，用户却读不到。
        final long = _semanticsData(
          tester,
          (data) => data.label.contains('把数据结构课程设计的最终报告'),
        );
        expect(long, isNotNull, reason: '长标题那一条必须有一个语义节点（否则屏幕阅读器读不到它）');
        expect(
          long!.label,
          contains(longTitle),
          reason:
              '${(scale * 100).round()}% 缩放下长标题的完整内容必须仍可获知。'
              '实测语义 label 是：<<${long.label}>>',
        );

        // ④ 那一行还要留在视口内：放大之后被挤到屏幕外同样等于"看不到"。
        final listRect = tester.getRect(find.byType(ListView));
        final cardRect = tester.getRect(
          find.byKey(const Key('day-schedule-card-block:long')),
        );
        expect(
          cardRect.top,
          lessThan(listRect.bottom),
          reason: '长标题那一条滚到视口下方去了 ⇒ 放大字号之后用户看不到它',
        );
        expect(
          cardRect.bottom,
          greaterThan(listRect.top),
          reason: '长标题那一条滚到视口上方去了',
        );
      });
    }
  });

  group('Task 9 Step 2 窗口宽度矩阵（1024／1280／1920）', () {
    for (final width in const [1024.0, 1280.0, 1920.0]) {
      testWidgets('${width.round()} px 下四类卡片右边界一致、操作槽恒为 48 px', (tester) async {
        // 四类**同页**：任务块（0 个动作）、固定日程（编辑/归属/删除）、
        // 规则保护时间（只有去设置）。计划 §2.7 的几何契约是
        // "卡片占满剩余宽度 + 固定 48 px 操作槽"，与这一行有几个动作无关。
        await pumpDayView(tester, size: Size(width, 1600));
        expect(tester.takeException(), isNull, reason: '$width px 下不应有布局异常');

        final list = tester.getRect(find.byType(ListView));
        final rights = <String, double>{};
        for (final id in const [
          'block:long',
          'fixed:course-1',
          'protected:breakfast:2026-10-05:450',
        ]) {
          final rect = tester.getRect(find.byKey(Key('day-schedule-card-$id')));
          rights[id] = rect.right;
          expect(
            list.right - rect.right,
            moreOrLessEquals(48, epsilon: 0.01),
            reason:
                '$width px 下 $id 的右边界到列表右边界不是 48 px（实测 ${list.right - rect.right}）。'
                '规则来源的保护时间只有一枚「去设置」，它的槽宽也必须与固定日程的三枚一样',
          );
        }
        expect(
          rights.values.toSet(),
          hasLength(1),
          reason: '$width px 下四类卡片的右边界不在同一条竖线上（R2 回归）：$rights',
        );
      });

      testWidgets('${width.round()} px 下更多操作菜单能打开并点到菜单项', (tester) async {
        await pumpDayView(tester, size: Size(width, 1600));
        expect(tester.takeException(), isNull, reason: '$width px 下不应有布局异常');

        final trigger = find.byKey(const Key('actions-fixed:course-1'));
        await tester.ensureVisible(trigger);
        await tester.pumpAndSettle();

        // 触发按钮必须落在视口内——"能打开"的前提是它没有被裁掉。
        final viewport = tester.getRect(find.byType(ListView));
        final triggerRect = tester.getRect(trigger);
        expect(
          triggerRect.top,
          greaterThanOrEqualTo(viewport.top - 0.01),
          reason: '$width px 下更多按钮滚出了视口顶部',
        );
        expect(
          triggerRect.bottom,
          lessThanOrEqualTo(viewport.bottom + 0.01),
          reason: '$width px 下更多按钮滚出了视口底部',
        );

        await tester.tap(trigger);
        await tester.pumpAndSettle();
        final item = find.byKey(const Key('delete-fixed:course-1'));
        expect(item, findsOneWidget, reason: '$width px 下菜单必须能打开');
        await tester.tap(item);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('delete-entire')),
          findsOneWidget,
          reason: '$width px 下菜单项必须真的能点到（打开了不等于点得到）',
        );
      });
    }
  });

  group('Task 9 Step 3 键盘路径（不用鼠标）', () {
    testWidgets('Tab 能走到每一行的更多按钮，且焦点顺序与视觉顺序一致', (tester) async {
      // 视口给足：这一条验的是**顺序**，不是滚动。
      await pumpDayView(tester, size: const Size(1024, 2000));
      expect(tester.takeException(), isNull);

      // **按满一圈就停**：焦点走完最后一个可聚焦控件后会回到页面第一个控件，
      // 那是 Tab 的正常循环，不是"顺序错了"。因此以"回到已访问过的行"作为终点，
      // 而不是拿循环次数硬顶。
      var lastTop = double.negativeInfinity;
      final visited = <String>[];
      for (var round = 0; round < 24; round++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final id = _focusedActionItemId(tester);
        if (id == null) continue;
        if (visited.contains(id)) break;
        final top = tester.getRect(find.byKey(Key('actions-$id'))).top;
        expect(
          top,
          greaterThanOrEqualTo(lastTop - 0.01),
          reason:
              '焦点顺序与视觉顺序不一致：焦点从纵坐标 $lastTop 跳回了 $top'
              '（已访问 ${visited.join("、")} 之后到了 $id）。'
              '键盘用户按 Tab 时应该自上而下走',
        );
        lastTop = top;
        visited.add(id);
      }

      expect(
        visited,
        containsAll(<String>[
          'fixed:course-1',
          'protected:breakfast:2026-10-05:450',
        ]),
        reason:
            'Tab 必须能到达每一行的更多按钮（这里只验有可执行动作的两行）。'
            '任务块没有动作、只渲染等宽空槽，本来就不该有焦点',
      );
    });

    testWidgets('只按键盘：打开「更多操作」→ 选中「去设置」', (tester) async {
      var openedSettings = 0;
      await pumpDayView(
        tester,
        onOpenProtectedTimeSettings: () => openedSettings++,
      );
      expect(tester.takeException(), isNull);

      const ruleId = 'protected:breakfast:2026-10-05:450';
      final trigger = find.byKey(const Key('actions-$ruleId'));
      expect(
        await _tabUntilFocused(tester, trigger),
        isTrue,
        reason: 'Tab 必须能到达规则保护时间那一行的更多按钮',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('settings-$ruleId')),
        findsOneWidget,
        reason: 'Enter 要能打开菜单',
      );
      // **方向键是这一步的一部分，不是装饰**：`PopupMenuItem` 内部是 `InkWell`，
      // 而菜单一打开时"焦点在哪一项"由 `_PopupMenuRoute.requestFocus` 决定；
      // 先用一次方向键把焦点显式落到那一项上，再回车激活——这正是键盘用户的实际动作，
      // 也是既有 `accessibility_semantics_test.dart` 里那条用例的做法。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        _focusedActionButtonLabel(tester),
        '去设置',
        reason: '方向键之后焦点必须落在可读的菜单项上，键盘用户才知道自己选的是哪一项',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(openedSettings, 1, reason: '键盘选中「去设置」必须真的走到那个入口（不是只把菜单关掉）');
    });

    testWidgets('只按键盘：打开「更多操作」→ 进入「编辑任务」', (tester) async {
      await pumpDayView(tester);
      expect(tester.takeException(), isNull);

      const courseId = 'fixed:course-1';
      final trigger = find.byKey(const Key('actions-$courseId'));
      expect(
        await _tabUntilFocused(tester, trigger),
        isTrue,
        reason: 'Tab 必须能到达固定日程那一行的更多按钮',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      // 方向键选中「编辑」（菜单里第一项），再回车。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_focusedActionButtonLabel(tester), '编辑');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('occurrence-title')),
        findsOneWidget,
        reason: '键盘选中「编辑」必须真的打开改写对话框',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('occurrence-title')))
            .controller!
            .text,
        '数据结构课',
        reason: '打开的必须是这一条的对话框（标题预填当前值）',
      );
    });
  });
}
