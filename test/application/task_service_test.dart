import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

void main() {
  test('快速录入只需标题和预计时长并填充收集箱默认值', () async {
    final repository = MemoryTaskRepository();
    final service = TaskService(
      repository: repository,
      clock: _FixedClock(DateTime.utc(2026, 10, 1, 8)),
      idGenerator: _FixedIdGenerator('task-1'),
    );

    final result = await service.quickAdd('  阅读论文  ', 47);

    expect(result.isSuccess, isTrue);
    expect(repository.saved, hasLength(1));
    final task = repository.saved.single;
    expect(task.id, 'task-1');
    expect(task.title, '阅读论文');
    expect(task.estimatedMinutes, 47);
    expect(task.remainingMinutes, 47);
    expect(task.status, TaskStatus.inbox);
    expect(task.schedulingEstimatedMinutes, 50);
  });

  test('空标题和非正时长返回字段错误且不写 repository', () async {
    final repository = MemoryTaskRepository();
    final service = TaskService(
      repository: repository,
      clock: _FixedClock(DateTime.utc(2026, 10, 1)),
      idGenerator: _FixedIdGenerator('unused'),
    );

    final result = await service.quickAdd(' ', 0);

    expect(result.fieldErrors['title'], isNotEmpty);
    expect(result.fieldErrors['estimatedMinutes'], isNotEmpty);
    expect(repository.saved, isEmpty);
  });
}

final class MemoryTaskRepository implements TaskRepository {
  final List<PlannerTask> saved = [];

  @override
  Future<PlannerTask?> getById(String id) async =>
      saved.where((task) => task.id == id).firstOrNull;

  @override
  Future<void> save(PlannerTask task) async => saved.add(task);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(saved);
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _FixedIdGenerator implements IdGenerator {
  const _FixedIdGenerator(this.value);
  final String value;
  @override
  String next() => value;
}
