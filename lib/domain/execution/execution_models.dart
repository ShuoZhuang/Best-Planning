import 'dart:collection';

/// 1.11.0 执行事实的领域值对象。
///
/// 设计：`docs/superpowers/specs/2026-10-18-v1.11.0-execution-start-and-recovery-design.md`
/// （下称"规范"）§5、§10、§19。本文件只放**不可变事实与它们的自校验**，不依赖 Flutter、
/// Drift 或任何仓储：同一份规则必须能被单元测试、页面和数据库层共同引用，而不是各写一遍。

/// 一次执行承诺的生命周期（规范 §19.6）。
enum ExecutionLifecycleState { planned, started, finished, withdrawn }

/// 执行实例的隐私状态；与生命周期正交（规范 §5.1）。
enum ExecutionPrivacyState { linked, anonymized }

/// 有效活动的事实来源（规范 §19.1）。
///
/// `legacyUnlinked` 只用于旧计时记录被显式解除关联后的历史事实，它**不进入启动指标**。
enum ExecutionActivitySource {
  realtime,
  manual,
  recoveryConfirmed,
  legacyUnlinked,
}

/// `planned` 记录合法计划占用；`actualOnly` 只记录真实投入（规范 §19.1、§7.2）。
enum ExecutionMode { planned, actualOnly }

/// 实时会话状态机（规范 §19.6）。
enum ExecutionSessionState { running, paused, recoveryPending, finished }

/// 提醒修订状态机（规范 §19.6、§21.1）。
enum ExecutionReminderState {
  pending,
  claimed,
  scheduled,
  suppressed,
  expired,
  unknown,
  cancelled,
  handled,
}

/// 恢复草案状态只存在于当前进程代次（规范 §19.6、§19.3）。
enum ExecutionDraftState { open, applied, cancelled, expired }

/// 领域事件类型。结果账本在 `execution_operations`，事件不承担幂等职责（规范 §19.2）。
enum ExecutionEventType {
  planned,
  started,
  paused,
  resumed,
  finished,
  manualRecorded,
  recordCorrected,
  recordInvalidated,
  withdrawn,
  dayHoldSet,
  reminderScheduled,
  reminderCancelled,
  recoveryRequested,
  recoveryApplied,
  progressAnchored,
  sessionLinked,
  taskAnonymized,
}

/// 活动段入账目标（规范 §19.2、§10.3）。
enum ExecutionTargetKind { task, recurringCycle }

/// 可选的执行障碍原因（规范 §12.2）。默认不选，不做任何推断。
enum ExecutionBarrierReason {
  temporaryInterruption,
  taskTooHard,
  lowEnergy,
  forgot,
  other,
}

/// 补记与既有记录重叠时的处理方式（规范 §12.1）。
///
/// 单纯点击"仍然保存"不能制造双份有效投入；交叠微秒最多进入一个进度目标。
enum ExecutionOverlapResolution {
  /// 只保留新区间中未被占用的部分。
  shortenNew,

  /// 用新区间替换重叠的旧记录。
  replaceExisting,

  /// 明确分配重叠区间（第一轮界面未提供逐微秒分配，服务按未支持处理）。
  allocateExplicit,

  /// 两条叙述都保留，但重叠部分不计入进度。
  saveNonCrediting,
}

/// 备注长度上限：0–500 个 Unicode 码点（规范 §19.1）。
const int executionNoteMaxCodePoints = 500;

/// 校验备注；通过返回 `null`，否则返回稳定的错误码（不返回界面文案）。
///
/// 除换行与制表符外的控制字符一律拒绝：它们会破坏通知正文、日志和表格渲染。
String? executionNoteError(String note) {
  if (note.runes.length > executionNoteMaxCodePoints) {
    return 'noteTooLong';
  }
  for (final rune in note.runes) {
    final isAllowedWhitespace = rune == 0x09 || rune == 0x0A;
    if (!isAllowedWhitespace && (rune < 0x20 || rune == 0x7F)) {
      return 'noteControlCharacter';
    }
  }
  return null;
}

