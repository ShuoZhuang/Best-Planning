import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/recurring_task_repository.dart';

/// 周期目标的 Drift 实现。
///
/// 行与领域对象的转换只在这一层发生：模板/周期的日期一律以 `YYYY-MM-DD` 文本落库，
/// **不经过 `DateTime` 的时区解释**（见 `planner_tables.dart` 里两张表的说明）。
final class DriftRecurringTaskRepository implements RecurringTaskRepository {
  DriftRecurringTaskRepository(this._database, this._dao);

  final db.AppDatabase _database;
  final RecurringTaskDao _dao;

  @override
  Future<void> saveTemplate(RecurringTaskTemplate template) =>
      _dao.upsertTemplate(_templateToRow(template));

  @override
  Future<RecurringTaskTemplate?> findTemplate(String templateId) async {
    final row = await _dao.findTemplateById(templateId);
    return row == null ? null : _templateToDomain(row);
  }

  @override
  Future<List<RecurringTaskTemplate>> listTemplates({
    bool includeArchived = true,
  }) async {
    final rows = await _dao.listAllTemplates(includeArchived: includeArchived);
    return rows.map(_templateToDomain).toList(growable: false);
  }

  @override
  Future<List<RecurringTaskTemplate>> listGeneratableTemplates(
    DateTime periodStartLocalDate,
  ) async {
    final rows = await _dao.listGeneratableTemplates(
      formatLocalDate(localDateOnly(periodStartLocalDate)),
    );
    return rows.map(_templateToDomain).toList(growable: false);
  }

  @override
  Future<RecurringTaskCycle?> findCycle(
    String templateId,
    DateTime periodStartLocalDate,
  ) async {
    final row = await _dao.findCycle(
      templateId,
      formatLocalDate(localDateOnly(periodStartLocalDate)),
    );
    return row == null ? null : _cycleToDomain(row);
  }

  @override
  Future<List<RecurringTaskCycle>> listCyclesInRange(
    DateTime fromLocalDate,
    DateTime toLocalDate,
  ) async {
    final rows = await _dao.listCyclesInRange(
      formatLocalDate(localDateOnly(fromLocalDate)),
      formatLocalDate(localDateOnly(toLocalDate)),
    );
    return rows.map(_cycleToDomain).toList(growable: false);
  }

  @override
  Future<List<RecurringTaskCycle>> listCyclesForTemplate(
    String templateId, {
    int? limit,
  }) async {
    final rows = await _dao.listCyclesForTemplate(templateId, limit: limit);
    return rows.map(_cycleToDomain).toList(growable: false);
  }

  @override
  Future<void> saveCycle(RecurringTaskCycle cycle) =>
      _dao.upsertCycle(_cycleToRow(cycle));

  /// 事务性的"没有就创建"。
  ///
  /// 两层保护，缺一不可：
  /// ① **一个事务**包住"写普通任务 + 写周期行"。任务写入失败时周期行必须一起回滚，
  ///    否则会留下一个指向不存在任务的实例，而外键只在**写入那一刻**检查；
  /// ② **插入失败后重新查询**，而不是把异常抛给调用方。两路并发生成（重复启动、
  ///    重复调用、恢复备份后重跑）在 `insertOnConflictUpdate` 下会**覆盖**先到的那一行
  ///    ——那会把 task_id 换成一个新任务，等价于"这一周生成了两次"。因此这里先用
  ///    `insert`（不是 upsert）让唯一约束真的生效，撞上了就承认"已经有人建过"，
  ///    返回**先到的那一行**。这正是 §7.2 第一条要求的语义。
  @override
  Future<RecurringTaskCycle> createCycleIfAbsent({
    required RecurringTaskCycle cycle,
    required PlannerTask task,
  }) => _database.transaction(() async {
    if (!await _dao.cycleExistsForTask(task.id)) {
      await _database
          .into(_database.tasks)
          .insertOnConflictUpdate(_taskToRow(task));
    }
    try {
      await _database
          .into(_database.recurringTaskCycles)
          .insert(_cycleToRow(cycle));
    } on Exception {
      // 唯一约束（(template_id, period_start_local_date) 或 task_id）拒绝了这次插入：
      // 说明并发的另一路已经建好了。回读那一行才是"实际存在的周期"。
      final existing = await _dao.findCycle(
        cycle.templateId,
        formatLocalDate(cycle.periodStartLocalDate),
      );
      if (existing == null) rethrow;
      return _cycleToDomain(existing);
    }
    final inserted = await _dao.findCycle(
      cycle.templateId,
      formatLocalDate(cycle.periodStartLocalDate),
    );
    return inserted == null ? cycle : _cycleToDomain(inserted);
  });

