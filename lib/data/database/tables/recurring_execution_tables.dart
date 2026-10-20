import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/tables/execution_tables.dart';
import 'package:personal_planner/data/database/tables/planner_tables.dart';

/// 1.12.0 周期目标单次执行、证据账本与持久预排表（设计 §5）。
///
/// 所有时间列都是 UTC 微秒；周界与有效区间必须由 `TimeZoneDatabase` 预先算好，
/// 数据库只保存结果，不在 SQL 里重新解释时区。

/// 周实例的完整排程快照（设计 §5.1、Task 3）。
class RecurringCycleSnapshots extends Table {
  TextColumn get cycleId => text()();
  TextColumn get templateId => text()();
  TextColumn get transportTaskId => text()();
  TextColumn get periodStartLocalDate => text()();
  IntColumn get periodStartUtc => integer()();
  IntColumn get periodEndUtc => integer()();
  IntColumn get effectiveStartUtc => integer()();
  IntColumn get effectiveEndUtc => integer()();
  TextColumn get timeZoneId => text()();
  IntColumn get templateRevision => integer()();
  TextColumn get title => text()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get areaId => text().nullable()();
  TextColumn get projectId => text().nullable()();
  TextColumn get priority => text()();
  TextColumn get energyLevel => text()();
  TextColumn get splitMode => text()();
  IntColumn get minChunkMinutes => integer()();
  IntColumn get maxChunkMinutes => integer()();
  IntColumn get preferredStartMinute => integer().nullable()();
  IntColumn get preferredEndMinute => integer().nullable()();
  TextColumn get pace => text()();
  IntColumn get allowedWeekdaysMask => integer()();
  IntColumn get targetMinutes => integer()();
  IntColumn get carryInMinutes => integer().withDefault(const Constant(0))();
  TextColumn get state => text()();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();
  IntColumn get settledAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {cycleId};

  @override
  List<String> get customConstraints => [
    'UNIQUE (template_id, period_start_local_date)',
    'CHECK (period_end_utc > period_start_utc)',
    'CHECK (effective_end_utc > effective_start_utc)',
    'CHECK (effective_start_utc >= period_start_utc)',
    'CHECK (effective_end_utc <= period_end_utc)',
    'CHECK (target_minutes > 0)',
    'CHECK (carry_in_minutes >= 0)',
    'CHECK (revision >= 1)',
    'CHECK ((preferred_start_minute IS NULL) = '
        '(preferred_end_minute IS NULL))',
    "CHECK (state IN ('open', 'met', 'missed', 'skipped'))",
  ];
}

