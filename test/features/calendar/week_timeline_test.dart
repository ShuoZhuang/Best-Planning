// M5（路线图 §9）周时间轴：视图切换与持久化、颜色复用、列头与卡片可点、
// 长标题限行 + Tooltip、150% 缩放可操作、以及**紧凑模式不回归**。
//
// 几何本身（高度比例、并排、极短任务、可见范围）由 `timeline_layout_test.dart`
// 用纯逻辑穷举；这里只钉子"页面确实按那份几何画出来了，并且两个模式都还能用"。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/week_view_preference_service.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/week_view_page.dart';

/// 当天本地 00:00（测试用 UTC 当本地，避免时区换算干扰断言）。
final _weekStart = DateTime.utc(2026, 10, 5);

ScheduleViewItem _item(
  String id,
  String title, {
  required DateTime start,
  Duration length = const Duration(hours: 1),
  int colorArgb = 0xff2f86ff,
  ScheduleItemKind kind = ScheduleItemKind.task,
}) => ScheduleViewItem(
  id: id,
  title: title,
  kind: kind,
  categoryKey: 'area:study',
  categoryLabel: '学业',
  categoryColorArgb: colorArgb,
  categorySortOrder: 0,
  range: TimeRange(startUtc: start, endUtc: start.add(length)),
);

final class _Source implements ScheduleViewSource {
  const _Source(this.items);
  final List<ScheduleViewItem> items;

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      Stream.value(items);
}

