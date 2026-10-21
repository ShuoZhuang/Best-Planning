import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/internal_transport_task_guard.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';

import '../../application/execution/execution_test_support.dart';

/// Task 1 特征测试：内部周期载体不得进入普通任务流/计数。
void main() {
  test('watchAllTasks 不包含 recurring: 内部载体', () async {
    final harness = await ExecutionTestHarness.create();
    addTearDown(harness.close);
    final cycles = DriftRecurringTaskRepository(
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
    final tasks = await service.watchAllTasks().first;
    expect(
      tasks.any((task) => task.id.startsWith('recurring:')),
      false,
      reason: '内部载体不能出现在普通任务数量、搜索结果与批量完成里',
    );
    // 内部载体仍由周期服务按 id 读取，数据本身没有被删除。
    expect(
      await cycles.findCycle('template-1', DateTime(2026, 10, 19)),
      isNotNull,
    );
  });
}