  /// 从现有 `time_entries` 汇总完成分钟（§4.2 最后一句：不造第二套分钟事实）。
  ///
  /// **聚合在 SQL 里做**：时间记录会长期累积，而每个周期目标每周都要问一次，把整张表
  /// 的行搬进内存只为加几个数不划算。
  ///
  /// 与 `DriftFocusEntryStore.confirmedEntries` 同一口径：只有
  /// `recovery_state = 'confirmed'`（崩溃恢复后未确认的不算）且
  /// `ended_at_utc IS NOT NULL`（还在跑的不算）的记录计入。时长按结束减开始再扣暂停，
  /// 下界为 0——暂停分钟大于跨度是脏数据，不该让进度变成负数。
  @override
  Future<int> recordedMinutesForTask(
    String taskId,
    DateTime periodStartUtc,
    DateTime periodEndUtc,
  ) async {
    // 逐行取"结束 − 开始 − 暂停"，**负数按 0 计**。SQLite 的 `max()` 是标量函数，但在
    // Drift 的表达式层里直接写它会与聚合 `max` 混淆，而 `abs()` 又会把"暂停 100 分钟但
    // 只跑了 30 分钟"这种脏数据算成 +70。因此用 `CASE WHEN … THEN … ELSE 0 END`：语义
    // 与 `FocusSession.activeMinutes` 的"下界为 0"完全一致，读者不必猜。
    final micros =
        _database.timeEntries.endedAtUtc -
        _database.timeEntries.startedAtUtc -
        _database.timeEntries.pausedMinutes *
            const Constant<int>(Duration.microsecondsPerMinute);
    final clamped = CaseWhenExpression<int>(
      cases: [CaseWhen(micros.isBiggerThanValue(0), then: micros)],
      orElse: const Constant<int>(0),
    );
    final query = _database.selectOnly(_database.timeEntries)
      ..addColumns([clamped])
      ..where(
        _database.timeEntries.taskId.equals(taskId) &
            _database.timeEntries.recoveryState.equals('confirmed') &
            _database.timeEntries.endedAtUtc.isNotNull() &
            _database.timeEntries.startedAtUtc.isBiggerOrEqualValue(
              periodStartUtc.microsecondsSinceEpoch,
            ) &
            _database.timeEntries.startedAtUtc.isSmallerThanValue(
              periodEndUtc.microsecondsSinceEpoch,
            ),
      );
    final rows = await query.get();
    var total = 0;
    for (final row in rows) {
      final value = row.read<int>(clamped) ?? 0;
      total += value ~/ Duration.microsecondsPerMinute;
    }
    return total;
  }

  db.RecurringTaskTemplatesCompanion _templateToRow(
    RecurringTaskTemplate template,
  ) => db.RecurringTaskTemplatesCompanion(
    id: Value(template.id),
    title: Value(template.title),
    notes: Value(template.notes),
    areaId: Value(template.areaId),
    projectId: Value(template.projectId),
    targetMinutes: Value(template.targetMinutes),
    priority: Value(template.priority.name),
    energyLevel: Value(template.energyLevel.name),
    splitMode: Value(template.splitMode.name),
    minChunkMinutes: Value(template.minChunkMinutes),
    maxChunkMinutes: Value(template.maxChunkMinutes),
    preferredStartMinute: Value(template.preferredStartMinute),
    preferredEndMinute: Value(template.preferredEndMinute),
    pace: Value(template.pace.name),
    allowedWeekdaysMask: Value(template.allowedWeekdaysMask),
    carryOverUnfinished: Value(template.carryOverUnfinished),
    startsOnLocalDate: Value(formatLocalDate(template.startsOnLocalDate)),
    endsOnLocalDate: Value(
      template.endsOnLocalDate == null
          ? null
          : formatLocalDate(template.endsOnLocalDate!),
    ),
    pausedUntilLocalDate: Value(
      template.pausedUntilLocalDate == null
          ? null
          : formatLocalDate(template.pausedUntilLocalDate!),
    ),
    timeZoneId: Value(template.timeZoneId),
    status: Value(template.status.name),
    createdAtUtc: Value(template.createdAtUtc.microsecondsSinceEpoch),
    updatedAtUtc: Value(template.updatedAtUtc.microsecondsSinceEpoch),
  );

