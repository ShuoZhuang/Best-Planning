import 'dart:math' as math;

import 'package:personal_planner/application/recurring_period.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/recurring_task_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

/// 一次 `ensureCycles` 的结果。
///
/// 除了生成的周期，还如实回报**这次到底新做了什么**：界面文案（"本周目标已就绪"）与
/// 测试断言都需要它，而让调用方自己比较调用前后的数据库状态既慢又容易漏掉"结算"这一类
/// 变化——结算同样是这次调用产生的后果。
final class RecurringCycleRun {
  const RecurringCycleRun({
    required this.cycles,
    required this.createdCount,
    required this.settledCount,
    required this.skippedCount,
  });

  /// 本次窗口内**全部**周期实例（含本次未新建的），按 `(periodStart, templateId)` 排序。
  final List<RecurringTaskCycle> cycles;
  final int createdCount;
  final int settledCount;
  final int skippedCount;

  bool get changed => createdCount > 0 || settledCount > 0;
}

/// 某一次生成请求的产物快照。
final class RecurringCycleCreation {
  const RecurringCycleCreation({
    required this.cycle,
    required this.task,
    required this.created,
  });

  final RecurringTaskCycle cycle;
  final PlannerTask task;

  /// 是否由本次调用真的写入。为 `false` 表示这一周早已存在（幂等命中）。
  final bool created;
}

/// 周期目标的生成、结算与进度（路线图 §3.3、§5、§11 Task 6）。
///
/// **三条不变量**，全部有专门的测试守着：
/// - **幂等**：同一模板同一周只有一个周期实例，重复启动、重复调用、恢复备份后重跑都一样。
///   实现方式是"先查、再事务性插入、最后回读"，唯一性由数据库主键兜底。
/// - **单一分钟来源**：完成分钟只从既有 `time_entries` 汇总，手动补记写的也是那张表。
/// - **不改写历史**：结算只把结果写进**已经过去**的周期；一旦某个周期的状态不再是
///   `open`，后续调用不会再动它（"上周的结果保留"，Global Constraints）。
final class RecurringTaskService {
  RecurringTaskService({
    required RecurringTaskRepository repository,
    required Clock clock,
    required IdGenerator idGenerator,
    required TimeZoneDatabase zones,
    required String timeZoneId,
    TaskRepository? tasks,
    void Function(ScheduleInputChange change)? onScheduleInputChanged,
  }) : _repository = repository,
       _clock = clock,
       _idGenerator = idGenerator,
       _zones = zones,
       _timeZoneId = timeZoneId,
       _tasks = tasks,
       _onScheduleInputChanged = onScheduleInputChanged;

  final RecurringTaskRepository _repository;
  final Clock _clock;
  final IdGenerator _idGenerator;
  final TimeZoneDatabase _zones;
  final String _timeZoneId;

  /// 普通任务仓储。为 `null` 时**不改写**周期任务的剩余时长（只读场景），
  /// 生成与结算照常——它们写的是周期表。
  final TaskRepository? _tasks;

  /// 与任务/日历共用的"排程输入变了"入口（见 `replanning_coordinator.dart`）。
  final void Function(ScheduleInputChange change)? _onScheduleInputChanged;

  /// 某一周在当前时区里的起止。
  WeeklyPeriod periodContaining(DateTime nowUtc) =>
      WeeklyPeriod.forInstant(nowUtc, _timeZoneId, _zones);

