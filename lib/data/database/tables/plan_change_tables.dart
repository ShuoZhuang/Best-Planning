import 'package:drift/drift.dart';

/// 1.11.0：调整应用回执、撤销快照与提交后副作用（计划 Task 10/11）。
///
/// **为什么必须是表**：应用回执是"同一令牌只产生一个新计划"的唯一证据
/// （DFR-015/029）；撤销快照是"不重跑算法也能精确恢复"的唯一依据（DFR-017/021）。
/// 两者都不能只活在一次调用的局部变量里。

/// 一次成功应用的唯一回执。`token_hash` 与 `adjustment_id` 都唯一：
/// 同一调整只能被应用一次，同一完整令牌只能换到一个计划版本。
class PlanAdjustmentApplyReceipts extends Table {
  TextColumn get receiptId => text()();
  TextColumn get adjustmentId => text().unique()();
  TextColumn get tokenHash => text().unique()();
  TextColumn get planVersionId => text()();
  TextColumn get undoReceiptId => text()();
  IntColumn get createdAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {receiptId};

  @override
  List<String> get customConstraints => [
    'CHECK (length(token_hash) = 64)',
    'CHECK (created_at_utc >= 0)',
  ];
}

/// 撤销快照：保存**基线块**与受影响的应用块身份，撤销时不重跑算法（DFR-017）。
///
/// 只存业务块字段，不存标题/备注/自由文本（隐私约束）。
class PlanAdjustmentUndoReceipts extends Table {
  TextColumn get receiptId => text()();
  TextColumn get adjustmentId => text().unique()();
  TextColumn get baselinePlanVersionId => text()();
  TextColumn get appliedPlanVersionId => text()();
  TextColumn get state => text()();
  TextColumn get baselineBlocksJson => text()();
  TextColumn get appliedBlockIdsJson => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get completedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {receiptId};

  @override
  List<String> get customConstraints => [
    "CHECK (state IN ('available', 'completed', 'blocked'))",
  ];
}

/// 提交后的数据库外副作用（通知重排、托盘/日历刷新），见 DFR-016。
///
/// 事务只负责**入队**；真正的副作用由 dispatcher 退避重试，失败不回滚已提交的计划。
class PlanChangeOutbox extends Table {
  TextColumn get id => text()();
  TextColumn get dedupeKey => text().unique()();
  TextColumn get kind => text()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  IntColumn get nextAttemptAtUtc => integer()();
  TextColumn get lastErrorCode => text().nullable()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get completedAtUtc => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (attempts >= 0)',
    "CHECK (kind IN ('planChanged', 'calendarRefresh', 'trayRefresh'))",
  ];
}
