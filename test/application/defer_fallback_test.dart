// 1.8.0（用户第 68 轮）：**回退路径的正确性**。
//
// 用户定的验收标准（原文）：
//
// > 局部修复失败后，要么通过全局排程真正完成延后，要么明确失败并阻止应用，
// > 绝不能保持原位置却显示成功。
//
// 这是本轮缺陷修复的**阻断项**。
//
// **为什么必须单独测**：常规延后用例只覆盖"级联成功"那条路径。
// 级联失败时 `adjustedTarget == null`，冻结分支不会执行，
// 但**引擎也不知道延后下界** —— `ScheduleProblem` 里此前只有
// `BlockAdjustmentContext.notBeforeUtc` 这一个字段记录它，而**引擎不读它**
// （装配层才是消费者）。于是可能出现"目标块留在原位、用户以为延后成功了"。
//
// 本文件先把**契约**钉住，再看代码是否满足。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_moves.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
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

  /// 可拆分成 30 分钟片段的 60 分钟任务。
  PlannerTask task() => PlannerTask(
    id: 't-a',
    title: '写报告',
    priority: TaskPriority.medium,
    estimatedMinutes: 60,
    remainingMinutes: 60,
    energyLevel: TaskEnergyLevel.medium,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    // 允许 30 与 60 两种片段：确认块是 60 分钟，而回退时希望引擎能拆成两个 30 分钟。
    maxChunkMinutes: 60,
    status: TaskStatus.open,
    createdAtUtc: dayStart,
    updatedAtUtc: dayStart,
  );

  PlannedBlock block(
    String id,
    DateTime start, {
    int minutes = 60,
    bool locked = false,
  }) => PlannedBlock(
    id: id,
    taskId: 't-a',
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
    locked: locked,
  );

  CalendarOccurrence protectedTime(
    String id,
    DateTime start, {
    int minutes = 60,
  }) => CalendarOccurrence(
    eventId: id,
    title: '保护时间',
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
    locked: true,
    kind: CalendarEventKind.protected,
  );

  Future<({ScheduleProposal proposal, ScheduleProblem problem})> run({
    required List<PlannedBlock> confirmedBlocks,
    required List<CalendarOccurrence> calendar,
    required int amount,
    required DateTime sourceStartUtc,
  }) async {
    final confirmed = ConfirmedPlan(
      id: 'v1',
      inputHash: 'h1',
      algorithmVersion: 'test',
      blocks: confirmedBlocks,
    );
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: _NoLifeAreas(),
      calendar: _Calendar(calendar),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(confirmed),
      clock: _Clock(dayStart),
      timeZoneId: zoneId,
      zones: zones,
      pendingMoves: PendingMoveDrafts()
        ..beginAdjustment(
          PlanAdjustmentRequest(
            blockId: 'b-target',
            amount: amount,
            unit: DeferUnit.minutes,
            sourceStartUtc: sourceStartUtc,
            timeZoneId: zoneId,
          ),
        ),
    );
    final proposal = await PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    ).createProposal();
    final problem = await source.load();
    return (proposal: proposal, problem: problem);
  }

  test('**1. 局部修复失败但全局回退成功**：延后仍然真的发生', () async {
    // 目标块 60 分钟在本地 09:00（`at(0)`）；延后 30 分钟 ⇒ 下界本地 09:30（`at(0.5)`）。
    //
    // 把下界之后的**连续 60 分钟全部堵死**，但留出**两段独立的 30 分钟**：
    //   · 保护时间 09:30–13:00（`at(0.5)`→`at(4)`）
    //   · 保护时间 13:30–23:00（`at(4.5)`→`at(14)`）
    //   ⇒ 可用的完整空档是 13:00–13:30（30 分钟）与 23:00 之后（30 分钟）。
    //
    // 级联要求"目标块**整体**落在不早于下界的位置"，**连续 60 分钟放不下** ⇒ 当天失败；
    // 但任务允许拆分 ⇒ 引擎可以排成两个 30 分钟片段。
    final result = await run(
      confirmedBlocks: [block('b-target', at(0))],
      calendar: [
        protectedTime(
          'p1',
          at(0).add(const Duration(minutes: 30)),
          minutes: 210,
        ),
        protectedTime(
          'p2',
          at(4).add(const Duration(minutes: 30)),
          minutes: 570,
        ),
      ],
      amount: 30,
      sourceStartUtc: at(0),
    );
    final proposal = result.proposal;
    final bound = at(0).add(const Duration(minutes: 30));

    // ① 原时间的目标块不再出现。
    expect(
      proposal.blocks.any((b) => b.startUtc == at(0)),
      isFalse,
      reason: '延后之后，原时间（09:00）不该还有这个任务的块',
    );
    // ② 新块全部不早于延后下界。
    for (final b in proposal.blocks) {
      expect(
        b.startUtc.isBefore(bound),
        isFalse,
        reason: '回退路径也必须尊重延后下界（不能"回到原位假装成功"）',
      );
    }
    // ③ 总安排时长仍为 60 分钟。
    final total = proposal.blocks.fold<int>(
      0,
      (sum, b) => sum + b.durationMinutes,
    );
    expect(total, 60, reason: '延后不改变任务总时长');
    // ④ 提案通过校验。
    final conflicts = PlanValidator(zones)
        .validate(result.problem, proposal.blocks);
    // ignore: avoid_print
    print(
      'DIAG8 window=${result.problem.planningWindow.startUtc.toIso8601String()}→'
      '${result.problem.planningWindow.endUtc.toIso8601String()} '
      'tasks=${result.problem.tasks.map((t) => t.id).toList()} '
      'conflicts=${conflicts.map((c) => c.code).toList()} '
      'blocks=${proposal.blocks.map((b) => '${b.id}/${b.taskId}@${b.startUtc.toIso8601String()}(+${b.durationMinutes})').toList()}',
    );
    expect(conflicts, isEmpty, reason: '提案不得含冲突');
    // ⑤ 所有块 ID 唯一。
    expect(
      proposal.blocks.map((b) => b.id).toSet().length,
      proposal.blocks.length,
    );
  });

  test('**2. 回退路径绝不静默保持原位置**（用户定的红线）', () async {
    // 用户定的验收红线（原文）：
    //
    // > 局部修复失败后，要么通过全局排程真正完成延后，要么明确失败并阻止应用，
    // > 绝不能保持原位置却显示成功。
    //
    // 本用例把整天的清醒时段堵死，于是**级联当天必然失败** ⇒ 走回退路径。
    // 回退路径上只要求两件事（越界的两种情况都要被挡住）：
    //   · 不能把目标块留在原位（那就是"保持原位置却显示成功"）；
    //   · 落点不能早于延后下界（那就是没执行延后）。
    // 至于是"真的排到别处"还是"结构化地报未安排"，两者都合法 —— 因此这里不写死。
    //
    // **据实说明**：我原本还断言"必须出现未安排或冲突"，但实测该断言**不成立**：
    // 规划窗口是 7 天，只要窗口内还有任何可放位置，引擎就会把任务排在那里
    // （实测落点 `2026-10-12T23:30:00.000Z`，`unscheduled=0`、`conflicts=[]`）——
    // 这是**合法结果**，不是缺陷。要让"必须失败"成立，得把整个 7 天窗口堵死，
    // 而窗口起点/终点的精确边界会把这类夹具做得很脆。
    // 因此这条改为只钉用户真正关心的红线。
    final fullDayBlocks = [
      for (var day = 0; day < 8; day++)
        protectedTime(
          'block-day-$day',
          dayStart.add(Duration(days: day)),
          minutes: 14 * 60,
        ),
    ];

    final result = await run(
      confirmedBlocks: [block('b-target', at(0))],
      calendar: fullDayBlocks,
      amount: 30,
      sourceStartUtc: at(0),
    );
    final proposal = result.proposal;
    final bound = at(0).add(const Duration(minutes: 30));

    // **核心断言 1**：不得把目标块留在原位置并伪装成延后成功。
    expect(
      proposal.blocks.any((b) => b.startUtc == at(0)),
      isFalse,
      reason:
          '延后失败时，目标块**不得**留在原位置。'
          '留在原位就是"保持原位置却显示成功"——用户明确禁止的那种结果',
    );
    // **核心断言 2**：任何被排进去的块都必须不早于延后下界。
    for (final b in proposal.blocks) {
      expect(
        b.startUtc.isBefore(bound),
        isFalse,
        reason: '回退路径（或失败结果）都不能把块放在延后下界之前',
      );
    }
    // **核心断言 3**：总时长不丢（要么排到别处、要么结构化地报未安排）。
    final total = proposal.blocks.fold<int>(
      0,
      (sum, b) => sum + b.durationMinutes,
    );
    expect(
      total == 60 || proposal.unscheduled.isNotEmpty,
      isTrue,
      reason:
          '回退路径不能把 60 分钟的任务弄丢：'
          '要么 60 分钟都在，要么明确报未安排',
    );
    // 所有块 ID 唯一。
    expect(
      proposal.blocks.map((b) => b.id).toSet().length,
      proposal.blocks.length,
    );
  });

  test('**3. 回退后的块集合互斥**（锁定 / 未受影响 / 被挤开 / 目标）', () async {
    // 同时放入四类块，断言 ID 唯一。
    final result = await run(
      confirmedBlocks: [
        block('b-target', at(0), minutes: 60),
        block('b-locked', at(6), minutes: 60, locked: true),
        block('b-plain', at(12), minutes: 60),
        block('b-squeezed', at(1), minutes: 30),
      ],
      calendar: [
        protectedTime(
          'p1',
          at(0).add(const Duration(minutes: 30)),
          minutes: 500,
        ),
      ],
      amount: 30,
      sourceStartUtc: at(0),
    );

    expect(
      result.proposal.blocks.map((b) => b.id).toSet().length,
      result.proposal.blocks.length,
      reason: '五类块必须按 ID 互斥：同一块不得出现两次',
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
