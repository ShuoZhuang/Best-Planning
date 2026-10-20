import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/execution/execution_commands.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/domain/models/task.dart';

import 'execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
  });

  tearDown(() => harness.close());

  test('补记10分钟只入账一次，重复操作重放原结果', () async {
    final command = await harness.recordManualCommand(
      operationId: 'op-manual',
      duration: const Duration(minutes: 10),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 10)),
      includedInAnchor: false,
    );
    final first = await harness.service.recordManual(command);
    final second = await harness.service.recordManual(command);
    expect(first.status, ExecutionResultStatus.applied);
    expect(second.status, ExecutionResultStatus.alreadyApplied);
    expect(await harness.taskRemainingMinutes('task-1'), 35);
  });

  test('同一操作ID不同补记请求被拒绝', () async {
    await harness.recordManual(
      operationId: 'op-manual',
      duration: const Duration(minutes: 10),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 10)),
      includedInAnchor: false,
    );
    final reused = await harness.recordManual(
      operationId: 'op-manual',
      duration: const Duration(minutes: 12),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 12)),
      includedInAnchor: false,
    );
    expect(reused.status, ExecutionResultStatus.invalid);
    expect(reused.reasonCode, ExecutionReasonCode.operationIdReused);
    expect(await harness.taskRemainingMinutes('task-1'), 35);
  });

  test('重启后重放同一操作返回原结果，不重复扣分钟', () async {
    final command = await harness.recordManualCommand(
      operationId: 'op-manual',
      duration: const Duration(minutes: 10),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 10)),
      includedInAnchor: false,
    );
    await harness.service.recordManual(command);
    final restarted = harness.restartService();
    final replay = await restarted.recordManual(command);
    expect(replay.status, ExecutionResultStatus.alreadyApplied);
    expect(await harness.taskRemainingMinutes('task-1'), 35);
  });

  test('补记与既有记录重叠：先要求确认，缩短后只入账未占用部分', () async {
    await harness.recordManual(
      operationId: 'op-first',
      duration: const Duration(minutes: 10),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 30)),
      includedInAnchor: false,
    );
    final start = harness.clock.nowUtc().subtract(const Duration(minutes: 25));
    final pending = await harness.recordManual(
      operationId: 'op-second',
      duration: const Duration(minutes: 10),
      startUtc: start,
      includedInAnchor: false,
    );
    expect(pending.status, ExecutionResultStatus.needsConfirmation);
    expect(pending.confirmationToken, isNotNull);
    expect(await harness.taskRemainingMinutes('task-1'), 35);

    final shortened = await harness.recordManual(
      operationId: 'op-third',
      duration: const Duration(minutes: 10),
      startUtc: start,
      includedInAnchor: false,
      overlapResolution: ExecutionOverlapResolution.shortenNew,
    );
    expect(shortened.status, ExecutionResultStatus.applied);
    // 第一段 30→20 分钟前；第二段 25→15 分钟前与第一段重叠 5 分钟，只入账 5 分钟。
    expect(await harness.taskRemainingMinutes('task-1'), 30);
  });

  test('重叠时保留叙述但不计入进度', () async {
    await harness.recordManual(
      operationId: 'op-first',
      duration: const Duration(minutes: 10),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 30)),
      includedInAnchor: false,
    );
    final nonCrediting = await harness.recordManual(
      operationId: 'op-second',
      duration: const Duration(minutes: 10),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 25)),
      includedInAnchor: false,
      overlapResolution: ExecutionOverlapResolution.saveNonCrediting,
    );
    expect(nonCrediting.status, ExecutionResultStatus.applied);
    expect(await harness.taskRemainingMinutes('task-1'), 35);
  });

  test('替换旧记录：旧投入被撤回，新记录重新入账', () async {
    await harness.recordManual(
      operationId: 'op-first',
      duration: const Duration(minutes: 10),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 30)),
      includedInAnchor: false,
    );
    final replaced = await harness.recordManual(
      operationId: 'op-second',
      duration: const Duration(minutes: 20),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 25)),
      includedInAnchor: false,
      overlapResolution: ExecutionOverlapResolution.replaceExisting,
    );
    expect(replaced.status, ExecutionResultStatus.applied);
    expect(await harness.taskRemainingMinutes('task-1'), 25);
  });

  test('晚补记早于人工检查点：未回答时要求确认；选择已包含则不再扣', () async {
    // 先建立检查点并做 5 分钟。
    await harness.recordManual(
      operationId: 'op-first',
      duration: const Duration(minutes: 5),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 5)),
      includedInAnchor: false,
    );
    expect(await harness.taskRemainingMinutes('task-1'), 40);
    final pending = await harness.recordManual(
      operationId: 'op-late',
      duration: const Duration(minutes: 10),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 20)),
    );
    expect(pending.status, ExecutionResultStatus.needsConfirmation);
    expect(pending.parameters['confirmationKind'], 'lateWithinAnchor');

    final included = await harness.recordManual(
      operationId: 'op-late-included',
      duration: const Duration(minutes: 10),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 20)),
      includedInAnchor: true,
    );
    expect(included.status, ExecutionResultStatus.applied);
    expect(await harness.taskRemainingMinutes('task-1'), 40);
  });

  test('更正记录使进度可逆且幂等', () async {
    final recorded = await harness.recordManual(
      operationId: 'op-manual',
      duration: const Duration(minutes: 10),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 10)),
      includedInAnchor: false,
    );
    expect(await harness.taskRemainingMinutes('task-1'), 35);
    final anchor = await harness.repository.currentAnchor('task-1');
    final corrected = await harness.service.correctRecord(
      CorrectExecutionRecordCommand(
        operationId: 'op-correct',
        dataEpoch: (await harness.status()).dataEpoch,
        recordId: recorded.sessionId!,
        segmentStartUtc: harness.clock.nowUtc().subtract(
          const Duration(minutes: 7),
        ),
        segmentEndUtc: harness.clock.nowUtc(),
        recordRevision: 1,
        newTargetKind: ExecutionTargetKind.task,
        newTargetId: 'task-1',
        newTargetProgressAnchorRevision: anchor!.revision,
        note: '更正为7分钟',
      ),
    );
    expect(corrected.status, ExecutionResultStatus.applied);
    expect(await harness.taskRemainingMinutes('task-1'), 38);

    // 第二次更正：7 分 30 秒 -> 精确剩余 37.5 分钟，调度向上取整为 38。
    final secondLink = await harness.repository.findSessionLink(
      recorded.sessionId!,
    );
    final secondAnchor = await harness.repository.currentAnchor('task-1');
    final correctedAgain = await harness.service.correctRecord(
      CorrectExecutionRecordCommand(
        operationId: 'op-correct-2',
        dataEpoch: (await harness.status()).dataEpoch,
        recordId: recorded.sessionId!,
        segmentStartUtc: harness.clock.nowUtc().subtract(
          const Duration(minutes: 7, seconds: 30),
        ),
        segmentEndUtc: harness.clock.nowUtc(),
        recordRevision: secondLink!.revision,
        newTargetKind: ExecutionTargetKind.task,
        newTargetId: 'task-1',
        newTargetProgressAnchorRevision: secondAnchor!.revision,
        note: '更正为7分30秒',
      ),
    );
    expect(correctedAgain.status, ExecutionResultStatus.applied);
    expect(await harness.taskRemainingMinutes('task-1'), 38);
  });

  test('已完成任务的记录被更正：保留完成决定，只更新进度', () async {
    final started = await harness.service.start(
      await harness.startCommand(operationId: 'op-start'),
    );
    harness.clock.advance(const Duration(minutes: 5));
    await harness.service.finish(await harness.finishCommand('op-finish'));
    final link = await harness.repository.findSessionLink(started.sessionId!);
    final task = await harness.taskRepository.getById('task-1');
    await harness.taskRepository.save(
      task!.copyWith(status: TaskStatus.completed),
    );
    final anchor = await harness.repository.currentAnchor('task-1');
    final result = await harness.service.correctRecord(
      CorrectExecutionRecordCommand(
        operationId: 'op-correct',
        dataEpoch: (await harness.status()).dataEpoch,
        recordId: started.sessionId!,
        segmentStartUtc: harness.clock.nowUtc().subtract(
          const Duration(minutes: 3),
        ),
        segmentEndUtc: harness.clock.nowUtc(),
        recordRevision: link!.revision,
        newTargetKind: ExecutionTargetKind.task,
        newTargetId: 'task-1',
        newTargetProgressAnchorRevision: anchor!.revision,
        note: '更正为3分钟',
      ),
    );
    expect(result.status, ExecutionResultStatus.applied);
    final after = await harness.taskRepository.getById('task-1');
    expect(after!.status, TaskStatus.completed);
    expect(after.remainingMinutes, 42);
  });

  test('修正剩余后更正较早投入：更新统计但不反向覆盖较新人工剩余', () async {
    final recorded = await harness.recordManual(
      operationId: 'op-manual',
      duration: const Duration(minutes: 5),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 5)),
      includedInAnchor: false,
    );
    // 用户在任务详情里把剩余改成 30，并建立新的检查点。
    final task = await harness.taskRepository.getById('task-1');
    await harness.taskRepository.save(task!.copyWith(remainingMinutes: 30));
    final sequence = await harness.repository.currentSequence();
    await harness.repository.appendAnchor(
      taskId: 'task-1',
      anchorRemainingMicros: 30 * 60 * 1000000,
      anchorSequence: sequence,
      reason: 'externalManualCorrection',
    );
    final anchor = await harness.repository.currentAnchor('task-1');
    final link = await harness.repository.findSessionLink(recorded.sessionId!);

    final corrected = await harness.service.correctRecord(
      CorrectExecutionRecordCommand(
        operationId: 'op-correct',
        dataEpoch: (await harness.status()).dataEpoch,
        recordId: recorded.sessionId!,
        segmentStartUtc: harness.clock.nowUtc().subtract(
          const Duration(minutes: 3),
        ),
        segmentEndUtc: harness.clock.nowUtc(),
        recordRevision: link!.revision,
        newTargetKind: ExecutionTargetKind.task,
        newTargetId: 'task-1',
        newTargetProgressAnchorRevision: anchor!.revision,
        note: '把旧记录从5分钟改为3分钟',
      ),
    );
    expect(corrected.status, ExecutionResultStatus.applied);
    expect(await harness.taskRemainingMinutes('task-1'), 30);
    final segments = await harness.database
        .customSelect(
          'SELECT start_utc, end_utc FROM execution_activity_segments '
          'WHERE invalidated_reason IS NULL',
        )
        .get();
    final activeMicros = segments.fold<int>(
      0,
      (sum, row) =>
          sum + (row.read<int>('end_utc') - row.read<int>('start_utc')),
    );
    expect(activeMicros, 3 * 60 * 1000000);
  });

  test('备注超长被拒绝且不写记录', () async {
    final result = await harness.recordManual(
      operationId: 'op-manual',
      duration: const Duration(minutes: 5),
      startUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 5)),
      includedInAnchor: false,
      note: 'a' * 501,
    );
    expect(result.status, ExecutionResultStatus.invalid);
    expect(result.reasonCode, ExecutionReasonCode.invalidNote);
    expect(await harness.taskRemainingMinutes('task-1'), 45);
  });

  group('稍后提醒', () {
    test('通知关闭时不假装已设置', () async {
      final disabled = await ExecutionTestHarness.create(
        notifications: const AlwaysEnabledNotifications(enabled: false),
      );
      addTearDown(disabled.close);
      await disabled.seedOccurrence();
      final runtime = await disabled.status();
      final result = await disabled.service.setSnooze(
        SetExecutionSnoozeCommand(
          operationId: 'op-snooze',
          dataEpoch: runtime.dataEpoch,
          occurrenceId: 'occurrence-1',
          elapsedMinutes: 10,
          occurrenceRevision: 1,
          reminderRevision: 0,
          notificationSettingsHash: 'settings-hash',
        ),
      );
      expect(result.status, ExecutionResultStatus.notificationsDisabled);
      expect(await disabled.repository.currentReminder('occurrence-1'), isNull);
    });

    test('从点击时刻起算10分钟；后一次替换前一次', () async {
      await harness.seedOccurrence();
      final target = harness.clock.nowUtc().add(const Duration(minutes: 10));
      final first = await harness.service.setSnooze(
        SetExecutionSnoozeCommand(
          operationId: 'op-snooze',
          dataEpoch: (await harness.status()).dataEpoch,
          occurrenceId: 'occurrence-1',
          elapsedMinutes: 10,
          occurrenceRevision: 1,
          reminderRevision: 0,
          notificationSettingsHash: 'settings-hash',
        ),
      );
      expect(first.status, ExecutionResultStatus.applied);
      harness.clock.advance(const Duration(minutes: 1));
      final second = await harness.service.setSnooze(
        SetExecutionSnoozeCommand(
          operationId: 'op-snooze-2',
          dataEpoch: (await harness.status()).dataEpoch,
          occurrenceId: 'occurrence-1',
          elapsedMinutes: 10,
          occurrenceRevision: 1,
          reminderRevision: 1,
          notificationSettingsHash: 'settings-hash',
        ),
      );
      expect(second.status, ExecutionResultStatus.applied);
      final current = await harness.repository.currentReminder('occurrence-1');
      expect(current!.revision, 2);
      expect(
        current.targetAtUtc,
        harness.clock.nowUtc().add(const Duration(minutes: 10)),
      );
      expect(current.targetAtUtc.isAfter(target), isTrue);
    });

    test('目标落入免打扰时保存 suppressed，不推迟发送', () async {
      final quiet = await ExecutionTestHarness.create(
        notifications: const AlwaysEnabledNotifications(quiet: true),
      );
      addTearDown(quiet.close);
      await quiet.seedOccurrence();
      final result = await quiet.service.setSnooze(
        SetExecutionSnoozeCommand(
          operationId: 'op-snooze',
          dataEpoch: (await quiet.status()).dataEpoch,
          occurrenceId: 'occurrence-1',
          elapsedMinutes: 10,
          occurrenceRevision: 1,
          reminderRevision: 0,
          notificationSettingsHash: 'settings-hash',
        ),
      );
      expect(result.status, ExecutionResultStatus.applied);
      final current = await quiet.repository.currentReminder('occurrence-1');
      expect(current!.state, ExecutionReminderState.suppressed);
    });
  });

  test('更正会话归属到另一任务：旧任务恢复、新任务扣减、信用守恒', () async {
    await harness.taskRepository.save(
      PlannerTask(
        id: 'task-2',
        areaId: 'area-1',
        title: '另一件事',
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
    final started = await harness.service.start(
      await harness.startCommand(
        operationId: 'op-start',
        targetDurationMicros: 5 * 60 * 1000000,
      ),
    );
    harness.clock.advance(const Duration(minutes: 5));
    await harness.service.finish(await harness.finishCommand('op-finish'));
    expect(await harness.taskRemainingMinutes('task-1'), 40);

    final link = await harness.repository.findSessionLink(started.sessionId!);
    await harness.repository.appendAnchor(
      taskId: 'task-2',
      anchorRemainingMicros: 30 * 60 * 1000000,
      anchorSequence: await harness.repository.currentSequence(),
      reason: 'testReassignTarget',
    );
    final targetAnchor = await harness.repository.currentAnchor('task-2');
    final corrected = await harness.service.correctRecord(
      CorrectExecutionRecordCommand(
        operationId: 'op-reassign',
        dataEpoch: (await harness.status()).dataEpoch,
        recordId: started.sessionId!,
        segmentStartUtc: harness.clock.nowUtc().subtract(
          const Duration(minutes: 5),
        ),
        segmentEndUtc: harness.clock.nowUtc(),
        recordRevision: link!.revision,
        newTargetKind: ExecutionTargetKind.task,
        newTargetId: 'task-2',
        newTargetProgressAnchorRevision: targetAnchor?.revision ?? 0,
        note: '归属改到另一件事',
      ),
    );
    expect(corrected.status, ExecutionResultStatus.applied);
    expect(await harness.taskRemainingMinutes('task-1'), 45);
    expect(await harness.taskRemainingMinutes('task-2'), 25);
    final credits = await harness.database
        .customSelect(
          'SELECT target_id, amount_micros FROM execution_credit_allocations',
        )
        .get();
    expect(
      credits.fold<int>(0, (sum, row) => sum + row.read<int>('amount_micros')),
      5 * 60 * 1000000,
    );
    expect(
      credits.map((row) => row.read<String>('target_id')),
      contains('task-2'),
    );
  });
}