Future<void> _pump(
  WidgetTester tester, {
  required List<ScheduleViewItem> items,
  WeekViewPreferenceService? preference,
  ValueChanged<ScheduleViewItem>? onOpenItem,
  ValueChanged<DateTime>? onOpenDay,
  double textScale = 1.0,
  Size size = const Size(1400, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: MaterialApp(
        home: Scaffold(
          body: WeekViewPage(
            source: _Source(items),
            weekStart: _weekStart,
            moveController: const DisabledWeekMoveController(),
            toLocal: (value) => value,
            viewModePreference: preference,
            onOpenItem: onOpenItem,
            onOpenDay: onOpenDay,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ── 切换存在、默认紧凑、可记忆（§9）────────────────────────────────────────

  testWidgets('M5 顶部有「紧凑／时间轴」切换，默认是紧凑模式', (tester) async {
    await _pump(
      tester,
      items: [
        _item('a', '算法作业', start: _weekStart.add(const Duration(hours: 9))),
      ],
    );

    expect(find.byKey(const Key('week-view-mode-compact')), findsOneWidget);
    expect(find.byKey(const Key('week-view-mode-timeline')), findsOneWidget);
    // §9："紧凑模式保留，不能强迫用户接受时间轴密度" ⇒ 默认必须是紧凑。
    expect(find.byKey(const Key('week-timeline-scroll')), findsNothing);
    expect(find.text('紧凑'), findsOneWidget);
    expect(find.text('时间轴'), findsOneWidget);
  });

  testWidgets('M5 切到时间轴后真的渲染时间轴，并能切回紧凑', (tester) async {
    await _pump(
      tester,
      items: [
        _item('a', '算法作业', start: _weekStart.add(const Duration(hours: 9))),
      ],
    );

    await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week-timeline-scroll')), findsOneWidget);
    expect(
      find.byKey(const Key('week-timeline-card-a')),
      findsOneWidget,
      reason: '时间轴里必须画出那张卡片',
    );

    await tester.tap(find.byKey(const Key('week-view-mode-compact')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('week-timeline-scroll')), findsNothing);
  });

  testWidgets('M5 记住本机选择：已存 timeline 时进页面就是时间轴', (tester) async {
    final settings = MemorySettingsRepository();
    await settings.write(
      WeekViewPreferenceService.storageKey,
      WeekViewMode.timeline.name,
    );
    await _pump(
      tester,
      items: [
        _item('a', '算法作业', start: _weekStart.add(const Duration(hours: 9))),
      ],
      preference: WeekViewPreferenceService(settings: settings),
    );

    expect(
      find.byKey(const Key('week-timeline-scroll')),
      findsOneWidget,
      reason: '上次选了时间轴，这次进来就该是时间轴',
    );
  });

  testWidgets('M5 切换会写回设置', (tester) async {
    final settings = MemorySettingsRepository();
    await _pump(
      tester,
      items: [
        _item('a', '算法作业', start: _weekStart.add(const Duration(hours: 9))),
      ],
      preference: WeekViewPreferenceService(settings: settings),
    );

    await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
    await tester.pumpAndSettle();

    expect(
      await settings.read(WeekViewPreferenceService.storageKey),
      WeekViewMode.timeline.name,
      reason: '切换必须落到设置里，否则"记住本机选择"是空话',
    );
  });

  testWidgets('M5 设置里的值不可识别时回落到紧凑（不因脏数据打不开日历）', (tester) async {
    final settings = MemorySettingsRepository();
    // 旧版本写下的名字、或被手改过的值。
    await settings.write(
      WeekViewPreferenceService.storageKey,
      'wat-not-a-mode',
    );
    await _pump(
      tester,
      items: [
        _item('a', '算法作业', start: _weekStart.add(const Duration(hours: 9))),
      ],
      preference: WeekViewPreferenceService(settings: settings),
    );

    expect(find.byKey(const Key('week-timeline-scroll')), findsNothing);
  });

  // ── 颜色复用统一目录（§9）──────────────────────────────────────────────────

  testWidgets('M5 时间轴卡片的颜色与紧凑模式来自同一派生器', (tester) async {
    const colorArgb = 0xff2f86ff;
    final item = _item(
      'a',
      '算法作业',
      start: _weekStart.add(const Duration(hours: 9)),
      colorArgb: colorArgb,
    );
    await _pump(tester, items: [item]);
    final expected = scheduleCategoryCardStyle(Color(colorArgb)).accent;

    // 紧凑模式把强调色用在**类型图标**上，没有彩色条（`Card` + 图标）。
    final compactIcon = tester
        .widget<Icon>(
          find
              .descendant(
                of: find.byKey(const ValueKey('week-schedule-card-a')),
                matching: find.byType(Icon),
              )
              .first,
        )
        .color;
    expect(compactIcon, expected);

    await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
    await tester.pumpAndSettle();
    // 时间轴把强调色用在**左侧竖条**上。
    final timelineAccent = tester
        .widget<ColoredBox>(
          find
              .descendant(
                of: find.byKey(const ValueKey('week-timeline-card-a')),
                matching: find.byType(ColoredBox),
              )
              .first,
        )
        .color;
    expect(
      timelineAccent,
      expected,
      reason: '同一事项在紧凑与时间轴里必须逐值同色（§9："颜色继续使用统一目录"）',
    );
  });

  // ── 卡片与列头可点（§9 退出条件）─────────────────────────────────────────

  testWidgets('M5 时间轴里点卡片进入该条详情', (tester) async {
    ScheduleViewItem? opened;
    await _pump(
      tester,
      items: [
        _item('a', '算法作业', start: _weekStart.add(const Duration(hours: 9))),
      ],
      onOpenItem: (item) => opened = item,
    );
    await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('week-timeline-card-a')));
    await tester.pumpAndSettle();
    expect(opened?.id, 'a', reason: '点卡片要进"这一条"，不是"这一天"');
  });

  testWidgets('M5 时间轴里点日期头进入**那一天**的日视图', (tester) async {
    DateTime? openedDay;
    await _pump(
      tester,
      items: [
        _item('a', '算法作业', start: _weekStart.add(const Duration(hours: 9))),
      ],
      onOpenDay: (day) => openedDay = day,
    );
    await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
    await tester.pumpAndSettle();

    // 时间轴列头与紧凑模式同样可点。
    await tester.tap(find.byKey(const ValueKey('week-timeline-day-label-今天')));
    await tester.pumpAndSettle();
    expect(openedDay, _weekStart, reason: '点"今天"的列头必须进今天，而不是别的天');
  });

  // ── 长标题限行 + Tooltip；真实起止时间（§9）──────────────────────────────

  testWidgets('M5 时间轴卡片标题限行，且带 Tooltip 可看完整标题', (tester) async {
    const longTitle = '这是一门标题非常长的课程名称用来验证它会省略而不是撑破卡片布局';
    await _pump(
      tester,
      items: [
        _item('a', longTitle, start: _weekStart.add(const Duration(hours: 9))),
      ],
    );
    await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(
      find.byKey(const ValueKey('week-timeline-title-a')),
    );
    expect(title.maxLines, 1, reason: '§9：课程和长标题在卡片内最多显示约定行数');
    expect(title.overflow, TextOverflow.ellipsis);
    // 完整标题通过 Tooltip 看。
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('week-timeline-title-a')),
        matching: find.byType(Tooltip),
      ),
      findsOneWidget,
      reason: '§9：完整标题通过详情或 Tooltip 查看',
    );
  });

  testWidgets('M5 时间轴卡片显示真实起止时间（比例高度只是观感）', (tester) async {
    await _pump(
      tester,
      items: [
        _item(
          'a',
          '算法作业',
          start: _weekStart.add(const Duration(hours: 9, minutes: 30)),
          length: const Duration(hours: 1, minutes: 15),
        ),
      ],
    );
    await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('week-timeline-range-a')), findsOneWidget);
    expect(find.text('09:30–10:45'), findsOneWidget);
  });

  // ── 缩放（§9 退出条件：150% 缩放下仍可操作）──────────────────────────────

  testWidgets('M5 150% 缩放时间轴仍渲染卡片且可点', (tester) async {
    ScheduleViewItem? opened;
    await _pump(
      tester,
      items: [
        _item('a', '算法作业', start: _weekStart.add(const Duration(hours: 9))),
      ],
      onOpenItem: (item) => opened = item,
      textScale: 1.5,
    );
    await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('week-timeline-card-a')),
      findsOneWidget,
      reason: '§9：150% 缩放下时间轴仍要可操作',
    );
    await tester.tap(find.byKey(const ValueKey('week-timeline-card-a')));
    await tester.pumpAndSettle();
    expect(opened?.id, 'a');
  });

  // ── 紧凑模式不回归（§9 退出条件）────────────────────────────────────────

  testWidgets('M5 紧凑模式仍然可拖动并请求调整（切到时间轴再切回来也不丢）', (tester) async {
    final controller = _CountingMoveController();
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeekViewPage(
            source: _Source([
              _item(
                'a',
                '算法作业',
                start: _weekStart.add(const Duration(hours: 9)),
              ),
            ]),
            weekStart: _weekStart,
            moveController: controller,
            toLocal: (value) => value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 切到时间轴再切回来——紧凑模式的拖动入口必须还在。
    await tester.tap(find.byKey(const Key('week-view-mode-timeline')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('week-view-mode-compact')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('week-schedule-card-a')),
      findsOneWidget,
      reason: '§9：紧凑模式行为不得回归',
    );
  });

  testWidgets('M5 没有安排时不显示时间轴（沿用既有的空状态）', (tester) async {
    await _pump(tester, items: const []);
    expect(find.text('未来七天暂无安排'), findsOneWidget);
  });
}

final class _CountingMoveController implements WeekMoveController {
  int calls = 0;

  @override
  Future<String?> proposeMove(
    ScheduleViewItem item,
    DateTime localDay, {
    bool lock = true,
  }) async {
    calls++;
    return null;
  }
}
