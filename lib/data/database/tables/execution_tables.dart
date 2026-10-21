import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/tables/planner_tables.dart';

/// 1.11.0 执行事实的持久表（规范 §19.2）。
///
/// **表名与约束是本轮契约**：Drift 生成的类与 SQL 必须一致。`time_entries` 仍是会话的
/// 基础计时账本，本组表只补充执行实例、事件、会话归属、活动段、进度与提醒；不复制成
/// 第二份计时账。
///
/// 跨行不变量（时长守恒、区间重叠、来源完整性）由同一写事务里的查询与验证完成，
/// 禁止假称行级 CHECK 已经覆盖它们。

/// 单行运行时状态：功能启用时间、唯一实时会话槽位、数据代次（规范 §19.2）。
class ExecutionRuntimeState extends Table {
  IntColumn get id => integer()();
  TextColumn get dataEpoch => text()();
  TextColumn get activeSessionId => text().nullable().references(
    TimeEntries,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  IntColumn get featureEnabledAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (id = 1)',
    'CHECK (revision >= 1)',
  ];
}

/// 已提交执行事实的单调序号。序号由写事务分配，不用时间戳替代顺序（规范 §10.2）。
class ExecutionWriteSequence extends Table {
  IntColumn get id => integer()();
  IntColumn get nextValue => integer().withDefault(const Constant(1))();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (id = 1)',
    'CHECK (next_value >= 0)',
  ];
}

/// 命令结果账本：与业务写入同事务提交，供断线、重启和重复点击重放（规范 §11、§19.3）。
class ExecutionOperations extends Table {
  TextColumn get dataEpoch => text()();
  TextColumn get operationId => text()();
  TextColumn get requestHash => text()();
  TextColumn get commandType => text()();
  TextColumn get subjectKind => text()();
  TextColumn get subjectId => text().nullable()();
  TextColumn get resultJson => text()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {dataEpoch, operationId};
}

/// 执行实例：用户承诺执行的一次安排（规范 §5.1）。
class ExecutionOccurrences extends Table {
  TextColumn get id => text()();

  /// 普通删除转匿名墓碑后为空；为空时不得借此重新绑定到另一任务。
  TextColumn get taskId =>
      text().nullable().references(Tasks, #id, onDelete: KeyAction.setNull)();
  TextColumn get originPlanVersionId => text().nullable()();
  TextColumn get originBlockId => text().nullable()();
  IntColumn get baselineStartUtc => integer()();
  IntColumn get baselineEndUtc => integer()();
  TextColumn get baselineTimeZoneId => text()();
  TextColumn get baselineLocalDate => text()();
  IntColumn get baselinePlannedDurationMicros => integer()();
  TextColumn get currentPlanVersionId => text().nullable()();

  /// 该实例最初承担的精确工作量与尚未执行份额（非负整数微秒）。
  IntColumn get allocatedMicros => integer()();
  IntColumn get remainingAllocationMicros => integer()();
  TextColumn get firstStartEvidenceId => text().nullable()();
  TextColumn get withdrawalReason => text().nullable()();
  IntColumn get withdrawnAtUtc => integer().nullable()();
  TextColumn get lifecycleState => text()();
  TextColumn get privacyState => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get revision => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (baseline_end_utc > baseline_start_utc)',
    'CHECK (baseline_planned_duration_micros >= 0)',
    'CHECK (allocated_micros >= 0)',
    'CHECK (remaining_allocation_micros >= 0)',
    'CHECK (remaining_allocation_micros <= allocated_micros)',
    'CHECK (revision >= 1)',
    "CHECK (lifecycle_state IN ('planned', 'started', 'finished', 'withdrawn'))",
    "CHECK (privacy_state IN ('linked', 'anonymized'))",
  ];
}

