// M1（路线图 §3.2、§11 Task 2）事项导航目标的**纯函数**测试。
//
// 这个文件证明的是"决定去哪儿"这一层：给定一条视图条目，解析出唯一的合法目标。
// 真实装配里"点了真的跳过去"由 `test/app/today_route_test.dart` 与
// `test/app/calendar_event_route_test.dart` 覆盖——两层合起来才等于 §3.2 的规则。
//
// **为什么这一层必须单独存在**：此前今日页那一行是 `context.go('/tasks/${item.taskId!}')`，
// 对**固定日程**与**保护时间**（它们的 `taskId` 是 `null`）会直接抛
// `Null check operator used on a null value`。而保护时间连"当天"都不是它的详情——
// 它是按规划规则算出来的区间，§3.2 要求去 `/settings/rules`。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/schedule_item_open_target.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

final _day = DateTime.utc(2026, 10, 8);

ScheduleViewItem _item({
  required String id,
  required ScheduleItemKind kind,
  String? taskId,
}) => ScheduleViewItem(
  id: id,
  title: '条目',
  kind: kind,
  range: TimeRange(
    startUtc: _day.add(const Duration(hours: 10)),
    endUtc: _day.add(const Duration(hours: 11)),
  ),
  categoryKey: 'area:study',
  categoryLabel: '学业',
  categoryColorArgb: 0xff456789,
  categorySortOrder: 0,
  taskId: taskId,
);

void main() {
  group('M1 任务条目', () {
    test('任务块进入它自己的任务详情', () {
      final target = resolveScheduleItemOpenTarget(
        _item(id: 'block:b1', kind: ScheduleItemKind.task, taskId: 't1'),
        _day,
      );

      expect(target, isA<TaskOpenTarget>());
      expect((target! as TaskOpenTarget).taskId, 't1');
    });

    // §3.2："没有合法目标的事项不显示死入口"。任务块缺 `taskId` 就是这种——
    // 此前靠 `item.taskId!` 当场崩溃，而不是"不显示入口"。
    test('任务块没有 taskId 时不给出目标（而不是抛异常）', () {
      final target = resolveScheduleItemOpenTarget(
        _item(id: 'block:b1', kind: ScheduleItemKind.task),
        _day,
      );

      expect(target, isNull, reason: '没有任务 id 就没有可打开的任务详情');
    });

    test('taskId 是空串时同样不给目标（空串不是合法实体 id）', () {
      final target = resolveScheduleItemOpenTarget(
        _item(id: 'block:b1', kind: ScheduleItemKind.task, taskId: ''),
        _day,
      );

      expect(target, isNull);
    });
  });

  group('M1 固定日程', () {
    // §3.2："固定日程进入对应日期的日视图，并定位该日程"。
    test('固定日程进入当天日视图，并带上这一条的日程 id', () {
      final target = resolveScheduleItemOpenTarget(
        _item(id: 'fixed:evt-7', kind: ScheduleItemKind.fixed),
        _day,
      );

      expect(target, isA<DayOpenTarget>());
      final day = target! as DayOpenTarget;
      expect(day.dayStartUtc, _day);
      expect(day.eventId, 'evt-7', reason: '必须带上领域事件 id 才能定位这一条');
    });

    test('传入的日期就是目标日期（今日页的"今天"）', () {
      final other = DateTime.utc(2026, 11, 1);
      final target =
          resolveScheduleItemOpenTarget(
                _item(id: 'fixed:evt-7', kind: ScheduleItemKind.fixed),
                other,
              )!
              as DayOpenTarget;

      expect(target.dayStartUtc, other);
    });

    test('条目 id 没有 `fixed:` 前缀时不给目标（解不出事件 id）', () {
      final target = resolveScheduleItemOpenTarget(
        _item(id: 'evt-7', kind: ScheduleItemKind.fixed),
        _day,
      );

      expect(target, isNull, reason: '取不到领域事件 id 就不能假装能定位');
    });

    test('`fixed:` 后面是空串时不给目标', () {
      final target = resolveScheduleItemOpenTarget(
        _item(id: 'fixed:', kind: ScheduleItemKind.fixed),
        _day,
      );

      expect(target, isNull);
    });
  });

  group('M1 保护时间', () {
    // §3.2："保护时间显示「查看保护规则」，进入 `/settings/rules`"。
    // **不是**日视图：保护时间是规划规则算出来的区间，规则页才是它的"详情"。
    test('保护时间进入规划规则页', () {
      final target = resolveScheduleItemOpenTarget(
        _item(id: 'protected:lunch', kind: ScheduleItemKind.protectedTime),
        _day,
      );

      expect(target, isA<PlanningRulesOpenTarget>());
    });
  });

  group('M1 其余与边界', () {
    // 生活块与任务块同源，但当前由任务侧产生，没有独立详情页；
    // 它**不是**"任务"，因此不该被送去 `/tasks/...`。
    test('生活块没有独立详情页，不给出目标', () {
      final target = resolveScheduleItemOpenTarget(
        _item(id: 'life:l1', kind: ScheduleItemKind.life),
        _day,
      );

      expect(target, isNull);
    });

    test('同一批条目逐条解析都不抛异常（§3.2 的"不显示死入口"前提）', () {
      for (final kind in ScheduleItemKind.values) {
        expect(
          () => resolveScheduleItemOpenTarget(
            _item(id: 'block:x', kind: kind, taskId: 't1'),
            _day,
          ),
          returnsNormally,
          reason: '${kind.label} 这一类的解析不能抛异常',
        );
      }
    });
  });
}