/// 本地日期键（`YYYY-MM-DD`）。日期不是时刻：时区换算之后才允许转成 UTC。
String executionLocalDateKey(DateTime localDate) {
  final year = localDate.year.toString().padLeft(4, '0');
  final month = localDate.month.toString().padLeft(2, '0');
  final day = localDate.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

void _requireUtc(DateTime value, String name) {
  if (!value.isUtc) {
    throw ArgumentError.value(value, name, 'Must be UTC.');
  }
}

void _requireNonNegative(int value, String name) {
  if (value < 0) {
    throw ArgumentError.value(value, name, 'Must not be negative.');
  }
}

/// §5.1 的执行实例：用户承诺执行的一次安排，身份独立于任务、会话与块。
final class ExecutionOccurrence {
  ExecutionOccurrence({
    required this.id,
    required this.taskId,
    required this.originPlanVersionId,
    required this.originBlockId,
    required this.baselineStartUtc,
    required this.baselineEndUtc,
    required this.baselineTimeZoneId,
    required this.baselineLocalDate,
    required this.baselinePlannedDurationMicros,
    required this.currentPlanVersionId,
    required this.allocatedMicros,
    required this.remainingAllocationMicros,
    required this.firstStartEvidenceId,
    required this.withdrawalReason,
    required this.withdrawnAtUtc,
    required this.lifecycleState,
    required this.privacyState,
    required this.createdAtUtc,
    required this.revision,
  }) {
    _requireUtc(baselineStartUtc, 'baselineStartUtc');
    _requireUtc(baselineEndUtc, 'baselineEndUtc');
    _requireUtc(createdAtUtc, 'createdAtUtc');
    if (!baselineEndUtc.isAfter(baselineStartUtc)) {
      throw ArgumentError('baselineEndUtc must be after baselineStartUtc.');
    }
    if (baselineTimeZoneId.trim().isEmpty) {
      throw ArgumentError.value(baselineTimeZoneId, 'baselineTimeZoneId');
    }
    if (baselineLocalDate.trim().isEmpty) {
      throw ArgumentError.value(baselineLocalDate, 'baselineLocalDate');
    }
    _requireNonNegative(
      baselinePlannedDurationMicros,
      'baselinePlannedDurationMicros',
    );
    _requireNonNegative(allocatedMicros, 'allocatedMicros');
    _requireNonNegative(remainingAllocationMicros, 'remainingAllocationMicros');
    if (remainingAllocationMicros > allocatedMicros) {
      throw ArgumentError(
        'remainingAllocationMicros cannot exceed allocatedMicros.',
      );
    }
    if (withdrawnAtUtc != null) {
      _requireUtc(withdrawnAtUtc!, 'withdrawnAtUtc');
    }
    if (lifecycleState == ExecutionLifecycleState.withdrawn &&
        withdrawnAtUtc == null) {
      throw ArgumentError('withdrawn occurrence requires withdrawnAtUtc.');
    }
    if (withdrawalReason != null) {
      final error = executionNoteError(withdrawalReason!);
      if (error != null) {
        throw ArgumentError.value(withdrawalReason, 'withdrawalReason', error);
      }
    }
    if (revision < 1) {
      throw ArgumentError.value(revision, 'revision', 'Must be at least 1.');
    }
  }

  final String id;
  final String? taskId;
  final String? originPlanVersionId;
  final String? originBlockId;
  final DateTime baselineStartUtc;
  final DateTime baselineEndUtc;
  final String baselineTimeZoneId;
  final String baselineLocalDate;
  final int baselinePlannedDurationMicros;
  final String? currentPlanVersionId;
  final int allocatedMicros;
  final int remainingAllocationMicros;
  final String? firstStartEvidenceId;
  final String? withdrawalReason;
  final DateTime? withdrawnAtUtc;
  final ExecutionLifecycleState lifecycleState;
  final ExecutionPrivacyState privacyState;
  final DateTime createdAtUtc;
  final int revision;

  bool get isWithdrawn => lifecycleState == ExecutionLifecycleState.withdrawn;

  bool get isFinished => lifecycleState == ExecutionLifecycleState.finished;

  bool get isTerminal => isWithdrawn || isFinished;

  bool get hasStarted => lifecycleState == ExecutionLifecycleState.started;

  /// 提前撤回只在"原开始之前且没有任何有效启动"时合法（规范 §5.2、§19.6）。
  bool canWithdrawBefore(DateTime instantUtc) {
    _requireUtc(instantUtc, 'instantUtc');
    return !hasStarted &&
        firstStartEvidenceId == null &&
        instantUtc.isBefore(baselineStartUtc);
  }

  ExecutionOccurrence copyWith({
    String? taskId,
    bool clearTaskId = false,
    String? originPlanVersionId,
    bool clearOriginPlanVersionId = false,
    String? originBlockId,
    bool clearOriginBlockId = false,
    DateTime? baselineStartUtc,
    DateTime? baselineEndUtc,
    String? baselineTimeZoneId,
    String? baselineLocalDate,
    int? baselinePlannedDurationMicros,
    String? currentPlanVersionId,
    bool clearCurrentPlanVersionId = false,
    int? allocatedMicros,
    int? remainingAllocationMicros,
    String? firstStartEvidenceId,
    bool clearFirstStartEvidenceId = false,
    String? withdrawalReason,
    DateTime? withdrawnAtUtc,
    ExecutionLifecycleState? lifecycleState,
    ExecutionPrivacyState? privacyState,
    DateTime? createdAtUtc,
    int? revision,
  }) => ExecutionOccurrence(
    id: id,
    taskId: clearTaskId ? null : (taskId ?? this.taskId),
    originPlanVersionId: clearOriginPlanVersionId
        ? null
        : (originPlanVersionId ?? this.originPlanVersionId),
    originBlockId: clearOriginBlockId
        ? null
        : (originBlockId ?? this.originBlockId),
    baselineStartUtc: baselineStartUtc ?? this.baselineStartUtc,
    baselineEndUtc: baselineEndUtc ?? this.baselineEndUtc,
    baselineTimeZoneId: baselineTimeZoneId ?? this.baselineTimeZoneId,
    baselineLocalDate: baselineLocalDate ?? this.baselineLocalDate,
    baselinePlannedDurationMicros:
        baselinePlannedDurationMicros ?? this.baselinePlannedDurationMicros,
    currentPlanVersionId: clearCurrentPlanVersionId
        ? null
        : (currentPlanVersionId ?? this.currentPlanVersionId),
    allocatedMicros: allocatedMicros ?? this.allocatedMicros,
    remainingAllocationMicros:
        remainingAllocationMicros ?? this.remainingAllocationMicros,
    firstStartEvidenceId: clearFirstStartEvidenceId
        ? null
        : (firstStartEvidenceId ?? this.firstStartEvidenceId),
    withdrawalReason: withdrawalReason ?? this.withdrawalReason,
    withdrawnAtUtc: withdrawnAtUtc ?? this.withdrawnAtUtc,
    lifecycleState: lifecycleState ?? this.lifecycleState,
    privacyState: privacyState ?? this.privacyState,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    revision: revision ?? this.revision,
  );
}

/// 一条领域事件。`operationId + subEventIndex` 由数据库唯一约束去重（规范 §19.2）。
final class ExecutionEvent {
  ExecutionEvent({
    required this.eventId,
    required this.dataEpoch,
    required this.operationId,
    required this.subEventIndex,
    required this.occurrenceId,
    required this.eventType,
    required this.occurredAtUtc,
    required this.recordedAtUtc,
    required this.source,
    required this.payload,
    required this.correctedEventId,
    required this.sequence,
    required this.revision,
  }) {
    _requireUtc(occurredAtUtc, 'occurredAtUtc');
    _requireUtc(recordedAtUtc, 'recordedAtUtc');
    if (subEventIndex < 0) {
      throw ArgumentError.value(subEventIndex, 'subEventIndex');
    }
    if (sequence < 1) {
      throw ArgumentError.value(sequence, 'sequence');
    }
    if (revision < 1) {
      throw ArgumentError.value(revision, 'revision');
    }
  }

  final String eventId;
  final String dataEpoch;
  final String operationId;
  final int subEventIndex;
  final String? occurrenceId;
  final ExecutionEventType eventType;
  final DateTime occurredAtUtc;
  final DateTime recordedAtUtc;
  final ExecutionActivitySource source;
  final Map<String, Object?> payload;
  final String? correctedEventId;
  final int sequence;
  final int revision;
}

/// 会话与执行实例的归属关系（规范 §19.2）。
final class ExecutionSessionLink {
  ExecutionSessionLink({
    required this.sessionId,
    required this.dataEpoch,
    required this.occurrenceId,
    required this.source,
    required this.mode,
    required this.firstAcceptedSequence,
    required this.revision,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) {
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
    if (revision < 1) {
      throw ArgumentError.value(revision, 'revision');
    }
  }

  final String sessionId;
  final String dataEpoch;
  final String? occurrenceId;
  final ExecutionActivitySource source;
  final ExecutionMode mode;
  final int? firstAcceptedSequence;
  final int revision;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

/// 半开区间 `[startUtc, endUtc)` 的一条有效活动段（规范 §19.1）。
final class ExecutionActivitySegment {
  ExecutionActivitySegment({
    required this.segmentId,
    required this.dataEpoch,
    required this.sessionId,
    required this.sequence,
    required this.startUtc,
    required this.endUtc,
    required this.source,
    required this.invalidatedReason,
    required this.createdAtUtc,
  }) {
    _requireUtc(startUtc, 'startUtc');
    _requireUtc(endUtc, 'endUtc');
    _requireUtc(createdAtUtc, 'createdAtUtc');
    if (!endUtc.isAfter(startUtc)) {
      throw ArgumentError('endUtc must be after startUtc.');
    }
    if (sequence < 1) {
      throw ArgumentError.value(sequence, 'sequence');
    }
  }

  final String segmentId;
  final String dataEpoch;
  final String sessionId;
  final int sequence;
  final DateTime startUtc;
  final DateTime endUtc;
  final ExecutionActivitySource source;
  final String? invalidatedReason;
  final DateTime createdAtUtc;

  int get durationMicros => endUtc.difference(startUtc).inMicroseconds;
}

/// 人工剩余时长的检查点（规范 §10.2）。
final class ExecutionProgressAnchor {
  ExecutionProgressAnchor({
    required this.taskId,
    required this.revision,
    required this.anchorRemainingMicros,
    required this.anchorSequence,
    required this.reason,
    required this.createdAtUtc,
    required this.isCurrent,
  }) {
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireNonNegative(anchorRemainingMicros, 'anchorRemainingMicros');
    _requireNonNegative(anchorSequence, 'anchorSequence');
    if (revision < 1) {
      throw ArgumentError.value(revision, 'revision');
    }
  }

  final String taskId;
  final int revision;
  final int anchorRemainingMicros;
  final int anchorSequence;
  final String reason;
  final DateTime createdAtUtc;
  final bool isCurrent;
}

/// 活动段向某个进度目标的精确分配（规范 §19.2）。交叠微秒最多入账一次。
final class ExecutionCreditAllocation {
  ExecutionCreditAllocation({
    required this.dataEpoch,
    required this.segmentId,
    required this.targetKind,
    required this.targetId,
    required this.allocationIndex,
    required this.recordRevision,
    required this.amountMicros,
    required this.firstAcceptedSequence,
    required this.createdAtUtc,
  }) {
    _requireUtc(createdAtUtc, 'createdAtUtc');
    if (amountMicros <= 0) {
      throw ArgumentError.value(amountMicros, 'amountMicros');
    }
    if (allocationIndex < 0) {
      throw ArgumentError.value(allocationIndex, 'allocationIndex');
    }
    if (recordRevision < 1) {
      throw ArgumentError.value(recordRevision, 'recordRevision');
    }
    if (firstAcceptedSequence < 1) {
      throw ArgumentError.value(firstAcceptedSequence, 'firstAcceptedSequence');
    }
  }

  final String dataEpoch;
  final String segmentId;
  final ExecutionTargetKind targetKind;
  final String targetId;
  final int allocationIndex;
  final int recordRevision;
  final int amountMicros;

  /// 首次入账序号。更正保留它，进度检查点据此判断"是否在锚点之后"。
  final int firstAcceptedSequence;
  final DateTime createdAtUtc;
}

/// 执行提醒意图；每个实例在库中最多一个当前修订（规范 §13、§21）。
final class ExecutionReminderIntent {
  ExecutionReminderIntent({
    required this.dataEpoch,
    required this.occurrenceId,
    required this.revision,
    required this.targetAtUtc,
    required this.notificationId,
    required this.state,
    required this.claimedAtUtc,
    required this.scheduledAtUtc,
    required this.dispatchResult,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) {
    _requireUtc(targetAtUtc, 'targetAtUtc');
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
    if (revision < 1) {
      throw ArgumentError.value(revision, 'revision');
    }
    if (claimedAtUtc != null) _requireUtc(claimedAtUtc!, 'claimedAtUtc');
    if (scheduledAtUtc != null) _requireUtc(scheduledAtUtc!, 'scheduledAtUtc');
  }

  final String dataEpoch;
  final String occurrenceId;
  final int revision;
  final DateTime targetAtUtc;
  final String notificationId;
  final ExecutionReminderState state;
  final DateTime? claimedAtUtc;
  final DateTime? scheduledAtUtc;
  final String? dispatchResult;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  bool get isActive => const {
    ExecutionReminderState.pending,
    ExecutionReminderState.claimed,
    ExecutionReminderState.scheduled,
    ExecutionReminderState.unknown,
  }.contains(state);
}

/// "今天不再安排该任务"的一次性限制（规范 §8、§19.2）。
final class ExecutionDayHold {
  ExecutionDayHold({
    required this.taskId,
    required this.localDate,
    required this.timeZoneId,
    required this.invalidAfterUtc,
    required this.sourceProposalId,
    required this.createdAtUtc,
  }) {
    _requireUtc(invalidAfterUtc, 'invalidAfterUtc');
    _requireUtc(createdAtUtc, 'createdAtUtc');
    if (localDate.trim().isEmpty) {
      throw ArgumentError.value(localDate, 'localDate');
    }
  }

  final String taskId;
  final String localDate;
  final String timeZoneId;
  final DateTime invalidAfterUtc;
  final String? sourceProposalId;
  final DateTime createdAtUtc;
}

/// 已提交命令的完整稳定结果（规范 §11、§19.2）。
final class ExecutionOperationRecord {
  const ExecutionOperationRecord({
    required this.dataEpoch,
    required this.operationId,
    required this.requestHash,
    required this.commandType,
    required this.subjectKind,
    required this.subjectId,
    required this.resultJson,
    required this.createdAtUtc,
  });

  final String dataEpoch;
  final String operationId;
  final String requestHash;
  final String commandType;
  final String subjectKind;
  final String? subjectId;
  final String resultJson;
  final DateTime createdAtUtc;
}

/// 关键事务之后的可重试附加操作（规范 §11、§19.2）。
final class ExecutionOutboxEntry {
  ExecutionOutboxEntry({
    required this.effectId,
    required this.dataEpoch,
    required this.sourceTransaction,
    required this.targetRevision,
    required this.effectType,
    required this.payload,
    required this.attempts,
    required this.createdAtUtc,
    required this.nextAttemptAtUtc,
    required this.processedAtUtc,
  }) {
    _requireUtc(createdAtUtc, 'createdAtUtc');
    _requireUtc(nextAttemptAtUtc, 'nextAttemptAtUtc');
    if (processedAtUtc != null) _requireUtc(processedAtUtc!, 'processedAtUtc');
    if (attempts < 0) throw ArgumentError.value(attempts, 'attempts');
  }

  final String effectId;
  final String dataEpoch;
  final String sourceTransaction;
  final int targetRevision;
  final String effectType;
  final Map<String, Object?> payload;
  final int attempts;
  final DateTime createdAtUtc;
  final DateTime nextAttemptAtUtc;
  final DateTime? processedAtUtc;
}

/// 单行运行时状态：功能启用时间、唯一会话槽位与数据代次（规范 §19.2）。
final class ExecutionRuntimeState {
  ExecutionRuntimeState({
    required this.id,
    required this.dataEpoch,
    required this.activeSessionId,
    required this.revision,
    required this.featureEnabledAtUtc,
    required this.updatedAtUtc,
  }) {
    if (id != 1) throw ArgumentError.value(id, 'id', 'Must be 1.');
    if (dataEpoch.trim().isEmpty) {
      throw ArgumentError.value(dataEpoch, 'dataEpoch');
    }
    if (revision < 1) throw ArgumentError.value(revision, 'revision');
    _requireUtc(featureEnabledAtUtc, 'featureEnabledAtUtc');
    _requireUtc(updatedAtUtc, 'updatedAtUtc');
  }

  final int id;
  final String dataEpoch;
  final String? activeSessionId;
  final int revision;
  final DateTime featureEnabledAtUtc;
  final DateTime updatedAtUtc;

  bool get hasActiveSession => activeSessionId != null;

  ExecutionRuntimeState copyWith({
    String? dataEpoch,
    String? activeSessionId,
    bool clearActiveSessionId = false,
    int? revision,
    DateTime? featureEnabledAtUtc,
    DateTime? updatedAtUtc,
  }) => ExecutionRuntimeState(
    id: id,
    dataEpoch: dataEpoch ?? this.dataEpoch,
    activeSessionId: clearActiveSessionId
        ? null
        : (activeSessionId ?? this.activeSessionId),
    revision: revision ?? this.revision,
    featureEnabledAtUtc: featureEnabledAtUtc ?? this.featureEnabledAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
  );
}

/// 当前实时会话的只读投影，供今日页执行条使用（规范 §7、§10）。
final class ExecutionSessionSnapshot {
  ExecutionSessionSnapshot({
    required this.sessionId,
    required this.occurrenceId,
    required this.taskId,
    required this.state,
    required this.source,
    required this.mode,
    required this.startedAtUtc,
    required this.activeMicros,
    required this.revision,
    required this.lastReliableAtUtc,
    this.runtimeRevision = 0,
  }) {
    _requireUtc(startedAtUtc, 'startedAtUtc');
    _requireUtc(lastReliableAtUtc, 'lastReliableAtUtc');
    _requireNonNegative(activeMicros, 'activeMicros');
  }

  final String sessionId;
  final String? occurrenceId;
  final String taskId;
  final ExecutionSessionState state;
  final ExecutionActivitySource source;
  final ExecutionMode mode;
  final DateTime startedAtUtc;
  final int activeMicros;
  final int revision;
  final DateTime lastReliableAtUtc;
  final int runtimeRevision;

  bool get isActive =>
      state == ExecutionSessionState.running ||
      state == ExecutionSessionState.paused ||
      state == ExecutionSessionState.recoveryPending;

  Duration get activeDuration => Duration(microseconds: activeMicros);
}

/// 一次"实例份额守恒"的输入：已有效入账 + 当前未完成份额 + 已明确减少的份额
/// 必须等于原始分配份额（规范 §5.2）。返回差额；0 表示守恒。
int executionShareDeltaMicros({
  required int allocatedMicros,
  required int creditedMicros,
  required int remainingAllocationMicros,
  required int explicitlyReducedMicros,
}) {
  _requireNonNegative(allocatedMicros, 'allocatedMicros');
  _requireNonNegative(creditedMicros, 'creditedMicros');
  _requireNonNegative(remainingAllocationMicros, 'remainingAllocationMicros');
  _requireNonNegative(explicitlyReducedMicros, 'explicitlyReducedMicros');
  return allocatedMicros -
      (creditedMicros + remainingAllocationMicros + explicitlyReducedMicros);
}

/// 供界面与指标使用的不可变执行事实集合。
final class ExecutionFacts {
  ExecutionFacts({
    required List<ExecutionOccurrence> occurrences,
    required List<ExecutionCreditAllocation> credits,
    required List<ExecutionActivitySegment> segments,
    required Map<String, DateTime> startedEvidence,
  }) : occurrences = UnmodifiableListView(List.of(occurrences)),
       credits = UnmodifiableListView(List.of(credits)),
       segments = UnmodifiableListView(List.of(segments)),
       startedEvidence = UnmodifiableMapView(Map.of(startedEvidence));

  final List<ExecutionOccurrence> occurrences;
  final List<ExecutionCreditAllocation> credits;
  final List<ExecutionActivitySegment> segments;

  /// 实例 id → 有效首次启动时刻（已按来源过滤）。
  final Map<String, DateTime> startedEvidence;
}
