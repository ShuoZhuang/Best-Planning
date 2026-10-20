import 'package:drift/native.dart';
import 'package:personal_planner/application/execution/execution_availability.dart';
import 'package:personal_planner/application/execution/execution_commands.dart';
import 'package:personal_planner/application/execution/execution_input_hashes.dart';
import 'package:personal_planner/application/execution/execution_notification_settings.dart';
import 'package:personal_planner/application/execution/execution_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart'
    show AppDatabase;
import 'package:personal_planner/data/database/daos/task_dao.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/domain/execution/execution_result.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

final class TestClock implements Clock {
  TestClock(this._now);

  DateTime _now;
  Duration _monotonic = Duration.zero;

  @override
  DateTime nowUtc() => _now;

  Duration get monotonic => _monotonic;

  void advance(Duration duration) {
    _now = _now.add(duration);
    _monotonic += duration;
  }
}

final class SequentialIds implements IdGenerator {
  int _next = 0;

  @override
  String next() => 'id-${++_next}';
}

final class AllowAllAvailability implements ExecutionAvailabilityPort {
  const AllowAllAvailability({this.available = const Duration(hours: 8)});

  final Duration available;

  @override
  Future<ExecutionAvailability> at({
    required DateTime nowUtc,
    required String taskId,
    String? occurrenceId,
  }) async => ExecutionAvailability.allowed(
    availableMicros: available.inMicroseconds,
    boundaryUtc: nowUtc.add(available),
    hardBoundaryInputHash: 'test-hard-boundary',
  );
}

final class BoundaryAvailability implements ExecutionAvailabilityPort {
  const BoundaryAvailability(this.boundaryUtc);

  final DateTime boundaryUtc;

  @override
  Future<ExecutionAvailability> at({
    required DateTime nowUtc,
    required String taskId,
    String? occurrenceId,
  }) async {
    if (nowUtc.isBefore(boundaryUtc)) {
      return ExecutionAvailability.allowed(
        availableMicros: boundaryUtc.difference(nowUtc).inMicroseconds,
        boundaryUtc: boundaryUtc,
        hardBoundaryInputHash: 'boundary-hash',
      );
    }
    return ExecutionAvailability.blocked(
      nextAvailableUtc: nowUtc.add(const Duration(hours: 1)),
      blockerKind: 'protected',
      hardBoundaryInputHash: 'boundary-hash',
    );
  }
}

final class LimitedAvailability implements ExecutionAvailabilityPort {
  const LimitedAvailability(this.available);

  final Duration available;

  @override
  Future<ExecutionAvailability> at({
    required DateTime nowUtc,
    required String taskId,
    String? occurrenceId,
  }) async => ExecutionAvailability.allowed(
    availableMicros: available.inMicroseconds,
    boundaryUtc: nowUtc.add(available),
    hardBoundaryInputHash: 'limited-hard-boundary',
  );
}

final class BlockedAvailability implements ExecutionAvailabilityPort {
  const BlockedAvailability();

  @override
  Future<ExecutionAvailability> at({
    required DateTime nowUtc,
    required String taskId,
    String? occurrenceId,
  }) async => ExecutionAvailability.blocked(
    nextAvailableUtc: nowUtc.add(const Duration(hours: 1)),
    blockerKind: 'protected',
    hardBoundaryInputHash: 'blocked-boundary',
  );
}

final class AlwaysEnabledNotifications
    implements ExecutionNotificationSettingsPort {
  const AlwaysEnabledNotifications({
    this.quiet = false,
    this.enabled = true,
    this.taskStartEnabled = true,
  });

  final bool quiet;
  final bool enabled;
  final bool taskStartEnabled;

  @override
  Future<ExecutionNotificationSettingsSnapshot> snapshot({
    required DateTime targetAtUtc,
  }) async => ExecutionNotificationSettingsSnapshot(
    enabled: enabled,
    taskStartEnabled: taskStartEnabled,
    suppressedByQuietHours: quiet,
    settingsHash: 'settings-hash',
  );
}

final class ExecutionTestHarness {
  ExecutionTestHarness._({
    required this.database,
    required this.clock,
    required this.ids,
    required this.repository,
    required this.taskRepository,
    required this.service,
  });

