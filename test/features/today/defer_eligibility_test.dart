// 1.11.0（计划 Task 9 Step 2、DFR-007/020）：延后入口资格矩阵。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/today/defer_eligibility.dart';

void main() {
  final day = DateTime.utc(2026, 10, 5);
  final now = day.add(const Duration(hours: 10, minutes: 30));

  ScheduleViewItem item({
    String id = 'block:b1',
    ScheduleItemKind kind = ScheduleItemKind.task,
    String? taskId = 't1',
    bool completed = false,
    bool locked = false,
    int startHour = 14,
  }) => ScheduleViewItem(
    id: id,
    title: '任务',
    kind: kind,
    categoryKey: 'area:study',
    categoryLabel: '学业',
    categoryColorArgb: 0xff456789,
    categorySortOrder: 0,
    taskId: taskId,
    isCompleted: completed,
    isLocked: locked,
    range: TimeRange(
      startUtc: day.add(Duration(hours: startHour)),
      endUtc: day.add(Duration(hours: startHour + 1)),
    ),
  );

  test('未来任务块可点', () {
    final eligibility = DeferEligibility.forItem(item: item(), nowUtc: now);

    expect(eligibility.isVisible, isTrue);
    expect(eligibility.isEnabled, isTrue);
    expect(eligibility.reason, DeferEntryReason.eligible);
    expect(eligibility.disabledLabel, isNull);
  });

  test('已开始/进行中的块可见但禁用，并说明原因', () {
    final eligibility = DeferEligibility.forItem(
      item: item(startHour: 10),
      nowUtc: now,
    );

    expect(eligibility.isVisible, isTrue);
    expect(eligibility.isEnabled, isFalse);
    expect(eligibility.reason, DeferEntryReason.alreadyStarted);
    expect(eligibility.disabledLabel, '这一块已经开始，不能延后');
  });

  test('已完成任务可见但禁用', () {
    final eligibility = DeferEligibility.forItem(
      item: item(completed: true),
      nowUtc: now,
    );

    expect(eligibility.isVisible, isTrue);
    expect(eligibility.isEnabled, isFalse);
    expect(eligibility.reason, DeferEntryReason.completed);
    expect(eligibility.disabledLabel, '任务已完成，不能延后');
  });

  test('固定日程、保护时间与非任务块不显示入口', () {
    for (final kind in [
      ScheduleItemKind.fixed,
      ScheduleItemKind.protectedTime,
    ]) {
      final eligibility = DeferEligibility.forItem(
        item: item(kind: kind, taskId: null),
        nowUtc: now,
      );
      expect(eligibility.isVisible, isFalse, reason: kind.name);
      expect(eligibility.isEnabled, isFalse, reason: kind.name);
      expect(eligibility.reason, DeferEntryReason.notTask);
    }
    expect(
      DeferEligibility.forItem(item: item(taskId: null), nowUtc: now).isVisible,
      isFalse,
      reason: '缺 taskId 的任务块没有可延后的任务',
    );
  });

  test('锁定块可见但禁用，并说明原因', () {
    final eligibility = DeferEligibility.forItem(
      item: item(locked: true),
      nowUtc: now,
    );

    expect(eligibility.isVisible, isTrue);
    expect(eligibility.isEnabled, isFalse);
    expect(eligibility.reason, DeferEntryReason.locked);
    expect(eligibility.disabledLabel, '这一块已锁定，不能延后');
  });

  test('块结束之后同样按"已开始"处理（历史块不提供入口）', () {
    final eligibility = DeferEligibility.forItem(
      item: item(startHour: 8),
      nowUtc: now,
    );

    expect(eligibility.isEnabled, isFalse);
    expect(eligibility.reason, DeferEntryReason.alreadyStarted);
  });
}
