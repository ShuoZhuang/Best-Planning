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

  test('对照：没有锁定块时延后照常生效', () {
    return defer(confirmedBlocks: [block('b-target', 0), block('b-other', 6)])
        .then((proposal) {
          final target = proposal.blocks
              .where((b) => b.id == 'b-target')
              .firstOrNull;
          expect(target, isNotNull);
          expect(
            target!.startUtc.isBefore(at(0).add(const Duration(minutes: 30))),
            isFalse,
            reason: '对照组：下界仍然生效',
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
