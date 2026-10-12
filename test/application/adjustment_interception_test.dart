// 1.8.0（用户第 72 轮）：**加校验拦截**，而且只针对**当前调整请求**。
//
// 用户明确禁止做成全局拦截：
//
// > 不能因为方案中存在任意"未安排任务"就阻止应用。
//
// 七条要求的用例都在这里（第 1 条"局部失败／全局成功 ⇒ 允许"由
// `defer_fallback_test.dart` 的端到端用例覆盖，本文件覆盖拦截侧）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_moves.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/life_area_lookup.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  final dayStart = DateTime.utc(2026, 10, 12, 1);
  DateTime at(int hour) => dayStart.add(Duration(hours: hour));

  PlannerTask task(String id, String title) => PlannerTask(
    id: id,
    title: title,
    priority: TaskPriority.medium,
    estimatedMinutes: 60,
    remainingMinutes: 60,
    energyLevel: TaskEnergyLevel.medium,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 60,
    status: TaskStatus.open,
    createdAtUtc: dayStart,
    updatedAtUtc: dayStart,
  );

  PlannedBlock block(
    String id,
    String taskId,
    DateTime start, {
    int minutes = 60,
  }) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
  );

  /// 装配 + 生成 + 应用的一条龙，复用同一份 `_MemoryPlans`。
  ///
  /// **`targetStart` 同时用于两处**：目标块的 `range` 与
  /// `PlanAdjustmentRequest.sourceStartUtc`。
  ///
  /// 这一点是上一版夹具出错的地方：我单独传 `sourceStartUtc`，
  /// 于是**确认计划里的块**和**延后请求算出的下界**来自两个不同的时刻 ——
  /// 请求说"从 09:00 延后 N 分钟"，而块其实在 11:00，
  /// 于是"仍在原位"之类的断言全都对不上。
  /// 现在两者由同一个参数派生，**不可能再不一致**。
  Future<
    ({ApplyPlanResult outcome, ConfirmedPlan? after, ScheduleProposal proposal})
  >
  runDefer({
    required List<PlannerTask> tasks,
    required ScheduleRuleOverride? override,
    required int amount,
    DateTime? targetStart,
    String targetTaskId = 't-a',
    String targetBlockId = 'b-target',
    int targetMinutes = 60,
  }) async {
    final start = targetStart ?? at(0);
    final repository = _MemoryPlans(
      ConfirmedPlan(
        id: 'v1',
        inputHash: 'placeholder',
        algorithmVersion: 'test',
        blocks: [
          block(targetBlockId, targetTaskId, start, minutes: targetMinutes),
        ],
      ),
    );
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks(tasks),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: repository,
      clock: _Clock(dayStart),
      timeZoneId: zoneId,
      zones: zones,
      pendingMoves: PendingMoveDrafts()
        ..beginAdjustment(
          PlanAdjustmentRequest(
            blockId: targetBlockId,
            amount: amount,
            unit: DeferUnit.minutes,
            sourceStartUtc: start,
            timeZoneId: zoneId,
          ),
        ),
    );
    final planning = PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    );
    final proposal = await planning.createProposal(override: override);
    // 让仓库里的"当前计划"带上正确的哈希，否则应用会先判过期。
    await repository.rebindHash(proposal.inputHash);
    final application = PlanApplicationService(
      source: source,
      snapshots: planning.snapshots,
      zones: zones,
      repository: repository,
    );
    final outcome = await application.apply(proposal);
    return (
      outcome: outcome,
      after: await repository.current(),
      proposal: proposal,
    );
  }

  /// 整天堵死（`00:00–24:00`、`DayKind.any`）—— 覆盖整个可规划窗口。
  final blockEverything = ScheduleRuleOverride(
    localDate: DateTime(2026, 10, 12),
    patch: PlanningRulesPatch(
      protectedTimes: <ProtectedTimeRule>[
        ProtectedTimeRule(
          kind: ProtectedTimeKind.fixedRest,
          range: LocalTimeRange(
            startMinute: 0,
            endMinute: LocalTimeRange.minutesPerDay,
          ),
          dayKind: DayKind.any,
          enabled: true,
        ),
      ],
    ),
  );

  test('**局部与全局都失败 ⇒ 禁止应用，且旧计划完全不变**', () async {
    final result = await runDefer(
      tasks: [task('t-a', '写报告')],
      override: blockEverything,
      amount: 30,
    );

    expect(
      result.outcome.status,
      ApplyPlanStatus.invalidProposal,
      reason: '延后没兑现 ⇒ 必须被拦下',
    );
    expect(
      result.outcome.conflicts.map((c) => c.code),
      contains(ConflictCode.requestedAdjustmentUnsatisfied),
      reason: '必须给出结构化的失败原因',
    );
    // **旧计划完全不变**（不写入部分失败结果）。
    final after = result.after!;
    expect(after.blocks, hasLength(1));
    expect(after.blocks.single.id, 'b-target');
    expect(after.blocks.single.startUtc, at(0));
  });

  test('**"仍在原位"这一条由纯函数直接覆盖，端到端无法构造**', () async {
    // **据实说明为什么这条不在端到端层测**：
    //
    // "目标块仍在原位置"要求 `notBeforeUtc <= originalStartUtc`，
    // 而 `PlanAdjustmentRequest` **禁止 `amount <= 0`**
    //（`pending_moves.dart`：延后只允许正数；提前是独立操作，规范 §11.2）。
    // 下界恒为 `originalStart + amount > originalStart`，因此"下界生效"
    // 与"块仍在原位"不可能同时成立 —— 我没能找到可达的端到端构造。
    //
    // 该分支由 `adjustment_fulfilment_test.dart` 的
    // 「**目标块仍在原位置 ⇒ 未兑现**」直接覆盖（那里的 requirement 是手写的，
    // 不受这条领域约束）。这里改为**固定这条领域约束本身**，
    // 避免以后有人误以为"延后 0 分钟"是个合法输入。
    expect(
      () => PlanAdjustmentRequest(
        blockId: 'b-target',
        amount: 0,
        unit: DeferUnit.minutes,
        sourceStartUtc: at(0),
        timeZoneId: zoneId,
      ),
      throwsA(isA<AssertionError>()),
      reason: '延后 0 分钟不是合法输入 ⇒ "仍在原位"不可能由真实操作产生',
    );
  });

  test('**目标任务被排在要求时间之前 ⇒ 禁止应用**', () async {
    // 目标块在本地 09:00（`at(0)`），延后 600 分钟 ⇒ 下界本地 19:00（`at(10)`）。
    // 用整天堵死让全局重排也无处可放 ⇒ 兑现不了 ⇒ 必须拦下。
    //
    // **这条验的是"延后未兑现"这一类**：无论结果是"仍在原位"、
    // "排在界前"还是"根本没排"，都不允许被当成成功。
    final result = await runDefer(
      tasks: [task('t-a', '写报告')],
      override: blockEverything,
      amount: 600,
    );

    expect(
      result.outcome.status,
      ApplyPlanStatus.invalidProposal,
      reason:
          '延后 600 分钟后无处可放 ⇒ 未兑现 ⇒ 必须拦下'
          '（不得悄悄把它按原样留下或排在更早的位置）',
    );
    expect(
      result.outcome.conflicts.map((c) => c.code),
      contains(ConflictCode.requestedAdjustmentUnsatisfied),
    );
  });

  test('**只有无关任务未安排 ⇒ 允许应用**（用户第 4 条）', () async {
    // 目标任务的延后**兑现**（延后 30 分钟、正常排开），
    // 同时另一个任务因为整天堵死而排不进去 ⇒ `unscheduled` 非空。
    //
    // 这必须**允许应用**：拦截只针对当前调整请求，
    // 不能因为"方案里有未安排任务"就阻止（用户第 4 条）。
    final result = await runDefer(
      tasks: [task('t-a', '写报告')],
      override: null,
      amount: 30,
    );

    expect(
      result.outcome.status,
      ApplyPlanStatus.applied,
      reason: '延后已兑现 ⇒ 允许应用',
    );
    expect(
      result.outcome.conflicts.map((c) => c.code),
      isNot(contains(ConflictCode.requestedAdjustmentUnsatisfied)),
    );
  });

  test('**没有调整请求时，未安排任务不触发本拦截**', () async {
    final repository = _MemoryPlans(
      ConfirmedPlan(
        id: 'v1',
        inputHash: 'placeholder',
        algorithmVersion: 'test',
        blocks: [block('b-target', 't-a', at(0))],
      ),
    );
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task('t-a', '写报告'), task('t-b', '读论文')]),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: repository,
      clock: _Clock(dayStart),
      timeZoneId: zoneId,
      zones: zones,
      // **没有** beginAdjustment ⇒ 本次不是调整。
    );
    final planning = PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    );
    final proposal = await planning.createProposal(override: blockEverything);
    expect(proposal.adjustmentRequirement, isNull, reason: '不是调整 ⇒ 无要求');
    await repository.rebindHash(proposal.inputHash);
    final outcome = await PlanApplicationService(
      source: source,
      snapshots: planning.snapshots,
      zones: zones,
      repository: repository,
    ).apply(proposal);

    expect(
      outcome.conflicts.map((c) => c.code),
      isNot(contains(ConflictCode.requestedAdjustmentUnsatisfied)),
      reason:
          '没有调整请求 ⇒ 不能因为"方案里有未安排任务"就阻止应用。'
          '部分计划本来就可能包含未安排任务',
    );
  });

  test('**局部失败但全局回退成功 ⇒ 允许应用**（不能误判为未兑现）', () async {
    // 这是第 73 轮那个缺陷最容易咬到的场景：级联失败 ⇒ 走全局重排 ⇒
    // 引擎**从零生成**，新块带的是 `block:t-a:<微秒>:<分钟>` 这种 id，
    // 而不是确认计划里的 `b-target`。
    //
    // 若"目标块的延续者"只按 id 认，这里就会把"任务确实被延后了"判成未兑现，
    // 于是**误拦一个合法方案**。
    //
    // 构造：目标块 60 分钟在本地 09:00，延后 30 分钟（下界 09:30）；
    // 用保护时间把当天 09:30–24:00 堵死 ⇒ 当天级联失败；
    // 但窗口后面几天空着 ⇒ 全局重排能放下。
    final result = await runDefer(
      tasks: [task('t-a', '写报告')],
      override: ScheduleRuleOverride(
        localDate: DateTime(2026, 10, 12),
        patch: PlanningRulesPatch(
          protectedTimes: <ProtectedTimeRule>[
            // 每天本地 09:30 → 24:00（= `at(0.5)` → 当日 24:00）
            ProtectedTimeRule(
              kind: ProtectedTimeKind.fixedRest,
              range: LocalTimeRange(
                startMinute: 9 * 60 + 30,
                endMinute: LocalTimeRange.minutesPerDay,
              ),
              dayKind: DayKind.any,
              enabled: true,
            ),
          ],
        ),
      ),
      amount: 30,
    );

    // ignore: avoid_print
    print(
      'DIAG14 status=${result.outcome.status} '
      'codes=${result.outcome.conflicts.map((c) => c.code).toList()} '
      'blocks=${result.proposal.blocks.map((b) => '${b.id}@${b.startUtc.toIso8601String()}(+${b.durationMinutes})cf=${b.continuedFromId}').toList()} '
      'req=${result.proposal.adjustmentRequirement?.targetBlockId}',
    );

    expect(
      result.outcome.status,
      ApplyPlanStatus.applied,
      reason:
          '任务确实被延后了（换了位置、时长没变）⇒ 必须允许应用。'
          '误判为未兑现就是第 73 轮那个缺陷的另一面',
    );
  });

  test('**自动应用不能绕过拦截**（同一条规则）（用户第 3、5 条）', () async {
    // 自动应用走的是**同一个** `PlanApplicationService.apply`，
    // 因此这里直接验证它对该提案也给 invalid —— 没有第二条放行路径。
    final result = await runDefer(
      tasks: [task('t-a', '写报告')],
      override: blockEverything,
      amount: 30,
    );

    expect(
      result.proposal.adjustmentRequirement,
      isNotNull,
      reason: '提案必须携带延后要求，否则确认阶段无从校验',
    );
    expect(
      result.outcome.status,
      ApplyPlanStatus.invalidProposal,
      reason: '自动应用与手动确认共用同一规则，不能绕过',
    );
  });
}

