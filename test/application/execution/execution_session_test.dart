import 'package:personal_planner/domain/models/time_range.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/execution/execution_availability.dart';
import 'package:personal_planner/application/execution/execution_commands.dart';
import 'package:personal_planner/application/execution/execution_input_hashes.dart';
import 'package:personal_planner/application/execution/execution_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

import 'execution_test_support.dart';

final class _NeverSource implements ScheduleProblemSource {
  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override, TimeRange? window}) async {
    throw StateError('截止时间已过时不应装配排程输入');
  }
}

void main() {
  late ExecutionTestHarness harness;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
  });

  tearDown(() => harness.close());

  Future<ExecutionCommandResult> start({
    String operationId = 'op-start',
    String? occurrenceId,
    int? occurrenceRevision,
    int? targetDurationMicros,
  }) async {
    return harness.service.start(
      await harness.startCommand(
        operationId: operationId,
        occurrenceId: occurrenceId,
        occurrenceRevision: occurrenceRevision,
        targetDurationMicros: targetDurationMicros,
      ),
    );
  }

  group('EXE-01/19 开始与会话槽位', () {
    test('今日页一次开始就建立持久会话、关联与事件', () async {
      final result = await start();
      expect(result.status, ExecutionResultStatus.applied);
      expect(result.sessionId, isNotNull);

      final status = await harness.status();
      expect(status.activeSession, isNotNull);
      expect(status.activeSession!.state, ExecutionSessionState.running);
      expect(status.activeSession!.taskId, 'task-1');

      final entry = await harness.repository.findTimeEntry(result.sessionId!);
      expect(entry, isNotNull);
      expect(entry!.endedAtUtc, isNull);
      final link = await harness.repository.findSessionLink(result.sessionId!);
      expect(link, isNotNull);
      expect(link!.source, ExecutionActivitySource.realtime);
    });

    test('重复点击同一操作只创建一段会话', () async {
      final command = await harness.startCommand(operationId: 'op-start');
      final first = await harness.service.start(command);
      final second = await harness.service.start(command);
      expect(first.status, ExecutionResultStatus.applied);
      expect(second.status, ExecutionResultStatus.alreadyApplied);
      expect(second.sessionId, first.sessionId);

      final open = await harness.repository.openTimeEntries();
      expect(open, hasLength(1));
    });

    test('同一实例已有会话时返回其身份而不是新建', () async {
      await harness.seedOccurrence();
      final first = await start(
        operationId: 'op-start',
        occurrenceId: 'occurrence-1',
        occurrenceRevision: 1,
      );
      final second = await start(
        operationId: 'op-start-2',
        occurrenceId: 'occurrence-1',
        occurrenceRevision: 1,
      );
      expect(second.status, ExecutionResultStatus.alreadyApplied);
      expect(second.sessionId, first.sessionId);
    });

    test('另一个实例占用槽位时返回 activeSessionConflict', () async {
      await harness.taskRepository.save(
        PlannerTask(
          id: 'task-2',
          areaId: 'area-1',
          title: '另一项任务',
          priority: TaskPriority.medium,
          estimatedMinutes: 30,
          remainingMinutes: 30,
          energyLevel: TaskEnergyLevel.medium,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 25,
          maxChunkMinutes: 90,
          status: TaskStatus.open,
          createdAtUtc: harness.clock.nowUtc(),
          updatedAtUtc: harness.clock.nowUtc(),
        ),
      );
      await start(operationId: 'op-start');
      final current = await harness.status();
      final conflict = await harness.service.start(
        StartExecutionCommand(
          operationId: 'op-start-2',
          dataEpoch: current.dataEpoch,
          taskId: 'task-2',
          mode: ExecutionMode.planned,
          taskInputHash: await harness.taskInputHash('task-2'),
          runtimeRevision: current.runtimeRevision,
        ),
      );
      expect(conflict.status, ExecutionResultStatus.activeSessionConflict);
      expect(conflict.parameters['activeTaskId'], 'task-1');
    });

    test('同一操作ID携带不同请求被拒绝', () async {
      await start(operationId: 'op-start', targetDurationMicros: 300000000);
      final current = await harness.status();
      final reused = await harness.service.start(
        await harness.startCommand(
          operationId: 'op-start',
          targetDurationMicros: 360000000,
        ),
      );
      expect(reused.status, ExecutionResultStatus.invalid);
      expect(reused.reasonCode, ExecutionReasonCode.operationIdReused);
      // 槽位仍只有原来那一段。
      expect((await harness.repository.openTimeEntries()), hasLength(1));
      expect(current.runtimeRevision, 2);
    });

    test('计划模式撞上保护时间时拒绝并给出下个合法时刻', () async {
      final blocked = await ExecutionTestHarness.create(
        availability: const BlockedAvailability(),
      );
      addTearDown(blocked.close);
      final result = await blocked.service.start(
        await blocked.startCommand(operationId: 'op-start'),
      );
      expect(result.status, ExecutionResultStatus.blockedByHardBoundary);
      expect(result.parameters['blockerKind'], 'protected');
      expect(result.parameters['nextAvailableUtc'], isNotNull);
      expect(await blocked.service.activeSession(), isNull);
    });

    test('actualOnly 不受保护时间阻挡，但不创建计划占用', () async {
      final blocked = await ExecutionTestHarness.create(
        availability: const BlockedAvailability(),
      );
      addTearDown(blocked.close);
      final result = await blocked.service.start(
        await blocked.startCommand(
          operationId: 'op-start',
          mode: ExecutionMode.actualOnly,
        ),
      );
      expect(result.status, ExecutionResultStatus.applied);
      final link = await blocked.repository.findSessionLink(result.sessionId!);
      expect(link!.mode, ExecutionMode.actualOnly);
    });

    test('磁盘/事务失败返回 storageFailed，不显示假开始', () async {
      final command = await harness.startCommand(operationId: 'op-start');
      await harness.close();
      final result = await harness.service.start(command);
      expect(result.status, ExecutionResultStatus.storageFailed);
      // tearDown 会再次 close；drift 的 close 是幂等的。
    });

    test('运行会话阻塞更新安装，结束后解除', () async {
      final safety = InMemoryUpdateSafetyCoordinator();
      addTearDown(safety.dispose);
      final guarded = await ExecutionTestHarness.create(updateSafety: safety);
      addTearDown(guarded.close);
      final result = await guarded.service.start(
        await guarded.startCommand(operationId: 'op-start'),
      );
      expect(result.status, ExecutionResultStatus.applied);
      expect(safety.status.blockers, contains(UpdateBlocker.executionSession));

      await guarded.service.finish(await guarded.finishCommand('op-finish'));
      expect(
        safety.status.blockers,
        isNot(contains(UpdateBlocker.executionSession)),
      );
    });

    test('两个服务实例同时发起开始只允许一段实时会话', () async {
      final second = harness.restartService();
      final firstCommand = await harness.startCommand(operationId: 'op-a');
      final secondCommand = await harness.startCommand(operationId: 'op-b');
      final results = await Future.wait([
        harness.service.start(firstCommand),
        second.start(secondCommand),
      ]);
      expect(
        results.where(
          (result) => result.status == ExecutionResultStatus.applied,
        ),
        hasLength(1),
      );
      expect(await harness.repository.openTimeEntries(), hasLength(1));
      expect(await harness.service.activeSession(), isNotNull);
    });

    test('任务已结束时开始被拒绝', () async {
      final task = await harness.taskRepository.getById('task-1');
      await harness.taskRepository.save(
        task!.copyWith(status: TaskStatus.completed),
      );
      final result = await start(operationId: 'op-start');
      expect(result.status, ExecutionResultStatus.invalid);
      expect(result.reasonCode, ExecutionReasonCode.taskClosed);
      expect(await harness.repository.openTimeEntries(), isEmpty);
    });

    test('截止已过后计划模式拒绝，actualOnly 仍可记录实际', () async {
      final task = await harness.taskRepository.getById('task-1');
      await harness.taskRepository.save(
        task!.copyWith(
          dueAtUtc: harness.clock.nowUtc().subtract(const Duration(minutes: 1)),
        ),
      );
      final gate = ScheduleExecutionAvailability(
        source: _NeverSource(),
        tasks: harness.taskRepository,
        clock: harness.clock,
      );
      final service = DriftExecutionService(
        repository: harness.repository,
        tasks: harness.taskRepository,
        clock: harness.clock,
        monotonicClock: CallbackMonotonicClock(() => harness.clock.monotonic),
        idGenerator: harness.ids,
        availability: gate,
      );
      final currentTask = (await harness.taskRepository.getById('task-1'))!;
      final status = await service.status();
      final taskHash = executionTaskInputHash(currentTask);

      final planned = await service.start(
        StartExecutionCommand(
          operationId: 'op-plan',
          dataEpoch: status.dataEpoch,
          taskId: 'task-1',
          mode: ExecutionMode.planned,
          taskInputHash: taskHash,
          runtimeRevision: status.runtimeRevision,
        ),
      );
      expect(planned.status, ExecutionResultStatus.blockedByHardBoundary);
      expect(planned.parameters['blockerKind'], 'deadlineElapsed');

      final actual = await service.start(
        StartExecutionCommand(
          operationId: 'op-actual',
          dataEpoch: status.dataEpoch,
          taskId: 'task-1',
          mode: ExecutionMode.actualOnly,
          taskInputHash: taskHash,
          runtimeRevision: status.runtimeRevision,
        ),
      );
      expect(actual.status, ExecutionResultStatus.applied);
    });

    test('不可拆分任务先做5分钟只记录真实投入，不改变拆分模式', () async {
      final task = await harness.taskRepository.getById('task-1');
      await harness.taskRepository.save(
        task!.copyWith(splitMode: TaskSplitMode.continuous),
      );
      await start(operationId: 'op-start', targetDurationMicros: 300000000);
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.finish(await harness.finishCommand('op-finish'));
      final after = await harness.taskRepository.getById('task-1');
      expect(after!.remainingMinutes, 40);
      expect(after.splitMode, TaskSplitMode.continuous);
    });

    test('超额投入使剩余归零但不移动锁定计划块', () async {
      final task = await harness.taskRepository.getById('task-1');
      await harness.taskRepository.save(task!.copyWith(remainingMinutes: 10));
      await harness.database.customInsert(
        "INSERT INTO plan_versions "
        '(id, created_at_utc, input_hash, algorithm_version, status, summary_json) '
        "VALUES ('plan-1', ?, 'hash', '20', 'confirmed', '{}')",
        variables: [
          Variable.withInt(harness.clock.nowUtc().microsecondsSinceEpoch),
        ],
      );
      final blockStart = harness.clock.nowUtc().add(const Duration(hours: 2));
      await harness.database.customInsert(
        'INSERT INTO schedule_blocks '
        '(id, plan_version_id, task_id, start_at_utc, end_at_utc, locked, '
        'explanation_code, created_at_utc, updated_at_utc) '
        'VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)',
        variables: [
          Variable.withString('locked-1'),
          Variable.withString('plan-1'),
          Variable.withString('task-1'),
          Variable.withInt(blockStart.microsecondsSinceEpoch),
          Variable.withInt(
            blockStart.add(const Duration(minutes: 45)).microsecondsSinceEpoch,
          ),
          Variable.withString('locked'),
          Variable.withInt(blockStart.microsecondsSinceEpoch),
          Variable.withInt(blockStart.microsecondsSinceEpoch),
        ],
      );
      await start(operationId: 'op-start', targetDurationMicros: 600000000);
      harness.clock.advance(const Duration(minutes: 20));
      await harness.service.finish(await harness.finishCommand('op-finish'));
      expect(await harness.taskRemainingMinutes('task-1'), 0);
      final block = await harness.database
          .customSelect(
            "SELECT locked, start_at_utc, end_at_utc FROM schedule_blocks "
            "WHERE id = 'locked-1'",
          )
          .getSingle();
      expect(block.read<int>('locked'), 1);
      expect(
        block.read<int>('start_at_utc'),
        blockStart.microsecondsSinceEpoch,
      );
    });

    test('暂停写入失败时保持运行状态，不假装已暂停', () async {
      await start(operationId: 'op-start');
      harness.clock.advance(const Duration(minutes: 1));
      await harness.database.customStatement(
        "CREATE TRIGGER fail_pause_events BEFORE INSERT ON execution_events "
        "BEGIN SELECT RAISE(ABORT, 'pause boom'); END",
      );
      final result = await harness.service.pause(
        await harness.pauseCommand('op-pause'),
      );
      expect(result.status, ExecutionResultStatus.storageFailed);
      final active = await harness.service.activeSession();
      expect(active, isNotNull);
      expect(active!.state, ExecutionSessionState.running);
      expect(await harness.repository.openTimeEntries(), hasLength(1));
    });

    test('事件写入失败时开始事务整体回滚，不留孤立会话', () async {
      await harness.database.customStatement(
        "CREATE TRIGGER fail_execution_events BEFORE INSERT ON execution_events "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END",
      );
      final result = await start(operationId: 'op-start');
      expect(result.status, ExecutionResultStatus.storageFailed);
      expect(await harness.repository.openTimeEntries(), isEmpty);
      final runtime = await harness.repository.runtimeState();
      expect(runtime!.activeSessionId, isNull);
    });

    test('事务提交后界面刷新回调失败，不把已保存改写成失败', () async {
      final flaky = await ExecutionTestHarness.create(
        onChanged: () => throw StateError('ui refresh failed'),
      );
      addTearDown(flaky.close);
      final result = await flaky.service.start(
        await flaky.startCommand(operationId: 'op-start'),
      );
      expect(result.status, ExecutionResultStatus.applied);
      expect(await flaky.repository.openTimeEntries(), hasLength(1));
      expect(await flaky.service.activeSession(), isNotNull);
    });

    test('损坏的会话元数据被隔离，不让今日页崩溃', () async {
      await harness.repository.insertTimeEntry(
        id: 'broken-session',
        taskId: 'task-1',
        startedAtUtc: harness.clock.nowUtc(),
        phase: ExecutionSessionState.running,
        activeMicros: 0,
        lastReliableAtUtc: harness.clock.nowUtc(),
        note: '',
      );
      await harness.database.customUpdate(
        'UPDATE time_entries SET source = ? WHERE id = ?',
        variables: [
          Variable.withString('{"phase":"weird"}'),
          Variable.withString('broken-session'),
        ],
      );
      final runtime = await harness.repository.ensureRuntimeState();
      await harness.repository.writeRuntimeState(
        runtime.copyWith(
          activeSessionId: 'broken-session',
          revision: runtime.revision + 1,
          updatedAtUtc: harness.clock.nowUtc(),
        ),
      );

      final status = await harness.service.status();
      expect(status.activeSession, isNull);
    });
  });

  group('EXE-02/03/05/69 实际投入与剩余', () {
    test('45分钟任务先做5分钟：点击不扣，5分钟后剩余40', () async {
      await start(targetDurationMicros: 5 * 60 * 1000000);
      expect(await harness.taskRemainingMinutes('task-1'), 45);
      harness.clock.advance(const Duration(minutes: 5));
      final paused = await harness.service.pause(
        await harness.pauseCommand('op-pause'),
      );
      expect(paused.status, ExecutionResultStatus.applied);
      expect(await harness.taskRemainingMinutes('task-1'), 40);
    });

    test('做2分钟后结束：只记2分钟，剩余43，任务仍未完成', () async {
      await start();
      harness.clock.advance(const Duration(minutes: 2));
      final result = await harness.service.finish(
        await harness.finishCommand('op-finish'),
      );
      expect(result.status, ExecutionResultStatus.applied);
      expect(await harness.taskRemainingMinutes('task-1'), 43);
      final task = await harness.taskRepository.getById('task-1');
      expect(task!.status, TaskStatus.open);
      final entry = await harness.repository.findTimeEntry(result.sessionId!);
      expect(entry!.endedAtUtc, isNotNull);
      expect(
        (await harness.repository.segmentsForSession(result.sessionId!))
            .fold<int>(0, (sum, segment) => sum + segment.durationMicros),
        2 * 60 * 1000000,
      );
    });

    test('两次各30秒累计1分钟，不因单条取整丢失', () async {
      await start(operationId: 'op-1');
      harness.clock.advance(const Duration(seconds: 30));
      await harness.service.finish(await harness.finishCommand('op-1-finish'));
      await start(operationId: 'op-2');
      harness.clock.advance(const Duration(seconds: 30));
      await harness.service.finish(await harness.finishCommand('op-2-finish'));
      expect(await harness.taskRemainingMinutes('task-1'), 44);
    });

    test('暂停10分钟不计入有效投入', () async {
      await start();
      harness.clock.advance(const Duration(minutes: 1));
      await harness.service.pause(await harness.pauseCommand('op-pause'));
      harness.clock.advance(const Duration(minutes: 10));
      await harness.service.resume(await harness.resumeCommand('op-resume'));
      harness.clock.advance(const Duration(minutes: 1));
      await harness.service.finish(await harness.finishCommand('op-finish'));
      expect(await harness.taskRemainingMinutes('task-1'), 43);
    });

    test('开始后立即结束且零投入：不计启动、不扣进度', () async {
      final started = await start();
      final finished = await harness.service.finish(
        await harness.finishCommand('op-finish'),
      );
      expect(finished.status, ExecutionResultStatus.applied);
      expect(await harness.taskRemainingMinutes('task-1'), 45);
      final link = await harness.repository.findSessionLink(started.sessionId!);
      expect(link, isNotNull);
      // 零投入不产生活动段。
      expect(
        await harness.repository.segmentsForSession(started.sessionId!),
        isEmpty,
      );
    });
  });

  group('EXE-18/22 执行实例归属与人工检查点', () {
    test('一段计时只归属所选实例，启动证据写入该实例', () async {
      await harness.seedOccurrence();
      final result = await start(
        operationId: 'op-start',
        occurrenceId: 'occurrence-1',
        occurrenceRevision: 1,
      );
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.finish(await harness.finishCommand('op-finish'));

      final occurrence = await harness.repository.findOccurrence(
        'occurrence-1',
      );
      expect(occurrence!.remainingAllocationMicros, 40 * 60 * 1000000);
      expect(occurrence.lifecycleState, ExecutionLifecycleState.started);
      expect(occurrence.firstStartEvidenceId, isNotNull);
      expect(await harness.taskRemainingMinutes('task-1'), 40);
      final link = await harness.repository.findSessionLink(result.sessionId!);
      expect(link!.occurrenceId, 'occurrence-1');
    });

    test('人工修正剩余后再做5分钟，从新检查点扣减', () async {
      // 先做 1 分钟，建立初始检查点（剩余 44）。
      await start(operationId: 'op-first');
      harness.clock.advance(const Duration(minutes: 1));
      await harness.service.finish(
        await harness.finishCommand('op-first-finish'),
      );
      expect(await harness.taskRemainingMinutes('task-1'), 44);

      // 模拟用户在任务详情里把剩余从 44 改成 30（外部写入）。
      final task = await harness.taskRepository.getById('task-1');
      await harness.taskRepository.save(task!.copyWith(remainingMinutes: 30));

      await start(operationId: 'op-second');
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.finish(
        await harness.finishCommand('op-second-finish'),
      );

      expect(await harness.taskRemainingMinutes('task-1'), 25);
      final anchors = await harness.database
          .customSelect(
            'SELECT revision, anchor_remaining_micros FROM execution_progress_anchors '
            'ORDER BY revision',
          )
          .get();
      expect(anchors.length, greaterThanOrEqualTo(2));
    });

    test('剩余30秒时调度仍需1分钟', () async {
      await harness.recordManual(
        operationId: 'op-manual',
        duration: const Duration(minutes: 44, seconds: 30),
        startUtc: harness.clock.nowUtc().subtract(
          const Duration(minutes: 44, seconds: 30),
        ),
        includedInAnchor: false,
      );
      expect(await harness.taskRemainingMinutes('task-1'), 1);
    });
  });

  group('EXE-21/48 崩溃与未知区间', () {
    test('启动恢复标记待确认，未知停机时间不入账', () async {
      await start();
      harness.clock.advance(const Duration(minutes: 1));
      final recovered = await harness.service.recoverOpenSession();
      expect(recovered, isNotNull);
      expect(recovered!.state, ExecutionSessionState.recoveryPending);

      harness.clock.advance(const Duration(minutes: 10));
      await harness.service.resume(await harness.resumeCommand('op-resume'));
      harness.clock.advance(const Duration(minutes: 1));
      await harness.service.finish(await harness.finishCommand('op-finish'));
      // 崩溃前没有 15 秒心跳，最后可靠检查点仍是开始时刻；未知的 1 分钟不入账。
      // 恢复后明确继续的 1 分钟正常入账。
      expect(await harness.taskRemainingMinutes('task-1'), 44);
    });

    test('首次启用旧库不接管旧未结束会话，也不制造历史实例', () async {
      await harness.repository.insertTimeEntry(
        id: 'legacy-open',
        taskId: 'task-1',
        startedAtUtc: harness.clock.nowUtc().subtract(const Duration(hours: 1)),
        phase: ExecutionSessionState.running,
        activeMicros: 0,
        lastReliableAtUtc: harness.clock.nowUtc().subtract(
          const Duration(hours: 1),
        ),
        note: '旧版本记录',
      );
      final recovered = await harness.service.recoverOpenSession();
      expect(recovered, isNull);
      expect(await harness.repository.openTimeEntries(), hasLength(1));
      final dayStart = harness.clock.nowUtc().subtract(const Duration(days: 1));
      expect(
        await harness.repository.occurrencesInWindow(
          startUtc: dayStart,
          endUtc: harness.clock.nowUtc().add(const Duration(days: 2)),
        ),
        isEmpty,
      );
    });
  });
}
