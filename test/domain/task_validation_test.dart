import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';

void main() {
  PlannerTask createTask({
    String title = '准备课程展示',
    int estimatedMinutes = 47,
    int remainingMinutes = 47,
  }) {
    return PlannerTask(
      id: 'task-1',
      title: title,
      priority: TaskPriority.medium,
      estimatedMinutes: estimatedMinutes,
      remainingMinutes: remainingMinutes,
      energyLevel: TaskEnergyLevel.high,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 25,
      maxChunkMinutes: 90,
      status: TaskStatus.open,
      createdAtUtc: DateTime.utc(2026, 10, 1),
      updatedAtUtc: DateTime.utc(2026, 10, 1),
    );
  }

  test('保留原始预计分钟数并把排程时长向上取整到五分钟', () {
    final task = createTask();

    expect(task.estimatedMinutes, 47);
    expect(task.schedulingEstimatedMinutes, 50);
    expect(task.remainingMinutes, 47);
    expect(task.schedulingRemainingMinutes, 50);
  });

  test('拒绝空标题以及零或负的时长', () {
    expect(() => createTask(title: '  '), throwsArgumentError);
    expect(() => createTask(estimatedMinutes: 0), throwsArgumentError);
    expect(() => createTask(remainingMinutes: -1), throwsArgumentError);
  });

  test('copyWith 修改指定字段且保留其余事实数据', () {
    final original = createTask();

    final updated = original.copyWith(
      title: '完成课程展示',
      remainingMinutes: 12,
      status: TaskStatus.inProgress,
    );

    expect(updated.id, original.id);
    expect(updated.title, '完成课程展示');
    expect(updated.estimatedMinutes, 47);
    expect(updated.remainingMinutes, 12);
    expect(updated.schedulingRemainingMinutes, 15);
    expect(updated.status, TaskStatus.inProgress);
  });
}
