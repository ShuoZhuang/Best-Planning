// M6（路线图 §3.3 最后一条、§11 Task 8 Step 7）：今日页卡片上的周期进度。
//
// §3.3 的原文要求是"卡片显示『本周已完成 80/180 分钟』和『本段 45 分钟』，**不能把已安排
// 误写成已完成**"。这个文件就钉住这两件事：
//   1. 有周期徽标时，卡片上出现"本周已完成 x/y 分钟"；
//   2. 徽标说的是**已完成**（来自 time_entries），而不是"已安排"；周视图那一侧由
//      `schedule_view_source` 的用例覆盖（这里只用现成的条目数据驱动页面）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/today/today_page.dart';

final _dayStartUtc = DateTime.utc(2026, 10, 6, 16); // 本地 2026-10-07 00:00

/// 卡片上的时段。**必须落在 [dayStartUtc, dayStartUtc + 1 天) 内**，否则会被今日页按
/// "哪一天"裁剪掉——那样测的是裁剪逻辑，不是进度徽标。
final _blockStartUtc = DateTime.utc(2026, 10, 7, 1); // 本地 09:00

final class _Source implements ScheduleViewSource {
  _Source(this.items);
  final List<ScheduleViewItem> items;

  @override
  Stream<List<ScheduleViewItem>> watch(DateTime startUtc, DateTime endUtc) =>
      Stream.value(items);
}

ScheduleViewItem _item({
  String id = 'block:b1',
  String title = '每周英语',
  String? taskId = 'recurring:template-1:2026-10-05',
  RecurringGoalBadge? goal,
  bool isCompleted = false,
}) => ScheduleViewItem(
  id: id,
  title: title,
  kind: ScheduleItemKind.task,
  range: TimeRange(
    startUtc: _blockStartUtc,
    endUtc: _blockStartUtc.add(const Duration(hours: 1)),
  ),
  categoryKey: 'area:study',
  categoryLabel: '学业',
  categoryColorArgb: 0xFF5B8DEF,
  categorySortOrder: 0,
  taskId: taskId,
  isCompleted: isCompleted,
  recurringGoal: goal,
);

Future<void> _pump(WidgetTester tester, List<ScheduleViewItem> items) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TodayPage(
          source: _Source(items),
          day: _dayStartUtc,
          toLocal: (instantUtc) => instantUtc.toUtc(),
          nowUtc: _dayStartUtc.add(const Duration(hours: 10)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('周期目标卡片显示"本周已完成 80/180 分钟"', (tester) async {
    await _pump(tester, [
      _item(
        goal: const RecurringGoalBadge(
          templateId: 'template-1',
          title: '每周英语',
          recordedMinutes: 80,
          targetMinutes: 180,
        ),
      ),
    ]);

    expect(find.text('本周已完成 80/180 分钟'), findsOneWidget);
  });

  testWidgets('达标时写明"已达标"，与未达标区分开', (tester) async {
    await _pump(tester, [
      _item(
        goal: const RecurringGoalBadge(
          templateId: 'template-1',
          title: '每周英语',
          recordedMinutes: 180,
          targetMinutes: 180,
        ),
      ),
    ]);

    expect(find.text('本周已完成 180/180 分钟（已达标）'), findsOneWidget);
  });

  testWidgets('文案说的是"已完成"，绝不出现"已安排"（§3.3）', (tester) async {
    await _pump(tester, [
      _item(
        goal: const RecurringGoalBadge(
          templateId: 'template-1',
          title: '每周英语',
          recordedMinutes: 80,
          targetMinutes: 180,
        ),
      ),
    ]);

    expect(find.textContaining('已完成'), findsWidgets);
    expect(
      find.textContaining('已安排'),
      findsNothing,
      reason: '把已安排误写成已完成会让用户以为这一周做完了',
    );
  });

  testWidgets('不是周期目标的条目完全没有那一行（纯增量）', (tester) async {
    await _pump(tester, [_item(taskId: 'task-1')]);

    expect(find.textContaining('本周已完成'), findsNothing);
    expect(find.text('每周英语'), findsWidgets, reason: '卡片本身照常渲染');
  });

  testWidgets('读屏也能听到周期进度（徽标不只是视觉信息）', (tester) async {
    await _pump(tester, [
      _item(
        goal: const RecurringGoalBadge(
          templateId: 'template-1',
          title: '每周英语',
          recordedMinutes: 45,
          targetMinutes: 180,
        ),
      ),
    ]);

    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('today-schedule-block:b1')),
    );
    expect(semantics.label, contains('本周已完成 45/180 分钟'));
  });

  testWidgets('150% 与 200% 缩放下进度那一行仍然可读', (tester) async {
    for (final scale in const [1.5, 2.0]) {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: TodayPage(
                source: _Source([
                  _item(
                    goal: const RecurringGoalBadge(
                      templateId: 'template-1',
                      title: '每周英语',
                      recordedMinutes: 80,
                      targetMinutes: 180,
                    ),
                  ),
                ]),
                day: _dayStartUtc,
                toLocal: (instantUtc) => instantUtc.toUtc(),
                nowUtc: _dayStartUtc.add(const Duration(hours: 10)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$scale 倍缩放下不应有布局异常');
      expect(
        find.text('本周已完成 80/180 分钟'),
        findsOneWidget,
        reason: '$scale 倍缩放下进度必须仍然可见',
      );
    }
  });
}
