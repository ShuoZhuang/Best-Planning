// FR-FOCUS-05 的"按专注记录重算剩余时长"。
//
// 口径（按默认选定）：`remaining = max(0, 预计时长 − 实际专注分钟)`；算到 0 时**同时把任务
// 标记为已完成**——0 剩余与"做完了"是同一件事的两种表达。本文件钉住的正是这两条：算出的数字，
// 以及"归零必须同时完成"。
//
// 这里用真实的 `TaskService` 加一个内存仓储，而不是替身服务：被验证的是服务自己的算法与
// 状态联动。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

final _now = DateTime.utc(2026, 10, 5, 9);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'id-${++_count}';
}

final class _Tasks implements TaskRepository {
  _Tasks(this.tasks);
  final Map<String, PlannerTask> tasks;

  /// 全量监听；这个替身没有数据库，因此"全部"与"未结束"共用一份数据。
  @override
  Stream<List<PlannerTask>> watchAllTasks() =>
      Stream.value(tasks.values.toList());

  @override
  Stream<List<PlannerTask>> watchOpenTasks() =>
      Stream.value(tasks.values.toList());

  @override
  Future<PlannerTask?> getById(String id) async => tasks[id];
  @override
  Future<void> save(PlannerTask task) async => tasks[task.id] = task;
}

PlannerTask _task({
  int estimated = 90,
  int remaining = 90,
  TaskStatus status = TaskStatus.open,
}) => PlannerTask(
  id: 'task-1',
  title: '写方案',
  notes: '',
  priority: TaskPriority.medium,
  estimatedMinutes: estimated,
  remainingMinutes: remaining,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 15,
  maxChunkMinutes: 60,
  status: status,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  late _Tasks tasks;
  late TaskService service;

  setUp(() {
    tasks = _Tasks({'task-1': _task()});
    service = TaskService(
      repository: tasks,
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
  });

  test('专注不足预计时长时，剩余时长等于差额，状态不变', () async {
    final result = await service.applyFocusRecompute(
      taskId: 'task-1',
      actualMinutes: 30,
    );

    expect(result.isSuccess, isTrue);
    expect(tasks.tasks['task-1']!.remainingMinutes, 60);
    expect(tasks.tasks['task-1']!.status, TaskStatus.open);
  });

  test('专注正好覆盖预计时长时归 0 并标记完成', () async {
    await service.applyFocusRecompute(taskId: 'task-1', actualMinutes: 90);

    // 归零必须同时完成：否则任务留在待排池里却没有任何可排时长。
    expect(tasks.tasks['task-1']!.remainingMinutes, 0);
    expect(tasks.tasks['task-1']!.status, TaskStatus.completed);
  });

  test('专注超出预计时长时剩余仍为 0（而不是负数）', () async {
    await service.applyFocusRecompute(taskId: 'task-1', actualMinutes: 120);

    // 负数会撞域不变量；钳到 0 才是"没有剩余工作"。
    expect(tasks.tasks['task-1']!.remainingMinutes, 0);
    expect(tasks.tasks['task-1']!.status, TaskStatus.completed);
  });

  test('没有专注记录时剩余时长回到预计时长', () async {
    tasks.tasks['task-1'] = _task(remaining: 20);

    await service.applyFocusRecompute(taskId: 'task-1', actualMinutes: 0);

    expect(tasks.tasks['task-1']!.remainingMinutes, 90);
    expect(tasks.tasks['task-1']!.status, TaskStatus.open);
  });

  test('任务不存在或实际时长为负时明确失败，不写库', () async {
    final missing = await service.applyFocusRecompute(
      taskId: 'nope',
      actualMinutes: 10,
    );
    final negative = await service.applyFocusRecompute(
      taskId: 'task-1',
      actualMinutes: -1,
    );

    expect(missing.isSuccess, isFalse);
    expect(negative.isSuccess, isFalse);
    expect(tasks.tasks['task-1']!.remainingMinutes, 90);
  });
}