  RecurringTaskTemplate _templateToDomain(db.RecurringTaskTemplate row) =>
      RecurringTaskTemplate(
        id: row.id,
        title: row.title,
        notes: row.notes,
        areaId: row.areaId,
        projectId: row.projectId,
        targetMinutes: row.targetMinutes,
        priority: TaskPriority.values.byName(row.priority),
        energyLevel: TaskEnergyLevel.values.byName(row.energyLevel),
        splitMode: TaskSplitMode.values.byName(row.splitMode),
        minChunkMinutes: row.minChunkMinutes,
        maxChunkMinutes: row.maxChunkMinutes,
        preferredStartMinute: row.preferredStartMinute,
        preferredEndMinute: row.preferredEndMinute,
        pace: RecurringPace.values.byName(row.pace),
        allowedWeekdaysMask: row.allowedWeekdaysMask,
        carryOverUnfinished: row.carryOverUnfinished,
        startsOnLocalDate: parseLocalDate(row.startsOnLocalDate),
        endsOnLocalDate: row.endsOnLocalDate == null
            ? null
            : parseLocalDate(row.endsOnLocalDate!),
        pausedUntilLocalDate: row.pausedUntilLocalDate == null
            ? null
            : parseLocalDate(row.pausedUntilLocalDate!),
        timeZoneId: row.timeZoneId,
        status: RecurringTemplateStatus.values.byName(row.status),
        createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
          row.createdAtUtc,
          isUtc: true,
        ),
        updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
          row.updatedAtUtc,
          isUtc: true,
        ),
      );

  db.RecurringTaskCyclesCompanion _cycleToRow(RecurringTaskCycle cycle) =>
      db.RecurringTaskCyclesCompanion(
        templateId: Value(cycle.templateId),
        periodStartLocalDate: Value(
          formatLocalDate(cycle.periodStartLocalDate),
        ),
        taskId: Value(cycle.taskId),
        baseTargetMinutes: Value(cycle.baseTargetMinutes),
        carryInMinutes: Value(cycle.carryInMinutes),
        status: Value(cycle.status.name),
        createdAtUtc: Value(cycle.createdAtUtc.microsecondsSinceEpoch),
        updatedAtUtc: Value(cycle.updatedAtUtc.microsecondsSinceEpoch),
      );

  RecurringTaskCycle _cycleToDomain(db.RecurringTaskCycle row) =>
      RecurringTaskCycle(
        templateId: row.templateId,
        periodStartLocalDate: parseLocalDate(row.periodStartLocalDate),
        taskId: row.taskId,
        baseTargetMinutes: row.baseTargetMinutes,
        carryInMinutes: row.carryInMinutes,
        status: RecurringCycleStatus.values.byName(row.status),
        createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
          row.createdAtUtc,
          isUtc: true,
        ),
        updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
          row.updatedAtUtc,
          isUtc: true,
        ),
      );

  db.TasksCompanion _taskToRow(PlannerTask task) => db.TasksCompanion(
    id: Value(task.id),
    projectId: Value(task.projectId),
    areaId: Value(task.areaId),
    title: Value(task.title),
    notes: Value(task.notes),
    priority: Value(task.priority.name),
    estimatedMinutes: Value(task.estimatedMinutes),
    remainingMinutes: Value(task.remainingMinutes),
    dueAtUtc: Value(task.dueAtUtc?.microsecondsSinceEpoch),
    availableFromUtc: Value(task.availableFromUtc?.microsecondsSinceEpoch),
    energyLevel: Value(task.energyLevel.name),
    splitMode: Value(task.splitMode.name),
    minChunkMinutes: Value(task.minChunkMinutes),
    maxChunkMinutes: Value(task.maxChunkMinutes),
    preferredStartMinute: Value(task.preferredWindow?.startMinute),
    preferredEndMinute: Value(task.preferredWindow?.endMinute),
    status: Value(task.status.name),
    createdAtUtc: Value(task.createdAtUtc.microsecondsSinceEpoch),
    updatedAtUtc: Value(task.updatedAtUtc.microsecondsSinceEpoch),
  );
}