  static Future<ExecutionTestHarness> create({
    DateTime? now,
    ExecutionAvailabilityPort availability = const AllowAllAvailability(),
    ExecutionNotificationSettingsPort notifications =
        const AlwaysEnabledNotifications(),
    UpdateSafetyCoordinator? updateSafety,
    void Function()? onChanged,
    bool seedTask = true,
  }) async {
    final clock = TestClock(now ?? DateTime.utc(2026, 10, 19, 5));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final ids = SequentialIds();
    final repository = DriftExecutionRepository(
      database,
      clock: clock,
      idGenerator: ids,
    );
    final taskRepository = DriftTaskRepository(TaskDao(database));
    final service = DriftExecutionService(
      repository: repository,
      tasks: taskRepository,
      clock: clock,
      monotonicClock: CallbackMonotonicClock(() => clock.monotonic),
      idGenerator: ids,
      availability: availability,
      notificationSettings: notifications,
      updateSafety: updateSafety,
      onChanged: onChanged,
    );
    await database.customInsert(
      "INSERT INTO areas (id, name, color, sort_order) "
      "VALUES ('area-1', '学业', 0, 0)",
    );
    if (seedTask) {
      await taskRepository.save(
        PlannerTask(
          id: 'task-1',
          areaId: 'area-1',
          title: '蓝桥杯竞赛课',
          priority: TaskPriority.medium,
          estimatedMinutes: 45,
          remainingMinutes: 45,
          energyLevel: TaskEnergyLevel.medium,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 25,
          maxChunkMinutes: 90,
          status: TaskStatus.open,
          createdAtUtc: clock.nowUtc(),
          updatedAtUtc: clock.nowUtc(),
        ),
      );
    }
    return ExecutionTestHarness._(
      database: database,
      clock: clock,
      ids: ids,
      repository: repository,
      taskRepository: taskRepository,
      service: service,
    );
  }

  final AppDatabase database;
  final TestClock clock;
  final SequentialIds ids;
  final DriftExecutionRepository repository;
  final TaskRepository taskRepository;
  final DriftExecutionService service;

  Future<void> close() => database.close();

  /// 同一份持久事实上的新服务实例，模拟进程重启。
  DriftExecutionService restartService() => DriftExecutionService(
    repository: repository,
    tasks: taskRepository,
    clock: clock,
    monotonicClock: CallbackMonotonicClock(() => clock.monotonic),
    idGenerator: ids,
    availability: const AllowAllAvailability(),
    notificationSettings: const AlwaysEnabledNotifications(),
  );

  Future<ExecutionStatus> status() => service.status();

  Future<String> taskInputHash(String taskId) async {
    final task = await taskRepository.getById(taskId);
    if (task == null) throw StateError('missing task');
    return executionTaskInputHash(task);
  }

  Future<StartExecutionCommand> startCommand({
    required String operationId,
    String taskId = 'task-1',
    String? occurrenceId,
    int? occurrenceRevision,
    ExecutionMode mode = ExecutionMode.planned,
    int? targetDurationMicros,
  }) async {
    final current = await status();
    return StartExecutionCommand(
      operationId: operationId,
      dataEpoch: current.dataEpoch,
      taskId: taskId,
      occurrenceId: occurrenceId,
      occurrenceRevision: occurrenceRevision,
      mode: mode,
      targetDurationMicros: targetDurationMicros,
      taskInputHash: await taskInputHash(taskId),
      runtimeRevision: current.runtimeRevision,
    );
  }

  Future<PauseExecutionCommand> pauseCommand(
    String operationId, {
    String? systemReason,
  }) async {
    final active = await service.activeSession();
    if (active == null) throw StateError('no active session');
    final runtime = await repository.runtimeState();
    return PauseExecutionCommand(
      operationId: operationId,
      dataEpoch: runtime!.dataEpoch,
      sessionId: active.sessionId,
      sessionRevision: active.revision,
      runtimeRevision: runtime.revision,
      systemReason: systemReason,
    );
  }

  Future<ResumeExecutionCommand> resumeCommand(String operationId) async {
    final active = await service.activeSession();
    if (active == null) throw StateError('no active session');
    final runtime = await repository.runtimeState();
    return ResumeExecutionCommand(
      operationId: operationId,
      dataEpoch: runtime!.dataEpoch,
      sessionId: active.sessionId,
      mode: active.mode,
      sessionRevision: active.revision,
      runtimeRevision: runtime.revision,
      hardBoundaryInputHash: 'test-hard-boundary',
    );
  }

