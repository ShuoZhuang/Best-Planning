import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/internal_transport_task_guard.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';

import 'execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftRecurringTaskRepository cycles;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    cycles = DriftRecurringTaskRepository(
      harness.database,
      RecurringTaskDao(harness.database),
    );
    await cycles.saveTemplate(
      RecurringTaskTemplate(
        id: 'template-1',
        title: '每周阅读',
        targetMinutes: 60,
        startsOnLocalDate: DateTime(2026, 10, 19),
        timeZoneId: 'Asia/Shanghai',
        createdAtUtc: harness.clock.nowUtc(),
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );
    await cycles.saveCycle(
      RecurringTaskCycle(
        templateId: 'template-1',
        periodStartLocalDate: DateTime(2026, 10, 19),
        taskId: 'task-1',
        baseTargetMinutes: 60,
        carryInMinutes: 0,
        status: RecurringCycleStatus.open,
        createdAtUtc: harness.clock.nowUtc(),
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );
  });

  tearDown(() => harness.close());

  test('普通任务服务拒绝直接完成内部周期载体', () async {
    final guard = InternalTransportTaskGuard(cycles);
    final service = TaskService(
      repository: harness.taskRepository,
      clock: harness.clock,
      idGenerator: harness.ids,
      transportGuard: guard,
    );
    expect(await guard.isTransport('task-1'), true);
    expect(await service.changeStatus('task-1', TaskStatus.completed), false);
    final result = await service.updateDraft(
      'task-1',
      const TaskDraft(title: '改名', estimatedMinutes: 60, areaId: 'area-1'),
    );
    expect(result.isSuccess, false);
    expect(result.fieldErrors.containsKey('taskId'), true);
    expect(
      (await service.correctRemainingMinutes('task-1', 5)).isSuccess,
      false,
    );
    expect(
      (await service.setDueDate('task-1', harness.clock.nowUtc())).isSuccess,
      false,
    );
    expect(
      (await service.deferTask(
        'task-1',
        by: const Duration(minutes: 5),
      )).isSuccess,
      false,
    );
    expect(
      (await service.setPriority('task-1', TaskPriority.high)).isSuccess,
      false,
    );
    expect(await service.assignProject('task-1', null), false);
    expect(
      await service.setPreferredWindow(
        'task-1',
        startMinute: 600,
        endMinute: 660,
      ),
      false,
    );
    final task = await harness.taskRepository.getById('task-1');
    expect(task!.status, TaskStatus.open);
  });

  test('普通任务仍可正常完成，成员资格检查不误伤', () async {
    await harness.taskRepository.save(
      PlannerTask(
        id: 'ordinary-1',
        areaId: 'area-1',
        title: '普通任务',
        estimatedMinutes: 30,
        remainingMinutes: 30,
        priority: TaskPriority.medium,
        energyLevel: TaskEnergyLevel.medium,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 25,
        maxChunkMinutes: 90,
        status: TaskStatus.open,
        createdAtUtc: harness.clock.nowUtc(),
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );
    final service = TaskService(
      repository: harness.taskRepository,
      clock: harness.clock,
      idGenerator: harness.ids,
      transportGuard: InternalTransportTaskGuard(cycles),
    );
    expect(
      await service.changeStatus('ordinary-1', TaskStatus.completed),
      true,
    );
    expect(
      (await harness.taskRepository.getById('ordinary-1'))!.status,
      TaskStatus.completed,
    );
  });

  test('普通任务流不包含内部周期载体，搜索/计数不会把它们当普通任务', () async {
    await harness.taskRepository.save(
      PlannerTask(
        id: 'recurring:template-1:2026-10-19',
        areaId: 'area-1',
        title: '每周阅读',
        estimatedMinutes: 60,
        remainingMinutes: 60,
        priority: TaskPriority.medium,
        energyLevel: TaskEnergyLevel.medium,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 25,
        maxChunkMinutes: 90,
        status: TaskStatus.open,
        createdAtUtc: harness.clock.nowUtc(),
        updatedAtUtc: harness.clock.nowUtc(),
      ),
    );
    final service = TaskService(
      repository: harness.taskRepository,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
    final visible = await service.watchAllTasks().first;
    expect(visible.map((task) => task.id), ['task-1']);
  });
}
