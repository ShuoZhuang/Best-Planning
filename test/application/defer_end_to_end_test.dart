// 1.8.0（裁定第 3、4 点；设计 §5.4）：延后在**真实生产路径**上真的生效。
//
// 前面三个文件各自验了一层：
//   · `block_level_defer_test.dart`   —— 装配层产出块级上下文；
//   · `defer_block_scope_test.dart`   —— 任务级可用起点不被改动；
//   · `engine_block_adjustment_test.dart` —— 引擎尊重交给它的位置。
//
// **但它们都没有验证"端到端真的动了"**。本文件补这一层：
// 真的 `RepositoryScheduleProblemSource`（带 `pendingMoves`）→ 真的 `PlanningService`
// → 真的 `DeterministicScheduleEngine`，然后看提案。
//
// 这一层必须存在：本批次已经出现过多次"函数对、接线空"的缺陷
// （`localRepairCascade` 生产零调用就是其中之一）。分层用例各自通过，
// 拼起来不成立——**只有端到端用例能发现这件事**。
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
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  const zoneId = 'UTC';
  final zones = TimeZoneDatabase();
  final day = DateTime.utc(2026, 10, 12);
  DateTime at(int hour) => day.add(Duration(hours: hour));

  /// 一个任务、两块：09:00–10:00 与 20:00–21:00。
  PlannerTask task() => PlannerTask(
    id: 't-a',
    title: '写报告',
    priority: TaskPriority.medium,
    estimatedMinutes: 120,
    remainingMinutes: 120,
    energyLevel: TaskEnergyLevel.medium,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 60,
    maxChunkMinutes: 60,
    status: TaskStatus.open,
    createdAtUtc: day,
    updatedAtUtc: day,
  );

  PlannedBlock block(String id, int hour) => PlannedBlock(
    id: id,
    taskId: 't-a',
    range: TimeRange(startUtc: at(hour), endUtc: at(hour + 1)),
  );

  final confirmed = ConfirmedPlan(
    id: 'v1',
    inputHash: 'h1',
    algorithmVersion: 'test',
    blocks: [block('b-morning', 9), block('b-evening', 20)],
  );

  Future<ScheduleProposal> generate({PendingMoveDrafts? pendingMoves}) {
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(confirmed),
      clock: _Clock(day),
      timeZoneId: zoneId,
      zones: zones,
      pendingMoves: pendingMoves,
    );
    return PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    ).createProposal();
  }

  PendingMoveDrafts deferring(String blockId, int amount) =>
      PendingMoveDrafts()..beginAdjustment(
        PlanAdjustmentRequest(
          blockId: blockId,
          amount: amount,
          unit: DeferUnit.minutes,
          sourceStartUtc: at(9),
          timeZoneId: zoneId,
        ),
      );

  test('**延后 90 分钟后，目标块落在下界之后**（端到端）', () async {
    final proposal = await generate(pendingMoves: deferring('b-morning', 90));

    final target = proposal.blocks
        .where((x) => x.id == 'b-morning')
        .firstOrNull;
    expect(target, isNotNull, reason: '被延后的块必须出现在提案里（它仍属于这次计划）');
    expect(
      target!.startUtc.isBefore(at(10).add(const Duration(minutes: 30))),
      isFalse,
      reason: '目标块不得早于下界 = 09:00 + 90 分钟',
    );
  });

  test('**同一任务的另一块不被牵连**（裁定第 3 点的端到端确认）', () async {
    // **按时刻比较，不按 id、也不假设引擎会保留确认计划里的位置**。
    //
    // 实测（见下方断言）：不延后时引擎排出 `09:00` 与 `13:30` 两块；
    // 它**不会**把确认计划里的 `20:00` 当成必须保留的落点——引擎是"从零生成"，
    // 只保证任务总时长与硬约束。因此"另一块有没有被牵连"要问的是
    // **除目标块之外的落点变没变**。
    //
    // 修复前延后是**任务级**的：下界被并进 `availableFromUtc`，
    // 于是同任务的每一块都被推到 09:00+90 分钟之后，13:30 那一块会被挪走。
    // 现在延后是块级的，13:30 保持不动——这条用例正是为此而存在。
    final before = await generate();
    final after = await generate(pendingMoves: deferring('b-morning', 90));

    Set<String> nonTargetSlots(ScheduleProposal p) => {
      for (final block in p.blocks)
        if (block.startUtc !=
            p.blocks.firstWhere((x) => x.id == 'b-morning').startUtc)
          block.startUtc.toIso8601String(),
    };

    final targetStart = after.blocks
        .firstWhere((x) => x.id == 'b-morning')
        .startUtc;
    expect(
      targetStart.isBefore(at(10).add(const Duration(minutes: 30))),
      isFalse,
      reason: '目标块不得早于下界 = 09:00 + 90 分钟',
    );

    final beforeOthers = {
      for (final block in before.blocks)
        if (block.startUtc != at(9)) block.startUtc.toIso8601String(),
    };
    final afterOthers = {
      for (final block in after.blocks)
        if (block.startUtc != targetStart) block.startUtc.toIso8601String(),
    };

    expect(
      afterOthers,
      beforeOthers,
      reason:
          '除目标块之外，其余落点必须逐值不变：'
          '延后**只调整当前计划块**（规范 §11.1）。'
          '修复前延后是任务级的，其余块会被一起推后——那时这条会红',
    );
    expect(
      nonTargetSlots(after),
      isNotEmpty,
      reason: '前置条件：这次生成里除了目标块还有别的块，否则本条验不到东西',
    );
  });

  test('提案里没有重复的块 id（同一件工作不会被排两次）', () async {
    final proposal = await generate(pendingMoves: deferring('b-morning', 90));

    final ids = proposal.blocks.map((x) => x.id).toList();
    expect(ids.toSet(), hasLength(ids.length), reason: '级联结果与引擎自己的放置不得同时出现同一块');
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
