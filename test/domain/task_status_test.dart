import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';

/// `TaskStatus` 的八个状态中，`scheduled` 与 `overdue` 是由事实派生的，不落库。
/// 本测试固定派生优先级与两个语义扩展，避免后续把派生状态当成可写入状态。
void main() {
  final now = DateTime.utc(2026, 10, 5, 12);
  final created = DateTime.utc(2026, 10, 1);
  final past = DateTime.utc(2026, 10, 4);
  final future = DateTime.utc(2026, 10, 9);

  PlannerTask task({TaskStatus status = TaskStatus.open, DateTime? due}) =>
      PlannerTask(
        id: 't1',
        title: '论文',
        priority: TaskPriority.high,
        estimatedMinutes: 120,
        remainingMinutes: 120,
        dueAtUtc: due,
        energyLevel: TaskEnergyLevel.high,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
        status: status,
        createdAtUtc: created,
        updatedAtUtc: created,
      );

  test('派生状态优先级：已结束 > 已逾期 > 进行中 > 已安排 > 用户状态', () {
    // 结束即结束，不再判逾期。
    expect(
      task(status: TaskStatus.completed, due: past).statusAt(nowUtc: now),
      TaskStatus.completed,
    );
    expect(
      task(status: TaskStatus.skipped, due: past).statusAt(nowUtc: now),
      TaskStatus.skipped,
    );
    // 截止已过且未结束 → 已逾期。
    expect(task(due: past).statusAt(nowUtc: now), TaskStatus.overdue);
    // 逾期比"进行中"更值得处理。
    expect(
      task(status: TaskStatus.inProgress, due: past).statusAt(nowUtc: now),
      TaskStatus.overdue,
    );
    // 进行中比"已安排"更能说明当下在做什么。
    expect(
      task(
        status: TaskStatus.inProgress,
        due: future,
      ).statusAt(nowUtc: now, hasPlanBlocks: true),
      TaskStatus.inProgress,
    );
    // 有已确认计划块 → 已安排。
    expect(
      task(due: future).statusAt(nowUtc: now, hasPlanBlocks: true),
      TaskStatus.scheduled,
    );
    // 其余情况回落到用户设置的状态。
    expect(task(due: future).statusAt(nowUtc: now), TaskStatus.open);
    expect(
      task(status: TaskStatus.inbox).statusAt(nowUtc: now),
      TaskStatus.inbox,
    );
  });

  test('没有截止时间的任务不会被判为已逾期', () {
    expect(task().statusAt(nowUtc: now), TaskStatus.open);
    expect(
      task().statusAt(nowUtc: now, hasPlanBlocks: true),
      TaskStatus.scheduled,
    );
  });

  test('statusAt 要求 UTC 时刻', () {
    expect(
      () => task().statusAt(nowUtc: DateTime(2026, 10, 5)),
      throwsArgumentError,
    );
  });

  test('isClosed 只覆盖完成、跳过与取消', () {
    expect(TaskStatus.completed.isClosed, isTrue);
    expect(TaskStatus.skipped.isClosed, isTrue);
    expect(TaskStatus.cancelled.isClosed, isTrue);
    for (final status in [
      TaskStatus.inbox,
      TaskStatus.open,
      TaskStatus.scheduled,
      TaskStatus.inProgress,
      TaskStatus.overdue,
    ]) {
      expect(status.isClosed, isFalse, reason: status.name);
    }
  });

  test('isStored 排除两个派生状态，数据库不会保存它们', () {
    expect(TaskStatus.scheduled.isStored, isFalse);
    expect(TaskStatus.overdue.isStored, isFalse);
    for (final status in [
      TaskStatus.inbox,
      TaskStatus.open,
      TaskStatus.inProgress,
      TaskStatus.completed,
      TaskStatus.skipped,
      TaskStatus.cancelled,
    ]) {
      expect(status.isStored, isTrue, reason: status.name);
    }
  });

  test('八个状态齐备', () {
    expect(TaskStatus.values, hasLength(8));
    expect(TaskStatus.values.map((status) => status.name), [
      'inbox',
      'open',
      'scheduled',
      'inProgress',
      'completed',
      'skipped',
      'cancelled',
      'overdue',
    ]);
  });
}
