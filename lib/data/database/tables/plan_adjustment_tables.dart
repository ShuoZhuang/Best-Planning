import 'package:drift/drift.dart';

/// 1.11.0 schema 11：块级调整操作（「延后本次」）的持久化（计划 Task 3 Step 2）。
///
/// **为什么必须是表而不是内存字段**：修复前一次延后只活在
/// `PendingMoveDrafts._adjustment` 里，生成路径的 `finally` 会清掉它，因此确认、
/// 重生、取消与重启恢复都无从谈起（DFR-001/003/004/018）。身份、意图、基线快照、
/// 修订号与过期时间落库之后，"生成结束"就不再等于"意图消失"。
///
/// 所有时刻都是 UTC 微秒；时区换算在写入前完成，SQL 里不再解释时区。
class PlanAdjustments extends Table {
  TextColumn get adjustmentId => text()();
  TextColumn get kind => text()();
  TextColumn get targetBlockId => text()();
  TextColumn get targetTaskId => text()();
  TextColumn get targetTitleSnapshot => text()();
  TextColumn get basePlanVersionId => text()();
  IntColumn get sourceStartUtc => integer()();
  IntColumn get sourceEndUtc => integer()();
  IntColumn get notBeforeUtc => integer()();
  TextColumn get timeZoneId => text()();
  IntColumn get requestedAmount => integer()();
  TextColumn get requestedUnit => text()();
  TextColumn get status => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get expiresAtUtc => integer()();
  IntColumn get revision => integer().withDefault(const Constant(1))();

  /// 同任务兄弟块 id 的 JSON 数组（不可变快照，DFR-034）。
  TextColumn get targetSiblingBlockIdsJson =>
      text().withDefault(const Constant('[]'))();

  /// 当前可确认的持久预览（`previewReady` 时非空）。
  TextColumn get previewId => text().nullable()();

  /// 应用成功后写入的目标计划版本；与 preview 一样全局唯一（见部分唯一索引）。
  TextColumn get appliedPlanVersionId => text().nullable()();

  TextColumn get failureCode => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {adjustmentId};

  @override
  List<String> get customConstraints => [
    'CHECK (source_end_utc > source_start_utc)',
    'CHECK (not_before_utc > source_start_utc)',
    'CHECK (expires_at_utc > created_at_utc)',
    'CHECK (requested_amount > 0)',
    'CHECK (revision >= 1)',
    "CHECK (kind IN ('defer'))",
    "CHECK (requested_unit IN ('minutes', 'hours', 'days'))",
    "CHECK (status IN ('active', 'generating', 'previewReady', 'applying', "
        "'applied', 'cancelled', 'failed', 'stale', 'expired'))",
    'CHECK (failure_code IS NULL OR failure_code IN ('
        "'targetMissing', 'targetChanged', 'targetIneligible', "
        "'basePlanChanged', 'previewExpired', 'tokenMismatch', 'noLegalSlot', "
        "'deadlineExceeded', 'disallowedWeekday', 'taskDailyLimitReached', "
        "'globalDailyLimitReached', 'requiredBreakUnavailable', "
        "'fixedOrProtectedConflict', 'searchBudgetExhausted', "
        "'invariantViolation', 'fulfilmentMissing', "
        "'fulfilmentDurationMismatch', 'concurrentModification'))",
    "CHECK ((status <> 'previewReady') OR preview_id IS NOT NULL)",
    "CHECK ((status <> 'applied') OR applied_plan_version_id IS NOT NULL)",
  ];
}

/// 调整状态转换的连续审计序列（计划 Task 3 Step 2、DFR-036）。
///
/// **只存稳定码与修订号**：不存标题、任务/块 UUID 的自由文本，也不存备注。
class PlanAdjustmentEvents extends Table {
  TextColumn get adjustmentId => text().references(
    PlanAdjustments,
    #adjustmentId,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get sequence => integer()();
  TextColumn get fromStatus => text()();
  TextColumn get toStatus => text()();
  IntColumn get revision => integer()();
  IntColumn get occurredAtUtc => integer()();
  TextColumn get reasonCode => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {adjustmentId, sequence};

  @override
  List<String> get customConstraints => [
    'CHECK (sequence >= 1)',
    'CHECK (revision >= 1)',
  ];
}