  /// 生成 `[window]` 内的周期实例，并顺手结算**已经过去**的那些。
  ///
  /// **顺序是刻意的：先结算上一周，再生成、最后按分钟重算本周任务。**
  ///
  /// 结算必须排在生成**之前**：结转要把上一周的缺口写进本周的实例，而 `_carryInFor` 读的是
  /// 上一周那一行的状态。若先生成本周，上一周此刻还挂着 `open`，于是"上周其实达标了"会被
  /// 当成缺口带进本周——实测过：目标 180、已记录 180 的那一周，下周仍然拿 180 分钟结转。
  Future<RecurringCycleRun> ensureCycles(TimeRange window, DateTime nowUtc) async {
    if (!nowUtc.isUtc) {
      throw ArgumentError.value(nowUtc, 'nowUtc', 'Must be UTC.');
    }
    final templates = {
      for (final template in await _repository.listTemplates())
        template.id: template,
    };
    // 窗口覆盖到的本地周（周一）列表。用日历算术逐周推进，不用 Duration。
    final periods = _periodsCovering(window);

    final settled = await _settlePastCycles(
      // **必须比窗口更早一周**：结算的对象是"已经结束的周期"，而启动窗口（滚动七天）
      // 的第一周就是**当前**那一周。只遍历窗口的话，本周一启动时上一周的实例永远不会被
      // 判定为 met / missed——`open` 会一直挂着，结转也就永远拿不到缺口。
      periods: _prependPreviousWeek(periods),
      nowUtc: nowUtc,
    );

    var createdCount = 0;
    final touchedTemplates = <String>{};
    for (final period in periods) {
      final generatable = await _repository.listGeneratableTemplates(
        period.startLocalDate,
      );
      for (final template in generatable) {
        if (template.isPausedOn(period.startLocalDate)) continue;
        final creation = await _ensureCycle(template, period, nowUtc);
        if (creation.created) createdCount++;
      }
      // 重算要遍历**全部落在这一周里的实例**，而不是只遍历刚刚生成的那一批：
      // 已经被补记过分钟的本周实例是上一次调用留下的，它同样需要按最新分钟对齐。
      touchedTemplates.addAll(
        (await _repository.listCyclesInRange(
          period.startLocalDate,
          period.startLocalDate,
        )).map((cycle) => cycle.templateId),
      );
    }

    // 本周任务按"已记录分钟"重算剩余：专注记录随时可能新增（例如刚跑完一次专注），
    // 而排程输入读的是任务的 `remainingMinutes`。
    //
    // **重算之前先定下结转**：结转会改变本周的有效目标，先算任务就会把不含结转的数字
    // 写进任务，而任务正是排程输入。
    for (final templateId in touchedTemplates) {
      final template = templates[templateId];
      if (template == null) continue;
      final cycle = await _repository.findCycle(
        templateId,
        periods.first.startLocalDate,
      );
      if (cycle == null) continue;
      final withCarry = await _applyCarryIn(template, cycle, nowUtc);
      await _syncTaskWithProgress(template, withCarry);
    }

    final cycles = <RecurringTaskCycle>[];
    for (final period in periods) {
      cycles.addAll(
        await _repository.listCyclesInRange(
          period.startLocalDate,
          period.startLocalDate,
        ),
      );
    }
    cycles.sort((a, b) {
      final byStart = a.periodStartLocalDate.compareTo(b.periodStartLocalDate);
      if (byStart != 0) return byStart;
      return a.templateId.compareTo(b.templateId);
    });

    return RecurringCycleRun(
      cycles: List.unmodifiable(cycles),
      createdCount: createdCount,
      settledCount: settled.settled,
      skippedCount: settled.skipped,
    );
  }

  /// 某个周期实例此刻的进度（路线图 §3.3）。
  Future<RecurringProgress> progressForCycle(
    String templateId,
    DateTime periodStartLocalDate,
  ) async {
    final cycle = await _repository.findCycle(templateId, periodStartLocalDate);
    if (cycle == null) {
      throw StateError(
        '周期实例不存在：$templateId @ '
        '${formatLocalDate(periodStartLocalDate)}',
      );
    }
    final period = WeeklyPeriod.startingAt(
      cycle.periodStartLocalDate,
      _timeZoneId,
      _zones,
    );
    final recorded = await _repository.recordedMinutesForTask(
      cycle.taskId,
      period.startUtc,
      period.endUtc,
    );
    final target = cycle.effectiveTargetMinutes;
    return RecurringProgress(
      templateId: cycle.templateId,
      periodStartLocalDate: cycle.periodStartLocalDate,
      targetMinutes: target,
      recordedMinutes: recorded,
      // 超额时剩余落在 0，而 `recordedMinutes` 保留真实值（§3.3："超过目标可以保留记录，
      // 但排程剩余量最低为 0"）。
      remainingMinutes: math.max(0, target - recorded),
      status: cycle.status,
      carryInMinutes: cycle.carryInMinutes,
    );
  }

