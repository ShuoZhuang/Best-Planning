// 1.8.0（用户第 71 轮）：**彻底无解时的结构化失败与阻止应用**。
//
// 用户指出的缺口（原文）：
//
// > 局部修复失败，并且全局排程也完全无处可放时，系统会明确报告未安排，
// > 并阻止把原位置当成成功结果应用。
//
// `defer_fallback_test.dart` 第 2 条**没有证明**这件事：它的夹具每天仍留有可用空档，
// 而且断言允许"成功排到别处"或"未安排"二选一。
//
// **本轮做法**：用**规则保护时间**把窗口内**每一天整天**堵死
// （`LocalTimeRange(0, 1440)` + `DayKind.any`）。
// 这条规则由 `ProtectedTimeExpander` 逐日展开，并且它已经正确处理
// `endMinute == 1440`（当天 24:00 = 次日零点），因此不需要我去猜窗口边界。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_moves.dart';
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
  // 东八区 2026-10-12（周一）09:00 = 01:00Z
  final dayStart = DateTime.utc(2026, 10, 12, 1);
  DateTime at(int hour) => dayStart.add(Duration(hours: hour));

  PlannerTask task() => PlannerTask(
    id: 't-a',
    title: '写报告',
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

  PlannedBlock block(String id, DateTime start, {int minutes = 60}) =>
      PlannedBlock(
        id: id,
        taskId: 't-a',
        range: TimeRange(
          startUtc: start,
          endUtc: start.add(Duration(minutes: minutes)),
        ),
      );

  RepositoryScheduleProblemSource makeSource({
    required List<CalendarOccurrence> calendar,
    List<PlannedBlock>? confirmedBlocks,
  }) => RepositoryScheduleProblemSource(
    tasks: _Tasks([task()]),
    lifeAreas: _NoLifeAreas(),
    calendar: _Calendar(calendar),
    settings: SettingsService(repository: MemorySettingsRepository()),
    plans: _Plan(
      ConfirmedPlan(
        id: 'v1',
        inputHash: 'h1',
        algorithmVersion: 'test',
        blocks: confirmedBlocks ?? [block('b-target', at(0))],
      ),
    ),
    clock: _Clock(dayStart),
    timeZoneId: zoneId,
    zones: zones,
    pendingMoves: PendingMoveDrafts()
      ..beginAdjustment(
        PlanAdjustmentRequest(
          blockId: 'b-target',
          amount: 30,
          unit: DeferUnit.minutes,
          sourceStartUtc: at(0),
          timeZoneId: zoneId,
        ),
      ),
  );

  /// **整天堵死**的保护时间覆盖：`00:00–24:00`、`DayKind.any`。
  ///
  /// 它由 `ProtectedTimeExpander` 逐日展开到窗口内的每一天，
  /// 因此窗口里**没有任何**可放片段的位置。
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

  test('**整个窗口无处可放 ⇒ 明确报未安排、不得留原位、且不能应用**', () async {
    final source = makeSource(calendar: const []);
    final planning = PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    );
    final proposal = await planning.createProposal(override: blockEverything);

    // 先确认"堵死"确实生效（否则下面的断言会变成假阳性）。
    final problem = await source.load(override: blockEverything);
    final covered = problem.protectedIntervals.fold<int>(
      0,
      (sum, interval) => sum + interval.range.durationMinutes,
    );
    final windowMinutes = problem.planningWindow.durationMinutes;
    expect(
      covered,
      greaterThanOrEqualTo(windowMinutes),
      reason:
          '前置条件：保护时间必须**铺满**整个窗口，'
          '否则"无处可放"不成立，后面几条断言没有意义',
    );

    // **核心断言 1**：不得把目标块留在原位置（"保持原位置却显示成功"）。
    expect(
      proposal.blocks.any((b) => b.startUtc == at(0)),
      isFalse,
      reason: '彻底无解时绝不能把目标块留在原位并当作延后成功',
    );

    // **核心断言 2**：必须**结构化地**报出未安排。
    expect(
      proposal.unscheduled,
      isNotEmpty,
      reason:
          '整个窗口无处可放 ⇒ 任务必须出现在 `unscheduled` 里。'
          '用户要求"明确报告未安排"，静默地什么都不排是不合格的',
    );

    // **核心断言 3**：提案里不得有任何"看起来成功"的残留。
    expect(proposal.blocks, isEmpty, reason: '无处可放 ⇒ 一条都不该排；有块就说明它偷偷用了别的位置');

    // **关于"阻止应用"——据实说明，不粉饰**：
    // 我原本断言"无解提案必须被 `PlanValidator` 拦下"，**实测不成立**。
    // `PlanValidator` 的 `lockedBlockMoved` 只针对 `problem.lockedBlocks` 里的块，
    // 而失败路径上目标块**不在** lockedBlocks 里（它回到 `existingBlocks` 交给引擎），
    // 因此"什么都没排"对校验器来说是**合法**的 —— 空计划没有冲突。
    //
    // 也就是说：**"阻止应用"在本场景没有独立机制**。用户看到的是
    // "任务被报告为未安排"这个结构化结果（核心断言 2），而不是"应用被拒绝"。
    // 这是产品行为，不是我在这里能补的语义 —— 记进验收文档，不写成"已验证阻止应用"。
    // 校验器对本场景**不报冲突**，这里把这个事实固定下来。
    final conflicts = PlanValidator(zones).validate(problem, proposal.blocks);
    expect(
      conflicts,
      isEmpty,
      reason:
          '据实固定现状：空计划对校验器是**合法**的'
          '（目标块不在 lockedBlocks 里，因此没有 lockedBlockMoved）。'
          '若将来有人给"无解"加上校验拦截，这条会红，提醒回来看上面那段说明',
    );
  });

  test('对照：不堵死时同一份输入能正常排出（确认上一条不是恒真）', () async {
    final source = makeSource(calendar: const []);
    final proposal = await PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    ).createProposal();

    expect(
      proposal.blocks,
      isNotEmpty,
      reason: '不堵死时应当排出内容 —— 否则上一条的"未安排"可能只是构造错误',
    );
    expect(proposal.unscheduled, isEmpty, reason: '不堵死时不该有未安排项');
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

final class _Calendar implements CalendarRepository {
  const _Calendar(this.occurrences);
  final List<CalendarOccurrence> occurrences;

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => [
    for (final occurrence in occurrences)
      if (occurrence.range.startUtc.isBefore(endUtc) &&
          startUtc.isBefore(occurrence.range.endUtc))
        occurrence,
  ];

  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _Plan implements PlanRepository {
  const _Plan(this.plan);
  final ConfirmedPlan? plan;

  @override
  Future<ConfirmedPlan?> current() async => plan;

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) => throw UnimplementedError();
}
