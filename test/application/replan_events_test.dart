// FR-STAT-06 的"重排原因"来源：任务排程输入变化时记一条 `replan:` 事件。
//
// 此前这一类事件**没有任何写入方**（W5 剩下的那一类），因此统计页的"重排原因"永远空着。
// 本文件钉住四类变化各自的原因码——原因码会**直接显示给用户**，所以它必须是人话而不是内部
// 枚举名；另外钉住"未装配回调时不报错"，因为任务服务不该依赖统计是否可用。
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
  @override
  Stream<List<PlannerTask>> watchOpenTasks() =>
      Stream.value(tasks.values.toList());
  @override
  Future<PlannerTask?> getById(String id) async => tasks[id];
  @override
  Future<void> save(PlannerTask task) async => tasks[task.id] = task;
}

PlannerTask _task() => PlannerTask(
  id: 'task-1',
  title: '写方案',
  notes: '',
  priority: TaskPriority.medium,
  estimatedMinutes: 90,
  remainingMinutes: 90,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 15,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 1),
);

void main() {
  late _Tasks tasks;
  late List<String> reasons;

  TaskService build({bool withCallback = true}) => TaskService(
    repository: tasks,
    clock: const _Clock(),
    idGenerator: _Ids(),
    onScheduleInputChanged: withCallback ? reasons.add : null,
  );

  setUp(() {
    tasks = _Tasks({'task-1': _task()});
    reasons = [];
  });

  test('改截止日期记一条"截止日期变化"', () async {
    await build().setDueDate('task-1', DateTime.utc(2026, 10, 20));

    expect(reasons, <String>['截止日期变化']);
  });

  test('改优先级记一条"优先级变化"', () async {
    await build().setPriority('task-1', TaskPriority.high);

    expect(reasons, <String>['优先级变化']);
  });

  test('改剩余时长记一条"剩余时长修正"', () async {
    await build().correctRemainingMinutes('task-1', 30);

    expect(reasons, <String>['剩余时长修正']);
  });

  test('改状态记一条"状态变化"', () async {
    await build().changeStatus('task-1', TaskStatus.completed);

    expect(reasons, <String>['状态变化']);
  });

  test('失败的修改不记原因（改不动就没有重排）', () async {
    final service = build();

    await service.setDueDate('missing', DateTime.utc(2026, 10, 20));
    await service.correctRemainingMinutes('task-1', -1);

    expect(reasons, isEmpty);
  });

  test('未装配回调时照常改任务，只是不留原因', () async {
    final service = build(withCallback: false);

    await service.setPriority('task-1', TaskPriority.high);

    expect(tasks.tasks['task-1']!.priority, TaskPriority.high);
    expect(reasons, isEmpty);
  });
}
