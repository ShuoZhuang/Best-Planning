import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';

final _created = DateTime.utc(2026, 10, 1);

PlannerArea _area(String id) => PlannerArea(
  id: id,
  name: id,
  color: 0,
  sortOrder: 0,
  createdAtUtc: _created,
  updatedAtUtc: _created,
);

PlannerProject _project(String id, String areaId) => PlannerProject(
  id: id,
  areaId: areaId,
  name: id,
  createdAtUtc: _created,
  updatedAtUtc: _created,
);

void main() {
  test('完整草稿保存会填充任务默认值', () async {
    final repository = MemoryTaskRepository();
    final service = TaskService(
      repository: repository,
      workspace: _MemoryWorkspace(areas: [_area('area-study')]),
      clock: _FixedClock(DateTime.utc(2026, 10, 1, 8)),
      idGenerator: _FixedIdGenerator('task-1'),
    );

    final result = await service.saveDraft(
      const TaskDraft(
        title: '  阅读论文  ',
        estimatedMinutes: 47,
        areaId: 'area-study',
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(repository.saved, hasLength(1));
    final task = repository.saved.single;
    expect(task.id, 'task-1');
    expect(task.areaId, 'area-study');
    expect(task.title, '阅读论文');
    expect(task.estimatedMinutes, 47);
    expect(task.remainingMinutes, 47);
    expect(task.status, TaskStatus.open);
    expect(task.schedulingEstimatedMinutes, 50);
  });

  test('空标题和非正时长返回字段错误且不写 repository', () async {
    final repository = MemoryTaskRepository();
    final service = TaskService(
      repository: repository,
      workspace: _MemoryWorkspace(areas: [_area('area-study')]),
      clock: _FixedClock(DateTime.utc(2026, 10, 1)),
      idGenerator: _FixedIdGenerator('unused'),
    );

    final result = await service.saveDraft(
      const TaskDraft(title: ' ', estimatedMinutes: 0, areaId: 'area-study'),
    );

    expect(result.fieldErrors['title'], isNotEmpty);
    expect(result.fieldErrors['estimatedMinutes'], isNotEmpty);
    expect(repository.saved, isEmpty);
  });

  test('空或不存在的领域会被拒绝', () async {
    final repository = MemoryTaskRepository();
    final service = TaskService(
      repository: repository,
      workspace: _MemoryWorkspace(areas: [_area('area-study')]),
      clock: _FixedClock(_created),
      idGenerator: const _FixedIdGenerator('unused'),
    );

    final empty = await service.saveDraft(
      const TaskDraft(title: '作业', estimatedMinutes: 60, areaId: ''),
    );
    final missing = await service.saveDraft(
      const TaskDraft(title: '作业', estimatedMinutes: 60, areaId: 'missing'),
    );

    expect(empty.fieldErrors['areaId'], isNotEmpty);
    expect(missing.fieldErrors['areaId'], isNotEmpty);
    expect(repository.saved, isEmpty);
  });

  test('项目必须属于所选领域，但不选项目是合法的', () async {
    final repository = MemoryTaskRepository();
    final service = TaskService(
      repository: repository,
      workspace: _MemoryWorkspace(
        areas: [_area('area-study'), _area('area-work')],
        projects: [_project('project-work', 'area-work')],
      ),
      clock: _FixedClock(_created),
      idGenerator: const _FixedIdGenerator('task-1'),
    );

    final mismatch = await service.saveDraft(
      const TaskDraft(
        title: '作业',
        estimatedMinutes: 60,
        areaId: 'area-study',
        projectId: 'project-work',
      ),
    );
    expect(mismatch.fieldErrors['projectId'], isNotEmpty);

    final withoutProject = await service.saveDraft(
      const TaskDraft(title: '作业', estimatedMinutes: 60, areaId: 'area-study'),
    );
    expect(withoutProject.isSuccess, isTrue);
    expect(withoutProject.task!.projectId, isNull);
  });

  test('最早开始时间必须为 UTC 且严格早于截止时间', () async {
    final repository = MemoryTaskRepository();
    final service = TaskService(
      repository: repository,
      workspace: _MemoryWorkspace(areas: [_area('area-study')]),
      clock: _FixedClock(_created),
      idGenerator: const _FixedIdGenerator('task-1'),
    );
    final due = DateTime.utc(2026, 10, 8, 12);

    final local = await service.saveDraft(
      TaskDraft(
        title: '作业',
        estimatedMinutes: 60,
        areaId: 'area-study',
        availableFromUtc: DateTime(2026, 10, 6, 8),
        dueAtUtc: due,
      ),
    );
    final equal = await service.saveDraft(
      TaskDraft(
        title: '作业',
        estimatedMinutes: 60,
        areaId: 'area-study',
        availableFromUtc: due,
        dueAtUtc: due,
      ),
    );
    final after = await service.saveDraft(
      TaskDraft(
        title: '作业',
        estimatedMinutes: 60,
        areaId: 'area-study',
        availableFromUtc: due.add(const Duration(minutes: 1)),
        dueAtUtc: due,
      ),
    );

    expect(local.fieldErrors['availableFromUtc'], isNotEmpty);
    expect(equal.fieldErrors['availableFromUtc'], isNotEmpty);
    expect(after.fieldErrors['availableFromUtc'], isNotEmpty);
  });

  test('合法领域、项目和最早开始时间会完整保存', () async {
    final repository = MemoryTaskRepository();
    final available = DateTime.utc(2026, 10, 6, 3, 15);
    final service = TaskService(
      repository: repository,
      workspace: _MemoryWorkspace(
        areas: [_area('area-study')],
        projects: [_project('project-course', 'area-study')],
      ),
      clock: _FixedClock(_created),
      idGenerator: const _FixedIdGenerator('task-1'),
    );

    final result = await service.saveDraft(
      TaskDraft(
        title: '算法作业',
        estimatedMinutes: 60,
        areaId: 'area-study',
        projectId: 'project-course',
        availableFromUtc: available,
        dueAtUtc: DateTime.utc(2026, 10, 8),
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(result.task!.areaId, 'area-study');
    expect(result.task!.projectId, 'project-course');
    expect(result.task!.availableFromUtc, available);
  });
}

final class MemoryTaskRepository implements TaskRepository {
  final List<PlannerTask> saved = [];

  @override
  Future<PlannerTask?> getById(String id) async =>
      saved.where((task) => task.id == id).firstOrNull;

  @override
  Future<void> save(PlannerTask task) async => saved.add(task);

  /// 全量监听；这个替身没有数据库，因此"全部"与"未结束"共用一份数据。
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(saved);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(saved);
}

final class _MemoryWorkspace implements WorkspaceRepository {
  _MemoryWorkspace({this.areas = const [], this.projects = const []});

  final List<PlannerArea> areas;
  final List<PlannerProject> projects;

  @override
  Future<List<PlannerArea>> listAreas() async => areas;

  @override
  Future<List<PlannerProject>> listProjects() async => projects;

  @override
  Future<void> saveArea(PlannerArea area) => throw UnimplementedError();

  @override
  Future<void> saveProject(PlannerProject project) =>
      throw UnimplementedError();
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
