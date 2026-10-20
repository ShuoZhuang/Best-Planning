import 'package:personal_planner/domain/models/time_range.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/execution/execution_commands.dart';
import 'package:personal_planner/application/execution/execution_plan_linker.dart';
import 'package:personal_planner/application/execution/execution_recovery_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

import 'execution_test_support.dart';

final class _NoPlans implements PlanRepository {
  @override
  Future<ConfirmedPlan?> current() async => null;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();
}

final class _UnusedSource implements ScheduleProblemSource {
  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override, TimeRange? window}) async {
    throw StateError('测试不应走到排程输入装配');
  }
}

void main() {
  late ExecutionTestHarness harness;
  late DriftExecutionRecoveryService service;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    service = DriftExecutionRecoveryService(
      repository: harness.repository,
      tasks: harness.taskRepository,
      plans: _NoPlans(),
      baseSource: _UnusedSource(),
      engine: DeterministicScheduleEngine(TimeZoneDatabase()),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      clock: harness.clock,
      idGenerator: harness.ids,
      linker: ExecutionPlanLinker(
        repository: harness.repository,
        zones: TimeZoneDatabase(),
        idGenerator: harness.ids,
        clock: harness.clock,
      ),
    );
  });

  tearDown(() => harness.close());

  RequestExecutionRecoveryCommand command({
    String planVersionId = 'plan-1',
    String processEpoch = '',
    int occurrenceRevision = 1,
  }) => RequestExecutionRecoveryCommand(
    operationId: 'op-recovery',
    dataEpoch: 'epoch',
    occurrenceId: 'occurrence-1',
    notBeforeUtc: harness.clock.nowUtc(),
    occurrenceRevision: occurrenceRevision,
    planVersionId: planVersionId,
    taskInputHash: '',
    progressAnchorRevision: 0,
    processEpoch: processEpoch.isEmpty ? service.processEpoch : processEpoch,
  );

  test('实例没有当前计划来源时明确报 sourceMappingMissing，不猜计划块', () async {
    final occurrence = await harness.seedOccurrence();
    await harness.repository.updateOccurrence(
      occurrence.copyWith(clearCurrentPlanVersionId: true),
    );

    final result = await service.requestRecovery(command());
    expect(result.result.status, ExecutionResultStatus.sourceMappingMissing);
    expect(result.result.reasonCode, ExecutionReasonCode.sourceMappingMissing);
    expect(result.draft, isNull);
    expect(service.openDraftCount, 0);
  });

  test('进程代次不一致时旧草案入口返回 stale', () async {
    await harness.seedOccurrence();
    final result = await service.requestRecovery(
      command(processEpoch: 'old-process'),
    );
    expect(result.result.status, ExecutionResultStatus.stale);
    expect(result.result.reasonCode, ExecutionReasonCode.draftExpired);
    expect(service.openDraftCount, 0);
  });

  test('计划版本不一致时拒绝生成恢复预览', () async {
    await harness.seedOccurrence();
    final result = await service.requestRecovery(
      command(planVersionId: 'another-plan'),
    );
    expect(result.result.status, ExecutionResultStatus.sourceMappingMissing);
    expect(service.openDraftCount, 0);
  });
}
