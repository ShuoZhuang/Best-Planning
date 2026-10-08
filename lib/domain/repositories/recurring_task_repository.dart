import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';

/// 周期目标的持久化接口（路线图 §5）。
///
/// 与 `TaskRepository` 并列而不是把它加宽：周期模板、周期实例与普通任务是**三类不同的
/// 事实**，混进一个接口会让"任务"这个词同时指三样东西，而本仓库已经因为"一个方法两种
/// 语义"吃过亏（见 `TaskRepository.watchOpenTasks` 的说明）。
abstract interface class RecurringTaskRepository {
  // ── 模板 ────────────────────────────────────────────────────────────────
  Future<void> saveTemplate(RecurringTaskTemplate template);

  Future<RecurringTaskTemplate?> findTemplate(EntityId templateId);

  /// 全部模板，含已归档的（详情页的历史与"停止以后生成"都要读到归档模板）。
  ///
  /// **排序在 SQL 里定死**（`created_at_utc` 然后 `id`）：排程结果不得依赖数据库返回
  /// 顺序（§7.2 最后一条），而"最后一条兜底排序"必须由仓储给出，不能指望调用方每次
  /// 自己排。这与 `TaskDao.watchAll` 的口径一致。
  Future<List<RecurringTaskTemplate>> listTemplates({
    bool includeArchived = true,
  });

  /// 只返回**当前应当生成实例**的模板：状态为 `active`、已到开始日、未过结束日。
  ///
  /// 暂停**不在这里过滤**：暂停有到期日，判断"这一周是否暂停"需要知道是哪一周，
  /// 因此由服务层用 `RecurringTaskTemplate.isPausedOn` 判定。
  Future<List<RecurringTaskTemplate>> listGeneratableTemplates(
    DateTime periodStartLocalDate,
  );

  // ── 周期实例 ─────────────────────────────────────────────────────────────
  /// 按 `(templateId, periodStartLocalDate)` 读取单个周期，不存在时为 `null`。
  Future<RecurringTaskCycle?> findCycle(
    EntityId templateId,
    DateTime periodStartLocalDate,
  );

  /// 按**生成的普通任务 id** 反查它属于哪一个周期实例。
  ///
  /// 排程层手里只有任务 id（`UnscheduledTask.taskId`），而缺口卡片要说的是"哪个周期目标
  /// 差多少"。`recurring_task_cycles.task_id` 上的 UNIQUE 约束让这个反查最多命中一行，
  /// 因此它可以安全地返回单值。
  Future<RecurringTaskCycle?> findCycleByTaskId(EntityId taskId);

  /// 落在 `[fromLocalDate, toLocalDate]`（含两端）内的全部周期实例。
  Future<List<RecurringTaskCycle>> listCyclesInRange(
    DateTime fromLocalDate,
    DateTime toLocalDate,
  );

  /// 某个模板的历史周期，最近的排在前面。
  Future<List<RecurringTaskCycle>> listCyclesForTemplate(
    EntityId templateId, {
    int? limit,
  });

  Future<void> saveCycle(RecurringTaskCycle cycle);

  /// **事务性**的"没有就创建"（路线图 Task 5 Step 2）。
  ///
  /// 两个并发生成请求（重复启动、重复调用、恢复备份后重跑）只能有一个
  /// `(templateId, periodStartLocalDate)` 周期——唯一约束由数据库保证，这里再把它
  /// 和"创建本周那个普通任务"放进**同一个事务**：只要任务写入失败，周期行也回滚，
  /// 不会留下一个指向不存在任务的实例。
  ///
  /// 返回实际存在的那个周期（无论是本次创建的还是先到的那个），因此调用方不需要
  /// 自己判断"这次到底建没建"。
  Future<RecurringTaskCycle> createCycleIfAbsent({
    required RecurringTaskCycle cycle,
    required PlannerTask task,
  });

  /// 某个任务的完成分钟合计（来自 `time_entries`）。
  ///
  /// **刻意放在仓储层**：它是"从既有事实表汇总"，属于持久化细节；服务层拿到的应该是
  /// 一个数字，而不是一句 SQL。
  Future<int> recordedMinutesForTask(
    EntityId taskId,
    DateTime periodStartUtc,
    DateTime periodEndUtc,
  );

  /// 手动补记一段已完成的分钟（路线图 §3.3"专注计时和手动补记都计入本周进度"）。
  ///
  /// **写进现有 `time_entries`**，不建第二张表、也不加第二套分钟口径（§4.2 最后一句）。
  /// 落库形状与 `DriftFocusEntryStore.save` 完全一致：`recovery_state = 'confirmed'`、
  /// `ended_at_utc` 非空，因此它会被 `recordedMinutesForTask` 与专注记录一视同仁地汇总。
  Future<void> recordCompletedMinutes({
    required EntityId entryId,
    required EntityId taskId,
    required int minutes,
    required DateTime endedAtUtc,
    String note = '',
  });

  /// 更新周期实例对应的普通任务（结算后会重算它的预计与剩余时长）。
  Future<void> saveTask(PlannerTask task);

  /// 某个任务在 `[startUtc, endUtc)` 内已确认的**每一次**记录时长（分钟），按开始时刻升序。
  ///
  /// **"本段 45 分钟"需要它**（§3.3：卡片要同时写"本周已完成 80/180"与"本段 45 分钟"）。
  /// 与 `recordedMinutesForTask` 的唯一差别是**不求和**：那个回答"这周一共做了多少"，
  /// 这个回答"今天/这一段做了多少"。两个数字必须来自同一批行，否则同一条专注记录会在
  /// 同一张卡片上给出两个互相矛盾的时长。
  Future<List<int>> recordedSegmentsForTask(
    EntityId taskId,
    DateTime startUtc,
    DateTime endUtc,
  );

  /// 删除某个周期实例以及它的普通任务（连带该任务的专注记录与修正记录）。
  ///
  /// 三张表在同一个事务里按依赖顺序清干净：外键（`time_entries.task_id` →
  /// `tasks.id`）不允许留下孤儿行，而"只删一半"会让这一周的进度凭空消失或让删除失败。
  Future<void> deleteCycleAndTask({
    required EntityId templateId,
    required DateTime periodStartLocalDate,
  });
}
