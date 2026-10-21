import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';

/// Task 18 的性质测试：同一周期输入重复展开，必须得到逐字段相同的排程任务。
void main() {
  const timeZoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  final now = DateTime.utc(2026, 10, 19, 4);
  final period = WeeklyPeriod.startingAt(
    DateTime(2026, 10, 19),
    timeZoneId,
    zones,
  );

  RecurringTaskTemplate templateFor(RecurringPace pace) =>
      RecurringTaskTemplate(
        id: 'template-1',
        title: '每周英语',
        targetMinutes: 210,
        priority: TaskPriority.high,
        pace: pace,
        allowedWeekdaysMask: pace == RecurringPace.selectedWeekdays
            ? weekdayMaskOf(const [DateTime.wednesday, DateTime.saturday])
            : recurringAllWeekdaysMask,
        startsOnLocalDate: DateTime(2026, 10, 19),
        timeZoneId: timeZoneId,
        createdAtUtc: now,
        updatedAtUtc: now,
      );

  RecurringTaskCycle cycleFor() => RecurringTaskCycle(
    templateId: 'template-1',
    periodStartLocalDate: DateTime(2026, 10, 19),
    taskId: 'recurring:template-1:2026-10-19',
    baseTargetMinutes: 210,
    createdAtUtc: now,
    updatedAtUtc: now,
  );

  for (final pace in RecurringPace.values) {
    test('$pace 重复展开结果逐字段一致', () {
      final input = RecurringScheduleInput(
        template: templateFor(pace),
        cycle: cycleFor(),
        progress: RecurringProgress(
          templateId: 'template-1',
          periodStartLocalDate: DateTime(2026, 10, 19),
          targetMinutes: 210,
          recordedMinutes: 0,
          remainingMinutes: 210,
          status: RecurringCycleStatus.open,
          carryInMinutes: 0,
        ),
        period: period,
        planningStartUtc: now,
      );
      final first = recurringSchedulableTasks(input: input, zones: zones);
      final second = recurringSchedulableTasks(input: input, zones: zones);
      expect(first.length, second.length);
      expect(first.first.preferLater, pace == RecurringPace.deadlineWeighted);
      for (var index = 0; index < first.length; index++) {
        final a = first[index];
        final b = second[index];
        expect(a.id, b.id);
        expect(a.requiredMinutes, b.requiredMinutes);
        expect(a.dueAtUtc, b.dueAtUtc);
        expect(a.availableFromUtc, b.availableFromUtc);
        expect(a.allowedWeekdaysMask, b.allowedWeekdaysMask);
        expect(a.distributionPolicy, b.distributionPolicy);
        expect(a.priority, b.priority);
      }
    });
  }
}
