import 'package:personal_planner/domain/repositories/recurring_task_repository.dart';

/// 普通任务入口对“内部周期载体”的成员资格防线（1.11.0 周期 Task 5）。
///
/// 内部载体是排程兼容投影，不是用户任务；普通完成、编辑、删除、深链不得直接改它的
/// `tasks` 行。命中时调用方应转向周期详情/片段入口。
final class InternalTransportTaskGuard {
  const InternalTransportTaskGuard(this.cycles);

  final RecurringTaskRepository cycles;

  Future<InternalTransportDenial?> check(String taskId) async {
    final cycle = await cycles.findCycleByTaskId(taskId);
    if (cycle == null) return null;
    return InternalTransportDenial(
      taskId: taskId,
      templateId: cycle.templateId,
      periodStartLocalDate: cycle.periodStartLocalDate,
    );
  }

  Future<bool> isTransport(String taskId) async => await check(taskId) != null;
}

final class InternalTransportDenial {
  const InternalTransportDenial({
    required this.taskId,
    required this.templateId,
    required this.periodStartLocalDate,
  });

  final String taskId;
  final String templateId;
  final DateTime periodStartLocalDate;

  String get route => '/tasks/recurring/$templateId';
}
