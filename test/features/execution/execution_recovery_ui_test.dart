import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/execution/execution_commands.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/features/execution/execution_recovery_controller.dart';
import 'package:personal_planner/features/execution/execution_recovery_dialog.dart';

import '../../application/execution/execution_test_support.dart';

final class _FakeRecoveryService implements ExecutionRecoveryService {
  _FakeRecoveryService(this.nowUtc);

  final DateTime nowUtc;
  RequestExecutionRecoveryCommand? requested;
  ApplyExecutionRecoveryCommand? applied;
  CancelExecutionRecoveryCommand? cancelled;
  bool failNext = false;

  @override
  String get processEpoch => 'process-epoch-1';

  @override
  Future<ExecutionRecoveryDraftResult> requestRecovery(
    RequestExecutionRecoveryCommand command,
  ) async {
    requested = command;
    if (failNext) {
      return ExecutionRecoveryDraftResult(
        result: ExecutionCommandResult.failure(
          ExecutionResultStatus.invalid,
          ExecutionReasonCode.proposalInvalid,
          operationId: command.operationId,
        ),
      );
    }
    final draft = ExecutionRecoveryDraft(
      draftId: 'draft-1',
      proposalId: 'proposal-1',
      occurrenceId: command.occurrenceId,
      processEpoch: processEpoch,
      state: ExecutionDraftState.open,
      revision: 1,
      createdAtUtc: nowUtc,
      notBeforeUtc: command.notBeforeUtc,
      targetShareMicros: command.targetShareMicros ?? 40 * 60 * 1000000,
      holdToday: command.holdToday,
      inputHash: 'input-hash',
      planVersionId: command.planVersionId,
      unassignedMinutes: 0,
      preview: ExecutionRecoveryPreview(
        blocks: [
          ExecutionRecoveryPreviewBlock(
            taskId: 'task-1',
            startUtc: nowUtc.add(const Duration(minutes: 5)),
            endUtc: nowUtc.add(const Duration(minutes: 45)),
            isOccurrenceTask: true,
          ),
        ],
        shortages: const [],
      ),
    );
    return ExecutionRecoveryDraftResult(
      result: ExecutionCommandResult.applied(
        operationId: command.operationId,
        occurrenceId: command.occurrenceId,
      ),
      draft: draft,
    );
  }

  @override
  Future<ExecutionCommandResult> applyRecovery(
    ApplyExecutionRecoveryCommand command,
  ) async {
    applied = command;
    return ExecutionCommandResult.applied(
      operationId: command.operationId,
      occurrenceId: 'occurrence-1',
    );
  }

  @override
  Future<ExecutionCommandResult> cancelRecovery(
    CancelExecutionRecoveryCommand command,
  ) async {
    cancelled = command;
    return ExecutionCommandResult.applied(
      operationId: command.operationId,
      occurrenceId: 'occurrence-1',
    );
  }
}

void main() {
  late ExecutionTestHarness harness;
  late _FakeRecoveryService service;
  late ExecutionRecoveryController controller;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    await harness.seedOccurrence();
    service = _FakeRecoveryService(harness.clock.nowUtc());
    controller = ExecutionRecoveryController(
      service: service,
      repository: harness.repository,
      tasks: harness.taskRepository,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
  });

  tearDown(() async {
    controller.dispose();
    await harness.close();
  });

  test('请求恢复使用当前实例、计划版本与任务哈希', () async {
    final ok = await controller.request(
      occurrenceId: 'occurrence-1',
      holdToday: true,
    );
    expect(ok, isTrue);
    expect(controller.draft, isNotNull);
    final command = service.requested!;
    expect(command.occurrenceId, 'occurrence-1');
    expect(command.planVersionId, 'plan-1');
    expect(command.holdToday, isTrue);
    expect(command.processEpoch, 'process-epoch-1');
    expect(command.notBeforeUtc, harness.clock.nowUtc());
  });

  test('应用使用草案的 proposalId/inputHash，成功后清空草案', () async {
    await controller.request(occurrenceId: 'occurrence-1');
    final ok = await controller.apply();
    expect(ok, isTrue);
    final command = service.applied!;
    expect(command.draftId, 'draft-1');
    expect(command.proposalId, 'proposal-1');
    expect(command.inputHash, 'input-hash');
    expect(command.authorizationMode, isNotNull);
    expect(controller.draft, isNull);
  });

  test('取消调用服务并释放草案，不留下可应用的旧对象', () async {
    await controller.request(occurrenceId: 'occurrence-1');
    await controller.cancel();
    expect(service.cancelled, isNotNull);
    expect(controller.draft, isNull);
  });

  testWidgets('预览对话框列出受影响块并在确认后应用', (tester) async {
    await controller.request(occurrenceId: 'occurrence-1');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showExecutionRecoveryDialog(
                  context,
                  controller: controller,
                  title: '蓝桥杯竞赛课',
                  formatTime: (value) =>
                      '${value.hour}:${value.minute.toString().padLeft(2, '0')}',
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.textContaining('本次安排'), findsOneWidget);
    expect(find.text('应用'), findsOneWidget);
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(service.applied, isNotNull);
    expect(controller.draft, isNull);
  });
}
