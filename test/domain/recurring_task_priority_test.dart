// M6（路线图 §3.4、§11 Task 8）：周期目标的**排序**。
//
// 这些用例钉住"多项竞争时谁先排"，以及路线图 §7.2 最后一条要求的那件事：
// **结果不依赖数据库返回顺序**。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/services/recurring_task_priority.dart';

RecurringSchedulingContext context({
  String id = 'template-1',
  TaskPriority priority = TaskPriority.medium,
  TaskEnergyLevel energy = TaskEnergyLevel.medium,
  int remaining = 100,
  int target = 180,
  int daysUntilEnd = 3,
  int allowedWeekdays = 7,
  int squeezed = 0,
}) => RecurringSchedulingContext(
  templateId: id,
  priority: priority,
  energyLevel: energy,
  remainingMinutes: remaining,
  targetMinutes: target,
  daysUntilPeriodEnd: daysUntilEnd,
  allowedWeekdayCount: allowedWeekdays,
  squeezedCount: squeezed,
);

void main() {
  group('单项排序', () {
    test('优先级越高分越高', () {
      final low = rankRecurringTask(context(priority: TaskPriority.low));
      final high = rankRecurringTask(context(priority: TaskPriority.high));
      final urgent = rankRecurringTask(context(priority: TaskPriority.urgent));
      expect(high.score, greaterThan(low.score));
      expect(urgent.score, greaterThan(high.score));
    });

    test('距周期结束越近分越高', () {
      final soon = rankRecurringTask(context(daysUntilEnd: 0));
      final later = rankRecurringTask(context(daysUntilEnd: 6));
      expect(soon.score, greaterThan(later.score));
      expect(soon.rationale, contains('今天'));
    });

    test('剩余比例越低分越高（先做完更容易做完的）', () {
      final almostDone = rankRecurringTask(context(remaining: 20, target: 180));
      final justStarted = rankRecurringTask(
        context(remaining: 180, target: 180),
      );
      expect(almostDone.score, greaterThan(justStarted.score));
    });

    test('连续被挤压次数越多分越高，但上界是 5 次', () {
      final zero = rankRecurringTask(context(squeezed: 0)).score;
      final three = rankRecurringTask(context(squeezed: 3)).score;
      final five = rankRecurringTask(context(squeezed: 5)).score;
      final nine = rankRecurringTask(context(squeezed: 9)).score;
      expect(three, greaterThan(zero));
      expect(five, greaterThan(three));
      // 上界：再被挤也不会压过优先级与截止，否则长期低优先级目标会长期霸占容量。
      expect(nine, five);
    });

    test('允许星期越窄分越高', () {
      final all = rankRecurringTask(context(allowedWeekdays: 7));
      final one = rankRecurringTask(context(allowedWeekdays: 1));
      expect(one.score, greaterThan(all.score));
    });

    test('理由里给出本周剩余、距结束天数、精力与均匀分布（§3.4）', () {
      final rank = rankRecurringTask(
        context(remaining: 100, daysUntilEnd: 2, energy: TaskEnergyLevel.high),
      );
      expect(rank.rationale, contains('本周剩余 100 分钟'));
      expect(rank.rationale, contains('距本周结束 2 天'));
      expect(rank.rationale, contains('高精力'));
      expect(rank.rationale, contains('均匀分布'));
    });

    test('被挤压次数与受限星期会写进理由', () {
      final rank = rankRecurringTask(context(squeezed: 2, allowedWeekdays: 3));
      expect(rank.rationale, contains('已连续 2 次未排入'));
      expect(rank.rationale, contains('仅允许 3 天'));
    });

    test('精力只进理由，不进分数（它的落点是引擎的精力匹配）', () {
      final low = rankRecurringTask(context(energy: TaskEnergyLevel.low));
      final high = rankRecurringTask(context(energy: TaskEnergyLevel.high));
      expect(low.score, high.score);
      expect(low.rationale, isNot(high.rationale));
    });
  });

  group('多项竞争', () {
    test('高优先级 + 临近结束的目标排在前面', () {
      final ranked = rankRecurringTasks([
        context(id: 'later', priority: TaskPriority.low, daysUntilEnd: 6),
        context(id: 'urgent', priority: TaskPriority.high, daysUntilEnd: 0),
      ]);
      expect(ranked.first.templateId, 'urgent');
    });

    test('结果不依赖输入顺序（§7.2 最后一条）', () {
      final contexts = [
        context(id: 'a', priority: TaskPriority.high, daysUntilEnd: 2),
        context(id: 'b', priority: TaskPriority.medium, daysUntilEnd: 0),
        context(id: 'c', priority: TaskPriority.low, squeezed: 3),
        context(id: 'd', priority: TaskPriority.urgent, remaining: 20),
      ];
      final forward = rankRecurringTasks(contexts)
          .map((rank) => rank.templateId)
          .toList();
      final reversed = rankRecurringTasks(contexts.reversed)
          .map((rank) => rank.templateId)
          .toList();
      expect(reversed, forward);
    });

    test('完全同分时按 id 兜底，仍与输入顺序无关', () {
      final ranked = rankRecurringTasks([
        context(id: 'zzz'),
        context(id: 'aaa'),
        context(id: 'mmm'),
      ]);
      expect(ranked.map((rank) => rank.templateId), ['aaa', 'mmm', 'zzz']);
      final reversed = rankRecurringTasks([
        context(id: 'mmm'),
        context(id: 'zzz'),
        context(id: 'aaa'),
      ]);
      expect(reversed.map((rank) => rank.templateId), ['aaa', 'mmm', 'zzz']);
    });

    test('三个以上目标竞争时名次稳定且名次集合与输入一致', () {
      final contexts = [
        for (var index = 0; index < 5; index++)
          context(id: 'template-$index', squeezed: index),
      ];
      final ranked = rankRecurringTasks(contexts);
      expect(ranked, hasLength(5));
      expect(
        ranked.map((rank) => rank.templateId).toSet(),
        contexts.map((item) => item.templateId).toSet(),
      );
      // 被挤压最多的那个排最前（其余条件相同）。
      expect(ranked.first.templateId, 'template-4');
    });
  });

  group('上下文校验', () {
    test('非法取值被拒绝', () {
      expect(() => context(remaining: -1), throwsA(isA<AssertionError>()));
      expect(() => context(target: 0), throwsA(isA<AssertionError>()));
      expect(() => context(daysUntilEnd: -1), throwsA(isA<AssertionError>()));
      expect(() => context(allowedWeekdays: 0), throwsA(isA<AssertionError>()));
      expect(() => context(squeezed: -1), throwsA(isA<AssertionError>()));
    });

    test('copyWith 只改指定项', () {
      final base = context(squeezed: 1);
      final updated = base.copyWith(squeezedCount: 4);
      expect(updated.squeezedCount, 4);
      expect(updated.remainingMinutes, base.remainingMinutes);
      expect(updated.templateId, base.templateId);
    });
  });
}
