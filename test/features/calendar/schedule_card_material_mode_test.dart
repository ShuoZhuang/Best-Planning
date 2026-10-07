// 四种材质模式（无玻璃 / 克制 / 激进 / 极致）不得改变日程卡片的填充与描边。
//
// **为什么这条测试必须存在**：卡片"发白"的根因是半透明填充——玻璃模式越激进，透上来的
// 背景越亮，同一张卡片在四种模式下看起来是四种颜色。修好之后卡片必须是**不透明**派生色，
// 于是"切换玻璃模式时卡片表面不漂移"就成了可断言的契约；这个文件把它钉住。
//
// 断言分两层：① 主题确实按传入模式生效（否则测试可能什么都没验证到）；② 学业卡与保护时间卡
// 的 `fill`/`border` 在四种模式下逐值相等，且等于共享派生器的结果。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/day_view/day_view_page.dart';
import 'package:personal_planner/features/calendar/schedule_category_card_style.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/week_view_page.dart';
import 'package:personal_planner/features/today/today_page.dart';

const Color _studyColor = Color(0xff2f86ff);
const Color _protectedColor = Color(0xff5ec8e5);

final DateTime _dayStartUtc = DateTime.utc(2026, 10, 5);

final List<ScheduleViewItem> _items = [
  ScheduleViewItem(
    id: 'fixed:class',
    title: '数据结构课',
    kind: ScheduleItemKind.fixed,
    categoryKey: 'area:study',
    categoryLabel: '学业',
    categoryColorArgb: _studyColor.toARGB32(),
    categorySortOrder: 0,
    range: TimeRange(
      startUtc: DateTime.utc(2026, 10, 5, 9),
      endUtc: DateTime.utc(2026, 10, 5, 10),
    ),
  ),
  ScheduleViewItem(
    id: 'protected:lunch:1',
    title: '午餐时间',
    kind: ScheduleItemKind.protectedTime,
    categoryKey: 'special:protected',
    categoryLabel: '保护时间',
    categoryColorArgb: _protectedColor.toARGB32(),
    categorySortOrder: 10000,
    range: TimeRange(
      startUtc: DateTime.utc(2026, 10, 5, 12),
      endUtc: DateTime.utc(2026, 10, 5, 13),
    ),
  ),
];

/// 用指定玻璃模式 pump 一个页面，并返回它内部的主题上下文。
///
/// 返回上下文是为了**证明模式真的生效了**：只比卡片颜色的话，一个忘了把主题传下去的实现
/// 会让四种模式都跑在默认主题上，测试依然是绿的。
Future<BuildContext> _pumpThemed(
  WidgetTester tester,
  PlannerMaterialMode mode,
  Widget home,
) async {
  final contexts = <BuildContext>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: PlannerTheme.dark(glassMode: mode),
      home: Builder(
        builder: (context) {
          contexts.add(context);
          return home;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return contexts.last;
}

/// 卡片按分类色必须得到的填充与描边；四个模式下都必须逐值相等。
void _expectSharedCardColors({
  required Color actualFill,
  required Color actualBorder,
  required Color categoryColor,
  required String reason,
}) {
  final expected = scheduleCategoryCardStyle(categoryColor);
  expect(actualFill, expected.fill, reason: '$reason 的填充随材质模式漂移了');
  expect(actualBorder, expected.border, reason: '$reason 的描边随材质模式漂移了');
  // 不透明：一旦这里变成半透明，玻璃背景就会重新把卡片冲淡。
  expect(actualFill.toARGB32() >>> 24, 0xff, reason: '$reason 的填充必须不透明');
  expect(actualBorder.toARGB32() >>> 24, 0xff, reason: '$reason 的描边必须不透明');
}

void main() {
  test('四种玻璃模式的表面本身确实不同，卡片颜色才值得断言"不漂移"', () {
    final surfaces = {
      for (final mode in PlannerMaterialMode.values)
        mode: PlannerGlassTheme.forMode(mode).surface.toARGB32(),
    };
    // 若四种模式的表面完全相同，"切换模式颜色不变"就是一句空话。
    expect(
      surfaces.values.toSet(),
      hasLength(PlannerMaterialMode.values.length),
    );
  });

  for (final mode in PlannerMaterialMode.values) {
    final label = mode.storedValue;

    testWidgets('$label：七日历卡片的填充与描边不随玻璃模式改变', (tester) async {
      final context = await _pumpThemed(
        tester,
        mode,
        WeekViewPage(
          source: _Source(_items),
          weekStart: _dayStartUtc,
          moveController: const DisabledWeekMoveController(),
        ),
      );
      expect(PlannerGlassTheme.of(context).mode, mode);

      for (final (id, color) in <(String, Color)>[
        ('fixed:class', _studyColor),
        ('protected:lunch:1', _protectedColor),
      ]) {
        final card = tester.widget<Card>(
          find.byKey(Key('week-schedule-card-$id')),
        );
        _expectSharedCardColors(
          actualFill: card.color!,
          actualBorder: (card.shape! as RoundedRectangleBorder).side.color,
          categoryColor: color,
          reason: '$label/七日历/$id',
        );
      }
    });

    testWidgets('$label：单日详情卡片的填充与描边不随玻璃模式改变', (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final context = await _pumpThemed(
        tester,
        mode,
        Scaffold(
          body: DayViewPage(
            source: _Source(_items),
            dayStartUtc: _dayStartUtc,
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
          ),
        ),
      );
      expect(PlannerGlassTheme.of(context).mode, mode);

      for (final (id, color) in <(String, Color)>[
        ('fixed:class', _studyColor),
        ('protected:lunch:1', _protectedColor),
      ]) {
        final card = tester.widget<Card>(
          find.byKey(Key('day-schedule-card-$id')),
        );
        _expectSharedCardColors(
          actualFill: card.color!,
          actualBorder: (card.shape! as RoundedRectangleBorder).side.color,
          categoryColor: color,
          reason: '$label/单日详情/$id',
        );
      }
    });

    testWidgets('$label：今日卡片的填充与描边不随玻璃模式改变', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final context = await _pumpThemed(
        tester,
        mode,
        TodayPage(source: _Source(_items), day: _dayStartUtc),
      );
      expect(PlannerGlassTheme.of(context).mode, mode);

      for (final (id, color) in <(String, Color)>[
        ('fixed:class', _studyColor),
        ('protected:lunch:1', _protectedColor),
      ]) {
        final decoration =
            tester
                    .widget<Container>(
                      find.byKey(Key('today-schedule-card-$id')),
                    )
                    .decoration!
                as BoxDecoration;
        _expectSharedCardColors(
          actualFill: decoration.color!,
          actualBorder: (decoration.border! as Border).top.color,
          categoryColor: color,
          reason: '$label/今日/$id',
        );
      }
    });
  }
}

final class _Source implements ScheduleViewSource {
  const _Source(this.items);

  final List<ScheduleViewItem> items;

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      Stream.value(items);
}