  /// 跳过本周（§3.3"跳过本周"）。
  ///
  /// **只把这一周标记为 `skipped`，模板原样不动**：跳过是"这周不想做"，
  /// 归档是"以后都不做了"，两件事混起来会让用户下周发现目标不见了。
  Future<RecurringTaskCycle> skipCycle(
    String templateId,
    DateTime periodStartLocalDate,
  ) async {
    final cycle = await _repository.findCycle(templateId, periodStartLocalDate);
    if (cycle == null) {
      throw StateError(
        '周期实例不存在：$templateId @ '
        '${formatLocalDate(periodStartLocalDate)}',
      );
    }
    final updated = cycle.copyWith(
      status: RecurringCycleStatus.skipped,
      updatedAtUtc: _clock.nowUtc(),
    );
    await _repository.saveCycle(updated);
    // 跳过之后这一周不再需要安排：把任务收尾，否则它会继续占着排程输入。
    await _closeCycleTask(cycle.taskId);
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '跳过本周周期目标',
        kind: DomainChangeKind.taskSkipped,
      ),
    );
    return updated;
  }

  /// 暂停到某个本地日期（含当日）。`until` 为 `null` 表示取消暂停。
  Future<RecurringTaskTemplate> pauseTemplate(
    String templateId, {
    DateTime? until,
  }) async {
    final template = await _requireTemplate(templateId);
    final updated = template.copyWith(
      pausedUntilLocalDate: until,
      updatedAtUtc: _clock.nowUtc(),
    );
    await _repository.saveTemplate(updated);
    return updated;
  }

  /// 停止以后生成（归档）。已生成的周期与它们的任务原样保留。
  Future<RecurringTaskTemplate> stopGenerating(String templateId) async {
    final template = await _requireTemplate(templateId);
    final updated = template.copyWith(
      status: RecurringTemplateStatus.archived,
      updatedAtUtc: _clock.nowUtc(),
    );
    await _repository.saveTemplate(updated);
    return updated;
  }

  /// 恢复生成（取消归档）。
  Future<RecurringTaskTemplate> resumeGenerating(String templateId) async {
    final template = await _requireTemplate(templateId);
    final updated = template.copyWith(
      status: RecurringTemplateStatus.active,
      updatedAtUtc: _clock.nowUtc(),
    );
    await _repository.saveTemplate(updated);
    return updated;
  }

  /// 按作用范围修改模板（§3.3 最后一条）。
  ///
  /// 三个范围的差别只落在**写哪一行**，这一点是刻意的：
  /// - [RecurringEditScope.thisCycle]：只改本周实例的目标快照与它的任务，模板不动；
  /// - [RecurringEditScope.fromNextWeek]：只改模板，本周实例保持原样（用户说"从下周开始"）；
  /// - [RecurringEditScope.entireSeries]：两者一起改。
  ///
  /// **已经结算过的历史周期永远不会被改写**：三个范围都只触碰"本周"这一个实例。
  Future<RecurringTaskTemplate> updateTemplate(
    String templateId,
    RecurringTaskTemplate Function(RecurringTaskTemplate current) change, {
    RecurringEditScope scope = RecurringEditScope.entireSeries,
    DateTime? nowUtc,
  }) async {
    final current = await _requireTemplate(templateId);
    final now = nowUtc ?? _clock.nowUtc();
    final edited = change(current);
    final template = edited.copyWith(updatedAtUtc: now);
    if (scope != RecurringEditScope.thisCycle) {
      await _repository.saveTemplate(template);
    }

    if (scope == RecurringEditScope.thisCycle ||
        scope == RecurringEditScope.entireSeries) {
      final period = WeeklyPeriod.forInstant(now, _timeZoneId, _zones);
      final cycle = await _repository.findCycle(
        templateId,
        period.startLocalDate,
      );
      if (cycle != null && cycle.status == RecurringCycleStatus.open) {
        final updatedCycle = cycle.copyWith(
          baseTargetMinutes: template.targetMinutes,
          updatedAtUtc: now,
        );
        await _repository.saveCycle(updatedCycle);
        await _syncTaskWithProgress(template, updatedCycle);
      }
    }
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '周期目标设置变化',
        kind: DomainChangeKind.taskSchedulingChanged,
      ),
    );
    return template;
  }

  /// 手动补记分钟（§3.3"专注计时和手动补记都计入本周进度"）。
  ///
  /// 写的是**现有 `time_entries`**，因此它与专注计时走的是同一条汇总路径。补记之后
  /// 立刻重算周期任务的剩余时长并同步状态——否则用户补记了 80 分钟，排程器仍然按
  /// 180 分钟安排（§7.2 第二条要的正是"排程输入只剩 100 分钟"）。
  Future<RecurringProgress> recordManualMinutes(
    String templateId,
    DateTime periodStartLocalDate,
    int minutes, {
    String note = '',
  }) async {
    if (minutes <= 0) {
      throw ArgumentError.value(minutes, 'minutes', 'Must be positive.');
    }
    final cycle = await _repository.findCycle(templateId, periodStartLocalDate);
    if (cycle == null) {
      throw StateError(
        '周期实例不存在：$templateId @ '
        '${formatLocalDate(periodStartLocalDate)}',
      );
    }
    if (cycle.status == RecurringCycleStatus.skipped) {
      throw StateError('本周目标已跳过，不能再补记分钟');
    }
    final now = _clock.nowUtc();
    await _repository.recordCompletedMinutes(
      entryId: _idGenerator.next(),
      taskId: cycle.taskId,
      minutes: minutes,
      endedAtUtc: now,
      note: note,
    );
    final template = await _requireTemplate(templateId);
    await _syncTaskWithProgress(template, cycle);
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '周期目标手动补记',
        kind: DomainChangeKind.focusActualChanged,
      ),
    );
    return progressForCycle(templateId, periodStartLocalDate);
  }

  /// 「完成本周」：把达标结果落库并收尾任务。
  Future<RecurringTaskCycle> completeCycle(
    String templateId,
    DateTime periodStartLocalDate,
  ) async {
    final cycle = await _repository.findCycle(templateId, periodStartLocalDate);
    if (cycle == null) {
      throw StateError(
        '周期实例不存在：$templateId @ '
        '${formatLocalDate(periodStartLocalDate)}',
      );
    }
    final updated = cycle.copyWith(
      status: RecurringCycleStatus.met,
      updatedAtUtc: _clock.nowUtc(),
    );
    await _repository.saveCycle(updated);
    await _closeCycleTask(cycle.taskId);
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '完成本周周期目标',
        kind: DomainChangeKind.taskCompleted,
      ),
    );
    return updated;
  }

  /// 某个模板在 `nowUtc` 所属那一周的实例（不存在时为 `null`）。
  Future<RecurringTaskCycle?> currentCycle(
    String templateId,
    DateTime nowUtc,
  ) => _repository.findCycle(
    templateId,
    WeeklyPeriod.forInstant(
      nowUtc,
      _timeZoneId,
      _zones,
    ).startLocalDate,
  );

  // ── 内部 ─────────────────────────────────────────────────────────────────

  Future<RecurringTaskTemplate> _requireTemplate(String templateId) async {
    final template = await _repository.findTemplate(templateId);
    if (template == null) {
      throw StateError('周期目标模板不存在：$templateId');
    }
    return template;
  }

  /// 覆盖 `[window]` 的本地周列表（按周一去重、升序）。
  List<WeeklyPeriod> _periodsCovering(TimeRange window) {
    final first = WeeklyPeriod.forInstant(
      window.startUtc,
      _timeZoneId,
      _zones,
    );
    final periods = <WeeklyPeriod>[first];
    // 半开区间：终点那一瞬间属于下一周，因此看 `endUtc - 1µs`。
    final last = WeeklyPeriod.forInstant(
      window.endUtc.subtract(const Duration(microseconds: 1)),
      _timeZoneId,
      _zones,
    );
    var cursor = first;
    while (cursor.startLocalDate.isBefore(last.startLocalDate)) {
      cursor = cursor.next(_zones);
      periods.add(cursor);
    }
    return periods;
  }

  /// 在周列表前面接上"窗口前一周"（结算用）。
  List<WeeklyPeriod> _prependPreviousWeek(List<WeeklyPeriod> periods) {
    final previous = periods.first.previous(_zones);
    return [previous, ...periods];
  }

  Future<RecurringCycleCreation> _ensureCycle(
    RecurringTaskTemplate template,
    WeeklyPeriod period,
    DateTime nowUtc,
  ) async {
    final existing = await _repository.findCycle(
      template.id,
      period.startLocalDate,
    );
    if (existing != null) {
      // 幂等命中：**连剩余时长都不动**。这里若顺手"修一下"任务，重复启动就会反复写入
      // 同一行，恢复备份后的重跑也不再是空操作（§9 要求"重复启动不能重复生成"）。
      final task = await _readTask(existing.taskId);
      return RecurringCycleCreation(
        cycle: existing,
        task: task ?? _taskFor(template, existing, period, nowUtc),
        created: false,
      );
    }

    // 新建时结转**能确定才写**：上一周还未结算就是 0，等工作推进到本周时再由
    // `_applyCarryIn` 补上（见那里的说明）。
    final carryIn =
        await _deriveCarryIn(template, period.startLocalDate) ?? 0;
    final cycle = RecurringTaskCycle(
      templateId: template.id,
      periodStartLocalDate: period.startLocalDate,
      taskId: _taskIdFor(template.id, period.startLocalDate),
      baseTargetMinutes: template.targetMinutes,
      carryInMinutes: carryIn,
      status: RecurringCycleStatus.open,
      createdAtUtc: nowUtc,
      updatedAtUtc: nowUtc,
    );
    final task = _taskFor(template, cycle, period, nowUtc);
    final stored = await _repository.createCycleIfAbsent(
      cycle: cycle,
      task: task,
    );
    // 并发/历史路径可能让我们拿到**别人建的那一行**，此时它的 taskId 与上面算出的不同，
    // 任务内容必须以实际存在的那一行为准。
    final effectiveTask = stored.taskId == task.id
        ? task
        : (await _readTask(stored.taskId) ??
              _taskFor(template, stored, period, nowUtc));
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '生成本周周期目标',
        kind: DomainChangeKind.taskCreated,
      ),
    );
    return RecurringCycleCreation(
      cycle: stored,
      task: effectiveTask,
      created: stored.taskId == cycle.taskId,
    );
  }

  /// 上一周的缺口，按模板的"结转未完成分钟"开关决定是否带进本周。
  ///
  /// **默认关闭**（Global Constraints："周期目标默认不结转未完成分钟；上周结果保留，
  /// 新一周按原目标重新开始"）。开启时**只结转缺口**：超额的部分不倒扣（那会让下周
  /// 目标变小，用户没有要求过这种事）。
  ///
  /// **只在上一周已经定案（met / missed / skipped）后才有值。** 上一周还挂着 `open` 时
  /// 返回 `null` 表示"还判断不了"——把"未结算"当成"未达标"会把一整周的缺口提前记到本周，
  /// 而那正是本方法刻意区分 `null` 与 `0` 的原因。`0` 是"确定了，没有缺口"。
  Future<int?> _deriveCarryIn(
    RecurringTaskTemplate template,
    DateTime periodStartLocalDate,
  ) async {
    if (!template.carryOverUnfinished) return 0;
    final previousStart = shiftLocalDate(periodStartLocalDate, -7);
    final previous = await _repository.findCycle(template.id, previousStart);
    if (previous == null) return 0;
    if (previous.status == RecurringCycleStatus.open) return null;
    if (previous.status == RecurringCycleStatus.skipped ||
        previous.status == RecurringCycleStatus.met) {
      return 0;
    }
    final previousPeriod = WeeklyPeriod.startingAt(
      previousStart,
      _timeZoneId,
      _zones,
    );
    final recorded = await _repository.recordedMinutesForTask(
      previous.taskId,
      previousPeriod.startUtc,
      previousPeriod.endUtc,
    );
    // 缺口以**上一周的目标**为准：上周的目标自己可能也含结转，逐周累加才是"欠了多少"。
    return math.max(0, previous.effectiveTargetMinutes - recorded);
  }

  /// 把可以确定的结转写进这一周的实例，返回写入后的那一行。
  ///
  /// **为什么不能只在创建时算一次**：滚动七天窗口会**提前**生成下一周的实例，那一刻本周
  /// 还没结束、更没结算，于是下一周会被建成 `carryIn = 0`。等到本周真的结束，若不再回头
  /// 修正，结转就永远丢了。实测过：目标 180、已记录 80 的一周，开启结转后下一周仍然只有
  /// 180 分钟目标。
  Future<RecurringTaskCycle> _applyCarryIn(
    RecurringTaskTemplate template,
    RecurringTaskCycle cycle,
    DateTime nowUtc,
  ) async {
    // 已定案的周期（达标、跳过、已判未达标）不再改目标：那是用户看过、系统记过的结果。
    if (cycle.status != RecurringCycleStatus.open) return cycle;
    final derived = await _deriveCarryIn(template, cycle.periodStartLocalDate);
    if (derived == null || derived == cycle.carryInMinutes) return cycle;
    final updated = cycle.copyWith(
      carryInMinutes: derived,
      updatedAtUtc: nowUtc,
    );
    await _repository.saveCycle(updated);
    return updated;
  }

  /// 结算：把 `open` 的历史周期定案。
  ///
  /// 判定只用**已经发生的分钟**（`time_entries` 汇总），因此"未达标"不是一个猜测，
  /// 而是"这一周结束了、记录没到目标"。达标的那一周顺带收尾它的任务。
  Future<({int settled, int skipped})> _settlePastCycles({
    required List<WeeklyPeriod> periods,
    required DateTime nowUtc,
  }) async {
    // 当前周不结算：它还在进行中，"未达标"要到它结束才成立。
    final currentStart = WeeklyPeriod.forInstant(
      nowUtc,
      _timeZoneId,
      _zones,
    ).startLocalDate;
    var settled = 0;
    var skipped = 0;
    for (final period in periods) {
      if (!period.startLocalDate.isBefore(currentStart)) continue;
      final cycles = await _repository.listCyclesInRange(
        period.startLocalDate,
        period.startLocalDate,
      );
      for (final cycle in cycles) {
        if (cycle.status != RecurringCycleStatus.open) continue;
        final recorded = await _repository.recordedMinutesForTask(
          cycle.taskId,
          period.startUtc,
          period.endUtc,
        );
        final met = recorded >= cycle.effectiveTargetMinutes;
        await _repository.saveCycle(
          cycle.copyWith(
            status: met ? RecurringCycleStatus.met : RecurringCycleStatus.missed,
            updatedAtUtc: nowUtc,
          ),
        );
        settled++;
        if (met) {
          await _closeCycleTask(cycle.taskId);
        } else {
          skipped++;
        }
      }
    }
    return (settled: settled, skipped: skipped);
  }

  /// 让周期任务与当前进度对齐：预计时长＝有效目标，剩余＝还差多少，达标即完成任务。
  Future<void> _syncTaskWithProgress(
    RecurringTaskTemplate template,
    RecurringTaskCycle cycle,
  ) async {
    final tasks = _tasks;
    if (tasks == null) return;
    final existing = await tasks.getById(cycle.taskId);
    if (existing == null) return;
    final period = WeeklyPeriod.startingAt(
      cycle.periodStartLocalDate,
      _timeZoneId,
      _zones,
    );
    final recorded = await _repository.recordedMinutesForTask(
      cycle.taskId,
      period.startUtc,
      period.endUtc,
    );
    final target = cycle.effectiveTargetMinutes;
    final remaining = math.max(0, target - recorded);
    final met = recorded >= target;
    final completed = met || cycle.status == RecurringCycleStatus.met;
    final status = completed ? TaskStatus.completed : existing.status;
    if (existing.estimatedMinutes == target &&
        existing.remainingMinutes == remaining &&
        existing.status == status) {
      // 无变化就不写：无谓的写入会把"最近修改"推到现在，也会让幂等测试之外的
      // 每一次启动都产生一串没有意义的更新。
      return;
    }
    final now = _clock.nowUtc();
    await tasks.save(
      existing.copyWith(
        estimatedMinutes: target,
        remainingMinutes: remaining,
        status: status,
        updatedAtUtc: now,
      ),
    );
    if (met && cycle.status == RecurringCycleStatus.open) {
      await _repository.saveCycle(
        cycle.copyWith(
          status: RecurringCycleStatus.met,
          updatedAtUtc: now,
        ),
      );
    }
  }

  Future<void> _closeCycleTask(String taskId) async {
    final tasks = _tasks;
    if (tasks == null) return;
    final existing = await tasks.getById(taskId);
    if (existing == null) return;
    if (existing.status == TaskStatus.completed) return;
    await tasks.save(
      existing.copyWith(
        status: TaskStatus.completed,
        remainingMinutes: 0,
        updatedAtUtc: _clock.nowUtc(),
      ),
    );
  }

  Future<PlannerTask?> _readTask(String taskId) async => _tasks?.getById(taskId);

  /// 周期实例对应的普通任务的 id。
  ///
  /// **由 (模板, 周) 推导，而不是随机生成**：这样"两路并发生成"会算出同一个 id，
  /// 数据库层面的主键与 UNIQUE 才有机会把第二次挡下来。随机 id 会让两次并发都成功写入
  /// 任务、只在周期行上撞车，留下一个孤儿任务。
  String _taskIdFor(String templateId, DateTime periodStartLocalDate) =>
      'recurring:$templateId:${formatLocalDate(periodStartLocalDate)}';

  PlannerTask _taskFor(
    RecurringTaskTemplate template,
    RecurringTaskCycle cycle,
    WeeklyPeriod period,
    DateTime nowUtc,
  ) => PlannerTask(
    id: cycle.taskId,
    projectId: template.projectId,
    areaId: template.areaId,
    title: template.title,
    notes: template.notes,
    priority: template.priority,
    estimatedMinutes: cycle.effectiveTargetMinutes,
    remainingMinutes: cycle.effectiveTargetMinutes,
    // 截止时间＝本周结束（下周一本地 00:00）。它同时是排程器使用的"周期剩余时间"：
    // `PressureCalculator` 按"本周剩余容量 / 到截止为止的总容量"算出本周该推进多少，
    // 因此"均匀分布不会把 180 分钟全堆到周日"这件事**不需要第二个排程器**。
    dueAtUtc: period.endUtc,
    energyLevel: template.energyLevel,
    splitMode: template.splitMode,
    minChunkMinutes: template.minChunkMinutes,
    maxChunkMinutes: template.maxChunkMinutes,
    preferredWindow: template.preferredWindow,
    status: TaskStatus.open,
    createdAtUtc: nowUtc,
    updatedAtUtc: nowUtc,
  );
}