  Future<FinishExecutionCommand> finishCommand(
    String operationId, {
    bool abandon = false,
    ExecutionBarrierReason? barrierReason,
    String note = '',
  }) async {
    final active = await service.activeSession();
    if (active == null) throw StateError('no active session');
    final runtime = await repository.runtimeState();
    return FinishExecutionCommand(
      operationId: operationId,
      dataEpoch: runtime!.dataEpoch,
      sessionId: active.sessionId,
      sessionRevision: active.revision,
      runtimeRevision: runtime.revision,
      abandonOccurrenceRemaining: abandon,
      barrierReason: barrierReason,
      note: note,
    );
  }

  Future<int> taskRemainingMinutes(String taskId) async {
    final task = await taskRepository.getById(taskId);
    if (task == null) throw StateError('missing task');
    return task.remainingMinutes;
  }

  Future<ExecutionOccurrence> seedOccurrence({
    String id = 'occurrence-1',
    String taskId = 'task-1',
    int allocatedMinutes = 45,
    int remainingMinutes = 45,
    DateTime? baselineStartUtc,
  }) async {
    final start = baselineStartUtc ?? clock.nowUtc();
    final occurrence = ExecutionOccurrence(
      id: id,
      taskId: taskId,
      originPlanVersionId: null,
      originBlockId: null,
      baselineStartUtc: start,
      baselineEndUtc: start.add(Duration(minutes: remainingMinutes)),
      baselineTimeZoneId: 'Asia/Shanghai',
      baselineLocalDate: '2026-10-19',
      baselinePlannedDurationMicros:
          allocatedMinutes * Duration.microsecondsPerMinute,
      currentPlanVersionId: 'plan-1',
      allocatedMicros: allocatedMinutes * Duration.microsecondsPerMinute,
      remainingAllocationMicros:
          remainingMinutes * Duration.microsecondsPerMinute,
      firstStartEvidenceId: null,
      withdrawalReason: null,
      withdrawnAtUtc: null,
      lifecycleState: ExecutionLifecycleState.planned,
      privacyState: ExecutionPrivacyState.linked,
      createdAtUtc: start,
      revision: 1,
    );
    await repository.insertOccurrence(occurrence);
    return occurrence;
  }

  Future<ExecutionCommandResult> recordManual({
    required String operationId,
    required Duration duration,
    DateTime? startUtc,
    String taskId = 'task-1',
    String? occurrenceId,
    int? occurrenceRevision,
    bool? includedInAnchor,
    ExecutionOverlapResolution? overlapResolution,
    String note = '',
    int progressAnchorRevision = 0,
  }) async {
    final command = await recordManualCommand(
      operationId: operationId,
      duration: duration,
      startUtc: startUtc,
      taskId: taskId,
      occurrenceId: occurrenceId,
      occurrenceRevision: occurrenceRevision,
      includedInAnchor: includedInAnchor,
      overlapResolution: overlapResolution,
      note: note,
      progressAnchorRevision: progressAnchorRevision,
    );
    return service.recordManual(command);
  }

  Future<RecordManualExecutionCommand> recordManualCommand({
    required String operationId,
    required Duration duration,
    DateTime? startUtc,
    String taskId = 'task-1',
    String? occurrenceId,
    int? occurrenceRevision,
    bool? includedInAnchor,
    ExecutionOverlapResolution? overlapResolution,
    String note = '',
    int progressAnchorRevision = 0,
  }) async {
    final current = await status();
    final task = await taskRepository.getById(taskId);
    if (task == null) throw StateError('missing task');
    final start = startUtc ?? clock.nowUtc().subtract(duration);
    return RecordManualExecutionCommand(
      operationId: operationId,
      dataEpoch: current.dataEpoch,
      taskId: taskId,
      occurrenceId: occurrenceId,
      occurrenceRevision: occurrenceRevision,
      segmentStartUtc: start,
      segmentEndUtc: start.add(duration),
      note: note,
      includedInAnchor: includedInAnchor,
      overlapResolution: overlapResolution,
      taskInputHash: executionTaskInputHash(task),
      progressAnchorRevision: progressAnchorRevision,
    );
  }
}