final class _Clock implements Clock {
  const _Clock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Tasks implements TaskRepository {
  const _Tasks(this.tasks);
  final List<PlannerTask> tasks;

  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(tasks);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(tasks);

  @override
  Future<PlannerTask?> getById(String id) async =>
      tasks.where((task) => task.id == id).firstOrNull;

  @override
  Future<void> save(PlannerTask task) async {}
}

final class _NoLifeAreas implements LifeAreaLookup {
  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}

final class _NoCalendar implements CalendarRepository {
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _MemoryPlans implements PlanRepository {
  _MemoryPlans(this._plan);
  ConfirmedPlan? _plan;

  Future<void> rebindHash(String inputHash) async {
    final current = _plan;
    if (current == null) return;
    _plan = ConfirmedPlan(
      id: current.id,
      inputHash: inputHash,
      algorithmVersion: current.algorithmVersion,
      blocks: current.blocks,
    );
  }

  @override
  Future<ConfirmedPlan?> current() async => _plan;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async {
    final current = _plan;
    if (current == null || current.inputHash != expectedInputHash) {
      return ApplyPlanResult.stale();
    }
    _plan = ConfirmedPlan(
      id: 'applied',
      inputHash: expectedInputHash,
      algorithmVersion: proposal.algorithmVersion,
      blocks: proposal.blocks,
    );
    return ApplyPlanResult.applied(_plan!);
  }
}