/// 可独立完成的执行片段（设计 §5.2、Task 6）。
class ExecutionFragments extends Table {
  TextColumn get fragmentId => text()();
  TextColumn get dataEpoch => text()();
  TextColumn get occurrenceId => text().references(
    ExecutionOccurrences,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get cycleId => text().nullable()();
  TextColumn get rootFragmentId => text()();
  TextColumn get sourceFragmentId => text().nullable()();
  TextColumn get planVersionId => text().references(PlanVersions, #id)();
  TextColumn get blockId => text()();
  IntColumn get plannedStartUtc => integer()();
  IntColumn get plannedEndUtc => integer()();
  IntColumn get plannedMinutes => integer()();
  IntColumn get allocatedMicros => integer()();
  IntColumn get completedMicros => integer().withDefault(const Constant(0))();
  TextColumn get state => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get completedAtUtc => integer().nullable()();
  IntColumn get revision => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {fragmentId};

  @override
  List<String> get customConstraints => [
    'UNIQUE (plan_version_id, block_id)',
    'CHECK (planned_end_utc > planned_start_utc)',
    'CHECK (planned_minutes > 0)',
    'CHECK (allocated_micros >= 0)',
    'CHECK (completed_micros >= 0)',
    'CHECK (completed_micros <= allocated_micros)',
    'CHECK (revision >= 1)',
    "CHECK (state IN ('planned', 'started', 'completed', 'withdrawn', "
        "'superseded'))",
  ];
}

/// 周期声明完成、撤销与更正证据（设计 §5.3、Task 7/8）。
class RecurringCompletionEvidence extends Table {
  TextColumn get evidenceId => text()();
  TextColumn get dataEpoch => text()();
  TextColumn get operationId => text()();
  TextColumn get cycleId => text()();
  TextColumn get fragmentId => text().nullable()();
  IntColumn get amountMicros => integer()();
  TextColumn get kind => text()();
  TextColumn get reversesEvidenceId => text().nullable()();
  IntColumn get recordedAtUtc => integer()();
  IntColumn get effectiveAtUtc => integer()();
  IntColumn get sequence => integer()();
  TextColumn get reason => text().nullable()();
  TextColumn get idempotencyKey => text()();
  IntColumn get revision => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {evidenceId};

  @override
  List<String> get customConstraints => [
    'UNIQUE (idempotency_key)',
    'CHECK (amount_micros > 0)',
    'CHECK (sequence >= 1)',
    'CHECK (revision >= 1)',
    "CHECK (kind IN ('activity', 'fragmentCompletion', 'manualAdjustment', "
        "'correction'))",
    "CHECK (kind <> 'correction' OR reverses_evidence_id IS NOT NULL)",
  ];
}

/// 周实例结转状态（1.11.0 Task 8）。
///
/// **为什么不给 `recurring_task_cycles` 加列**：那是 v7 就存在的历史表，回填列会改变
/// 历史 schema 快照并让 v7→v11 校验失败；这里用 v11 新表承载 provisional 标记。
class RecurringCarryInStates extends Table {
  TextColumn get cycleId => text()();
  BoolColumn get provisional => boolean().withDefault(const Constant(false))();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {cycleId};

  @override
  List<String> get customConstraints => ['CHECK (revision >= 1)'];
}

/// 待确认预排头（设计 §5.4、§11.4；1.11.0 计划 Task 3 Step 3 泛化）。
///
/// 它现在承载**所有**待确认预览：周期预排（`recurringLookahead`）与延后调整
/// （`deferAdjustment`）。`operationId` 是操作身份——周期预排固定为
/// `recurring-lookahead`，延后调整用 `adjustmentId`。因此"每个种类只有一条
/// active"的旧约束换成"每个操作只有一条 active"，两个独立调整不会互相 supersede。
class PendingPlanPreviews extends Table {
  TextColumn get previewId => text()();
  TextColumn get kind => text()();
  TextColumn get operationId =>
      text().withDefault(const Constant('recurring-lookahead'))();
  TextColumn get basePlanVersionId => text()();
  TextColumn get inputHash => text()();
  TextColumn get algorithmVersion => text()();
  IntColumn get windowStartUtc => integer()();
  IntColumn get windowEndUtc => integer()();
  TextColumn get timeZoneId => text()();
  TextColumn get status => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get expiresAtUtc => integer()();
  TextColumn get summaryJson => text().withDefault(const Constant('{}'))();
  TextColumn get diagnosticsJson => text().withDefault(const Constant('{}'))();
  IntColumn get revision => integer().withDefault(const Constant(1))();

  /// 完整提案（canonical JSON）。**不能只存块**：`unscheduled`、`conflicts`、
  /// `explanations`、`metrics`、`outcome` 与调整要求都是确认阶段必须复用的输入。
  TextColumn get proposalJson => text().withDefault(const Constant('{}'))();

  /// canonical 提案的 SHA-256；确认时逐字比对（DFR-033）。
  TextColumn get proposalSha256 => text().withDefault(const Constant(''))();

  /// 提案编码格式版本；未知版本拒绝解码，不丢字段重建"看起来可用"的残缺提案。
  IntColumn get formatVersion => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {previewId};

  @override
  List<String> get customConstraints => [
    'CHECK (window_end_utc > window_start_utc)',
    'CHECK (revision >= 1)',
    'CHECK (format_version >= 1)',
    "CHECK (kind IN ('recurringLookahead', 'deferAdjustment'))",
    "CHECK (status IN ('active', 'superseded', 'accepted', 'rejected', "
        "'stale'))",
  ];
}

/// 预排块：保存标题投影与来源身份，不写入正式计划表。
class PendingPlanPreviewBlocks extends Table {
  TextColumn get previewId => text().references(
    PendingPlanPreviews,
    #previewId,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get blockId => text()();
  TextColumn get taskId => text().nullable()();
  TextColumn get cycleId => text().nullable()();
  TextColumn get title => text()();
  IntColumn get startUtc => integer()();
  IntColumn get endUtc => integer()();
  IntColumn get minutes => integer()();
  TextColumn get explanationCode => text()();

  @override
  Set<Column<Object>> get primaryKey => {previewId, blockId};

  @override
  List<String> get customConstraints => [
    'CHECK (end_utc > start_utc)',
    'CHECK (minutes > 0)',
  ];
}
