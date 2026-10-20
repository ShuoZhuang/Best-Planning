import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/database/tables/planner_tables.dart';

part 'recurring_task_dao.g.dart';

/// 周期目标模板与周期实例的存取。
///
/// 这里只做"取数与写数"，**不做业务判断**（"这一周该不该生成""进度够不够"都在
/// `RecurringTaskService`）：DAO 一旦开始判断业务，那些判断就只能靠数据库测试来覆盖，
/// 而本周界、暂停、结转这类规则用纯 Dart 测试要快得多也准得多。
@DriftAccessor(
  tables: [RecurringTaskTemplates, RecurringTaskCycles, Tasks, TimeEntries],
)
class RecurringTaskDao extends DatabaseAccessor<AppDatabase>
    with _$RecurringTaskDaoMixin {
  RecurringTaskDao(super.attachedDatabase);

  // ── 模板 ────────────────────────────────────────────────────────────────

  Future<RecurringTaskTemplate?> findTemplateById(String id) => (select(
    recurringTaskTemplates,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  /// 全部模板，含已归档的。
  ///
  /// 排序按 `created_at_utc` 然后 `id`，理由与 `TaskDao.watchAll` 完全一致：
  /// 排程与摘要都不得依赖数据库的返回顺序（§7.2 最后一条），因此"顺序"必须是这个方法
  /// 的**合同**，而不是调用方的运气。
  Future<List<RecurringTaskTemplate>> listAllTemplates({
    bool includeArchived = true,
  }) {
    final query = select(recurringTaskTemplates)
      ..orderBy([
        (row) => OrderingTerm.asc(row.createdAtUtc),
        (row) => OrderingTerm.asc(row.id),
      ]);
    if (!includeArchived) {
      query.where((row) => row.status.equals('active'));
    }
    return query.get();
  }

  /// 开始日不晚于 [periodStartLocalDate] 且（没有结束日或结束日晚于该日）的启用模板。
  ///
  /// **日期比较用文本**：`starts_on_local_date` 存的是定宽 `YYYY-MM-DD`，字典序与
  /// 时间序一致，因此 `<=` 的语义正确，而且不需要在 SQL 里做日期解析。
  Future<List<RecurringTaskTemplate>> listGeneratableTemplates(
    String periodStartLocalDate,
  ) {
    final query = select(recurringTaskTemplates)
      ..where(
        (row) =>
            row.status.equals('active') &
            row.startsOnLocalDate.isSmallerOrEqualValue(periodStartLocalDate) &
            (row.endsOnLocalDate.isNull() |
                row.endsOnLocalDate.isBiggerOrEqualValue(periodStartLocalDate)),
      )
      ..orderBy([
        (row) => OrderingTerm.asc(row.createdAtUtc),
        (row) => OrderingTerm.asc(row.id),
      ]);
    return query.get();
  }

  /// 与 `[periodStart, periodEnd)` 有效区间相交的模板（1.11.0 设计 §5.1、Task 3）。
  Future<List<RecurringTaskTemplate>> listTemplatesIntersecting({
    required String periodStartLocalDate,
    required String periodEndLocalDate,
  }) {
    final query = select(recurringTaskTemplates)
      ..where(
        (row) =>
            row.status.equals('active') &
            row.startsOnLocalDate.isSmallerThanValue(periodEndLocalDate) &
            (row.endsOnLocalDate.isNull() |
                row.endsOnLocalDate.isBiggerOrEqualValue(periodStartLocalDate)),
      )
      ..orderBy([
        (row) => OrderingTerm.asc(row.createdAtUtc),
        (row) => OrderingTerm.asc(row.id),
      ]);
    return query.get();
  }

  Future<void> upsertTemplate(RecurringTaskTemplatesCompanion template) =>
      into(recurringTaskTemplates).insertOnConflictUpdate(template);

  // ── 周期实例 ─────────────────────────────────────────────────────────────

  Future<RecurringTaskCycle?> findCycle(
    String templateId,
    String periodStartLocalDate,
  ) =>
      (select(recurringTaskCycles)..where(
            (row) =>
                row.templateId.equals(templateId) &
                row.periodStartLocalDate.equals(periodStartLocalDate),
          ))
          .getSingleOrNull();

  /// 按生成的普通任务 id 反查周期实例。
  ///
  /// `task_id` 上的 UNIQUE 约束保证最多命中一行，因此可以直接取单值。
  Future<RecurringTaskCycle?> findCycleByTaskId(String taskId) =>
      (select(recurringTaskCycles)
            ..where((row) => row.taskId.equals(taskId))
            ..limit(1))
          .getSingleOrNull();

  /// 按 task id **集合**批量读取周期实例。
  ///
  /// 三条约束写在 SQL 这一层，而不是交给调用方补：
  /// - **空集合不发 SQL**（`IN ()` 是语法错误，而"空集合"在装配层是常态——没有周期目标
  ///   的用户每次生成计划都会走到这里）；
  /// - **只按 task id 查**，不按日期猜"哪些 open task 可能是实例"：日期不是身份，
  ///   跨时区边界与异常遗留的实例都必须能被认出来；
  /// - **排序在 SQL 里定死**（`period_start_local_date`、`template_id`、`task_id`）：
  ///   排程结果不得依赖数据库返回顺序（§7.2 最后一条）。
  Future<List<RecurringTaskCycle>> findCyclesByTaskIds(Set<String> taskIds) {
    if (taskIds.isEmpty) return Future.value(const []);
    final query = select(recurringTaskCycles)
      ..where((row) => row.taskId.isIn(taskIds))
      ..orderBy([
        (row) => OrderingTerm.asc(row.periodStartLocalDate),
        (row) => OrderingTerm.asc(row.templateId),
        (row) => OrderingTerm.asc(row.taskId),
      ]);
    return query.get();
  }

  Future<List<RecurringTaskCycle>> listCyclesInRange(
    String fromLocalDate,
    String toLocalDate,
  ) {
    final query = select(recurringTaskCycles)
      ..where(
        (row) =>
            row.periodStartLocalDate.isBiggerOrEqualValue(fromLocalDate) &
            row.periodStartLocalDate.isSmallerOrEqualValue(toLocalDate),
      )
      ..orderBy([
        (row) => OrderingTerm.asc(row.periodStartLocalDate),
        (row) => OrderingTerm.asc(row.templateId),
      ]);
    return query.get();
  }

  Future<List<RecurringTaskCycle>> listCyclesForTemplate(
    String templateId, {
    int? limit,
  }) {
    final query = select(recurringTaskCycles)
      ..where((row) => row.templateId.equals(templateId))
      // **按周倒序**（最近的一周在最前）：历史列表要回答的是"最近几周怎么样"，
      // 正序会让最新结果永远在最下面，而 `limit` 取到的会是最旧的那几周。
      ..orderBy([
        (row) => OrderingTerm.desc(row.periodStartLocalDate),
        (row) => OrderingTerm.asc(row.taskId),
      ]);
    if (limit != null) query.limit(limit);
    return query.get();
  }

  Future<void> upsertCycle(RecurringTaskCyclesCompanion cycle) =>
      into(recurringTaskCycles).insertOnConflictUpdate(cycle);

  /// 周期的 task_id 是否已被占用（UNIQUE 的显式预检）。
  Future<bool> cycleExistsForTask(String taskId) async {
    final row =
        await (select(recurringTaskCycles)
              ..where((row) => row.taskId.equals(taskId))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  // ── 分钟事实 ─────────────────────────────────────────────────────────────

  /// 任务是否存在。
  Future<bool> taskExists(String taskId) async {
    final row =
        await (select(tasks)
              ..where((row) => row.id.equals(taskId))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// 某个任务在 `[startedAtUtc, endedAtUtc)` 内**已确认且已结束**的时间记录合计分钟。
  ///
  /// **必须在 SQL 里聚合，而不是把行捞出来在 Dart 里算**：时间记录会长期累积，而这里每次
  /// 都要为每个周期目标算一遍。"取行再算"会把整张表的行搬进内存。
  ///
  /// 口径与 `DriftFocusEntryStore.confirmedEntries` 完全一致——两条路径读的是同一批行，
  /// 否则"专注记录里显示 45 分钟"与"周期进度显示 0 分钟"会互相矛盾：
  /// - `recovery_state = 'confirmed'`：崩溃恢复后**未确认**的记录不算完成；
  /// - `ended_at_utc IS NOT NULL`：还在跑的专注不算完成（它的时长还在变）；
  /// - 时长＝`(ended_at_utc − started_at_utc) / 60000000 − paused_minutes`，下界为 0。
  ///
  /// **起点落在窗口内**才计入：一条跨周记录归属它开始的那一周。这与用户看到的一致——
  /// 周日晚 23:30 开始的 60 分钟专注属于那一周，而不是"下周一凌晨"的那一周。
  Future<int> recordedMinutesForTask({
    required String taskId,
    required int startUtcMicros,
    required int endUtcMicros,
  }) async {
    final rows = await customSelect(
      'SELECT started_at_utc, ended_at_utc, paused_minutes '
      'FROM time_entries '
      'WHERE task_id = ? AND recovery_state = ? '
      'AND ended_at_utc IS NOT NULL '
      'AND started_at_utc >= ? AND started_at_utc < ?',
      variables: [
        Variable<String>(taskId),
        const Variable<String>('confirmed'),
        Variable<int>(startUtcMicros),
        Variable<int>(endUtcMicros),
      ],
      readsFrom: {timeEntries},
    ).get();

    var total = 0;
    for (final row in rows) {
      final started = row.read<int>('started_at_utc');
      final ended = row.read<int>('ended_at_utc');
      final paused = row.read<int>('paused_minutes');
      final minutes = (ended - started) ~/ Duration.microsecondsPerMinute;
      total += (minutes - paused).clamp(0, 1 << 30);
    }
    return total;
  }
}