/// 已提交计划块与执行实例的关联。拆分为多条链接，记录来源块与预留量（规范 §5.1、§19.5）。
class ExecutionBlockLinks extends Table {
  TextColumn get dataEpoch => text()();
  TextColumn get planVersionId => text().references(PlanVersions, #id)();
  TextColumn get blockId => text()();
  TextColumn get occurrenceId => text().references(
    ExecutionOccurrences,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get sourceBlockId => text().nullable()();
  IntColumn get reservedMicros => integer()();
  IntColumn get createdAtUtc => integer()();

  /// 可见块对应的执行片段；v11 旧行迁移后由回填补齐（设计 §5.2）。
  TextColumn get fragmentId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {dataEpoch, planVersionId, blockId};

  @override
  List<String> get customConstraints => ['CHECK (reserved_micros >= 0)'];
}

/// 领域事件。`(operation_id, sub_event_index)` 唯一；请求摘要与命令结果只保存在
/// `execution_operations`，避免两套幂等事实（规范 §19.2）。
class ExecutionEvents extends Table {
  TextColumn get eventId => text()();
  TextColumn get dataEpoch => text()();
  TextColumn get operationId => text()();
  IntColumn get subEventIndex => integer()();
  TextColumn get occurrenceId =>
      text().nullable().references(ExecutionOccurrences, #id)();
  TextColumn get eventType => text()();
  IntColumn get occurredAtUtc => integer()();
  IntColumn get recordedAtUtc => integer()();
  TextColumn get source => text()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  TextColumn get correctedEventId => text().nullable()();
  IntColumn get sequence => integer()();
  IntColumn get revision => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {eventId};

  @override
  List<String> get customConstraints => [
    'UNIQUE (operation_id, sub_event_index)',
    'CHECK (sub_event_index >= 0)',
    'CHECK (sequence >= 1)',
    'CHECK (revision >= 1)',
  ];
}

/// 会话主归属：来源、planned/actualOnly、首次入账序号与当前有效修订（规范 §19.2）。
class ExecutionSessionLinks extends Table {
  TextColumn get sessionId =>
      text().references(TimeEntries, #id, onDelete: KeyAction.cascade)();
  TextColumn get dataEpoch => text()();
  TextColumn get occurrenceId =>
      text().nullable().references(ExecutionOccurrences, #id)();
  TextColumn get source => text()();
  TextColumn get mode => text()();
  IntColumn get firstAcceptedSequence => integer().nullable()();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {sessionId};

  @override
  List<String> get customConstraints => [
    'CHECK (revision >= 1)',
    "CHECK (source IN ('realtime', 'manual', 'recoveryConfirmed', 'legacyUnlinked'))",
    "CHECK (mode IN ('planned', 'actualOnly'))",
  ];
}

/// 精确活动段：半开区间 `[start, end)`，结束必须大于开始（规范 §19.1）。
class ExecutionActivitySegments extends Table {
  TextColumn get segmentId => text()();
  TextColumn get dataEpoch => text()();
  TextColumn get sessionId =>
      text().references(TimeEntries, #id, onDelete: KeyAction.cascade)();
  IntColumn get sequence => integer()();
  IntColumn get startUtc => integer()();
  IntColumn get endUtc => integer()();
  TextColumn get source => text()();
  TextColumn get invalidatedReason => text().nullable()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {segmentId};

  @override
  List<String> get customConstraints => [
    'UNIQUE (session_id, sequence)',
    'CHECK (end_utc > start_utc)',
    'CHECK (sequence >= 1)',
    "CHECK (source IN ('realtime', 'manual', 'recoveryConfirmed', 'legacyUnlinked'))",
  ];
}

/// 人工剩余检查点：每任务只有一个当前检查点（规范 §10.2）。
class ExecutionProgressAnchors extends Table {
  TextColumn get taskId =>
      text().references(Tasks, #id, onDelete: KeyAction.cascade)();
  IntColumn get revision => integer()();
  IntColumn get anchorRemainingMicros => integer()();
  IntColumn get anchorSequence => integer()();
  TextColumn get reason => text()();
  IntColumn get createdAtUtc => integer()();
  BoolColumn get isCurrent => boolean().withDefault(const Constant(true))();

  @override
  Set<Column<Object>> get primaryKey => {taskId, revision};

  @override
  List<String> get customConstraints => [
    'CHECK (revision >= 1)',
    'CHECK (anchor_remaining_micros >= 0)',
    'CHECK (anchor_sequence >= 0)',
  ];
}

/// 活动段向普通任务或周期目标的精确分配（规范 §19.2）。
class ExecutionCreditAllocations extends Table {
  TextColumn get dataEpoch => text()();
  TextColumn get segmentId => text().references(
    ExecutionActivitySegments,
    #segmentId,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get targetKind => text()();
  TextColumn get targetId => text()();
  IntColumn get allocationIndex => integer()();
  IntColumn get recordRevision => integer()();
  IntColumn get amountMicros => integer()();

  /// 首次入账序号。更正保留原值，进度检查点据此判断"是否在锚点之后"（规范 §10.2）。
  IntColumn get firstAcceptedSequence => integer()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {
    segmentId,
    targetKind,
    targetId,
    allocationIndex,
    recordRevision,
  };

  @override
  List<String> get customConstraints => [
    'CHECK (amount_micros > 0)',
    'CHECK (allocation_index >= 0)',
    'CHECK (record_revision >= 1)',
    'CHECK (first_accepted_sequence >= 1)',
    "CHECK (target_kind IN ('task', 'recurringCycle'))",
  ];
}

/// 执行提醒意图：每个实例最多一个当前修订（规范 §13、§21）。
class ExecutionReminderIntents extends Table {
  TextColumn get dataEpoch => text()();
  TextColumn get occurrenceId => text().references(
    ExecutionOccurrences,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get revision => integer()();
  IntColumn get targetAtUtc => integer()();
  TextColumn get notificationId => text()();
  TextColumn get state => text()();
  IntColumn get claimedAtUtc => integer().nullable()();
  IntColumn get scheduledAtUtc => integer().nullable()();
  TextColumn get dispatchResult => text().nullable()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {occurrenceId, revision, dataEpoch};

  @override
  List<String> get customConstraints => [
    'CHECK (revision >= 1)',
    "CHECK (state IN ('pending', 'claimed', 'scheduled', 'suppressed', "
        "'expired', 'unknown', 'cancelled', 'handled'))",
  ];
}

/// 已确认的"今天不再安排"一次性限制（规范 §8、§19.2）。
class ExecutionDayHolds extends Table {
  TextColumn get taskId =>
      text().references(Tasks, #id, onDelete: KeyAction.cascade)();
  TextColumn get localDate => text()();
  TextColumn get timeZoneId => text()();
  IntColumn get invalidAfterUtc => integer()();
  TextColumn get sourceProposalId => text().nullable()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {taskId, localDate, timeZoneId};
}

/// 关键事务之后的可重试附加操作（统计缓存失效、偏好证据、通知对账）（规范 §19.2）。
class ExecutionOutbox extends Table {
  TextColumn get effectId => text()();
  TextColumn get dataEpoch => text()();
  TextColumn get sourceTransaction => text()();
  IntColumn get targetRevision => integer()();
  TextColumn get effectType => text()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  IntColumn get createdAtUtc => integer()();
  IntColumn get nextAttemptAtUtc => integer()();
  IntColumn get processedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {effectId};

  @override
  List<String> get customConstraints => [
    'CHECK (attempts >= 0)',
    'CHECK (target_revision >= 1)',
  ];
}
