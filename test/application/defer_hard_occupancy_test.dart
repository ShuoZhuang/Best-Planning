// 1.8.0（规范 §11.1／§11.4；用户第 65 轮复核）：
// 调整路径必须使用**统一的硬占用区间**，并且**只移动真正挡路的块**。
//
// 复核指出的两处（本文件先钉这两条）：
//
// 1. **真正锁定的块被当成可移动**：生产接线把 `confirmedBlocks` 里所有可排任务块
//    都交给级联，只排除了 `skippedBlockIds` 与 `pinnedByBlockId`，
//    **没有排除 `block.locked`**。而 `localRepairCascade` 只把 `immovable` 参数里的块
//    当作不可移动 —— 于是锁定块会被搬走（甚至与原位置形成重复）。
// 2. **已经过去的块没有冻结**：它们仍参与级联，可能被搬动。
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
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  // 东八区 2026-10-12（周一）09:00 = 01:00Z
  final dayStart = DateTime.utc(2026, 10, 12, 1);
  DateTime at(int hour) => dayStart.add(Duration(hours: hour));

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
    createdAtUtc: dayStart,
    updatedAtUtc: dayStart,
  );

  PlannedBlock block(
    String id,
    int hour, {
    int minutes = 60,
    bool locked = false,
  }) => PlannedBlock(
    id: id,
    taskId: 't-a',
    range: TimeRange(
      startUtc: at(hour),
      endUtc: at(hour).add(Duration(minutes: minutes)),
    ),
    locked: locked,
  );

  Future<ScheduleProposal> defer({
    required List<PlannedBlock> confirmedBlocks,
    int amount = 30,
    DateTime? nowUtc,
  }) {
    final confirmed = ConfirmedPlan(
      id: 'v1',
      inputHash: 'h1',
      algorithmVersion: 'test',
      blocks: confirmedBlocks,
    );
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(confirmed),
      clock: _Clock(nowUtc ?? dayStart),
      timeZoneId: zoneId,
      zones: zones,
      pendingMoves: PendingMoveDrafts()
        ..beginAdjustment(
          PlanAdjustmentRequest(
            blockId: 'b-target',
            amount: amount,
            unit: DeferUnit.minutes,
            sourceStartUtc: at(0),
            timeZoneId: zoneId,
          ),
        ),
    );
    return PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    ).createProposal();
  }

  test('**真正锁定的块不被搬动**（`locked` 必须是硬占用）', () {
    // 构造：目标块 09:00（本地）延后 60 分钟 ⇒ 下界 10:00，正好落在锁定块
    // 09:30–10:30 上。级联若把锁定块当可移动，就会把它推走以给目标让路。
    final confirmedBlocks = [
      block('b-target', 0),
      block('b-locked', 0, minutes: 60, locked: true),
    ];

    return defer(confirmedBlocks: confirmedBlocks, amount: 60).then((proposal) {
      // ignore: avoid_print
      print(
        'DIAG6 all=${proposal.blocks.map((b) => '${b.id}@${b.startUtc.toIso8601String()}').toList()}',
      );
      final locked = proposal.blocks
          .where((b) => b.id == 'b-locked')
          .firstOrNull;
      expect(locked, isNotNull, reason: '锁定块必须仍在计划里');
      expect(
        locked!.startUtc,
        at(0),
        reason:
            '锁定块的位置**逐字不变**。它必须作为硬占用传给级联，'
            '而不是出现在可移动输入里',
      );
    });
  });

  test('**已过去的块不被搬动**（它只作为硬占用）', () {
    // 现在 = 本地 09:30（`at(0)` + 30 分钟）。过去块在本地 09:00–09:30（`at(0)` 起 30 分钟），
    // 端点恰好落在"现在"，因此它**在窗口内**（`startUtc` = 窗口起点）。
    // 目标块在本地 14:00（`at(5)`），延后 30 分钟。
    //
    // 若过去的块进了可移动输入，级联会把它当成"能不能留在原位"的普通块，
    // 一旦挡路就会搬走它 —— 但已经发生的安排是**事实**，不该被搬。
    final confirmed = ConfirmedPlan(
      id: 'v1',
      inputHash: 'h1',
      algorithmVersion: 'test',
      blocks: [block('b-past', 0, minutes: 30), block('b-target', 5)],
    );
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(confirmed),
      clock: _Clock(at(0).add(const Duration(minutes: 30))),
      timeZoneId: zoneId,
      zones: zones,
      pendingMoves: PendingMoveDrafts()
        ..beginAdjustment(
          PlanAdjustmentRequest(
            blockId: 'b-target',
            amount: 30,
            unit: DeferUnit.minutes,
            sourceStartUtc: at(5),
            timeZoneId: zoneId,
          ),
        ),
    );

    return PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    ).createProposal().then((proposal) {
      final past = proposal.blocks.where((b) => b.id == 'b-past').firstOrNull;
      expect(past, isNotNull, reason: '已过去的块必须仍在计划里（它在窗口内）');
      expect(past!.startUtc, at(0), reason: '过去的块必须冻结在原位');
    });
  });

  test('**没有任何块 ID 出现两次**（五类块按 ID 互斥）', () {
    // 用户第 67 轮独立核验发现的缺陷：同一个锁定块被放进最终提案两次。
    //
    // 原因：`lockedBlocks` 先按 `block.locked` 加入锁定块，
    // 随后"未被本次调整碰到 ⇒ 原位冻结"那一段**没有排除 `locked`**，又加了一次。
    //
    // 五类块必须按 ID 互斥：锁定 / 钉住（拖动）/ 调整目标 / 被挤开 / 原位冻结。
    final confirmedBlocks = [
      block('b-target', 0),
      block('b-locked', 0, minutes: 60, locked: true),
      block('b-plain', 6),
    ];

    return defer(confirmedBlocks: confirmedBlocks, amount: 60).then((proposal) {
      final ids = proposal.blocks.map((b) => b.id).toList();
      expect(
        ids.toSet(),
        hasLength(ids.length),
        reason:
            '同一块出现两次 ⇒ 用户会在日程里看到两份相同安排。'
            '实测过的坏输出：`b-locked@09:00` 出现两次',
      );
    });
  });

  test('**锁定块恰好出现一次**（不能既锁定又冻结）', () {
    final confirmedBlocks = [
      block('b-target', 0),
      block('b-locked', 0, minutes: 60, locked: true),
    ];

    return defer(confirmedBlocks: confirmedBlocks, amount: 60).then((proposal) {
      final locked = proposal.blocks.where((b) => b.id == 'b-locked');
      expect(
        locked,
        hasLength(1),
        reason: '锁定块必须**恰好一次**：它同时属于"锁定"与"未受影响的块"，只能记一次',
      );
    });
  });

  test('**级联失败的回退路径仍然把目标块排进计划**', () {
    // 用户第 67 轮第 4 条：只有局部修复**成功**时才能冻结未受影响的块。
    // 失败回退时若把目标块也冻结在原位，用户点了延后却什么都没变 —— 延后失效。
    //
    // **据实说明这条用例证明了什么、没证明什么**：
    // 它覆盖"下界落在次日、当天放不下"的场景，断言目标块**没有被冻结在原位**
    // 且仍进了计划。但我**试过**把生产代码改成"只要 `adjustment != null` 就冻结"
    // 来验证它会红 —— 结果它**仍然通过**：这个夹具里当天尝试其实**成功**了
    // （下界之后窗口还剩足够空间），`adjustedTarget` 不为空，冻结分支根本没走到。
    //
    // 因此**"失败路径不冻结目标"目前只有代码事实（`adjustedTarget != null` 门槛）
    // 与代码审查支持，没有真正走通的用例**。要真正覆盖，需要构造一个
    // "当天尝试失败且回退也失败"的夹具，而那要求把规划窗口收窄到当天 ——
    // 窗口由 `days` 参数决定，会连带改变装配层别处的行为，属于扩大改动面，
    // 本轮**没有做**，据实记在验收文档里。
    final confirmed = ConfirmedPlan(
      id: 'v1',
      inputHash: 'h1',
      algorithmVersion: 'test',
      blocks: [block('b-target', 14, minutes: 30), block('b-other', 6)],
    );
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(confirmed),
      clock: _Clock(dayStart),
      timeZoneId: zoneId,
      zones: zones,
      pendingMoves: PendingMoveDrafts()
        ..beginAdjustment(
          PlanAdjustmentRequest(
            blockId: 'b-target',
            amount: 60,
            unit: DeferUnit.minutes,
            sourceStartUtc: at(14).add(const Duration(minutes: 30)),
            timeZoneId: zoneId,
          ),
        ),
    );

    return PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    ).createProposal().then((proposal) {
      final target = proposal.blocks
          .where((b) => b.id == 'b-target')
          .firstOrNull;
      expect(target, isNotNull, reason: '回退路径仍必须把目标块排进计划（不能因为级联失败就丢掉它）');
      expect(
        target!.startUtc.isBefore(at(15)),
        isFalse,
        reason:
            '下界落在次日 ⇒ 目标块不能被冻结在原位（本地 23:30 = `at(14.5)`）。'
            '若这里回到 `at(14.5)`，说明失败路径把目标块冻结了，延后失效',
      );
    });
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
