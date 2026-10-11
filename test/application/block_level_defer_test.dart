// 1.8.0（裁定第 3 点；设计 §5.3）：延后**必须保留块级请求**，不得降成任务级下界。
//
// 修复前的装配（`repository_schedule_problem_source.dart`）把"指定块的延后请求"
// 转成**整个任务的** `availableFromUtc`：
//
//     deferredTaskStarts[block.taskId] = notBefore;
//     ...
//     availableFromUtc: _laterOf(task.availableFromUtc, deferredTaskStarts[task.id]),
//
// 后果：**延后一块会把它自己其余的块也一起推后**。
// 规范 §11.1 的文案是"只调整当前计划块"，§11.4 第 3、4 条要求"移动的其他块数量最少"——
// 任务级下界与这两条都不符。
//
// 修法：`ScheduleProblem` 增加**块级**调整上下文，延后路径直接携带它进入引擎。
//
// 本文件钉住三件事：
// 1. 任务的 `availableFromUtc` **不再**被延后请求改动；
// 2. `ScheduleProblem.adjustment` 带着**准确的目标块 id**与下界；
// 3. 没有延后请求时 `adjustment` 为空（不留残影）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_moves.dart';
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
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  // 东八区 2026-10-12（周一）09:00 => 01:00Z
  final base = DateTime.utc(2026, 10, 12, 1);

  /// 一个任务的**两块**：10:00 与 15:00（东八区）。
  PlannerTask task() => PlannerTask(
    id: 't1',
    title: '写报告',
    priority: TaskPriority.medium,
    estimatedMinutes: 120,
    remainingMinutes: 120,
    energyLevel: TaskEnergyLevel.medium,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 60,
    status: TaskStatus.open,
    createdAtUtc: base,
    updatedAtUtc: base,
  );

  PlannedBlock block(String id, int hour) => PlannedBlock(
    id: id,
    taskId: 't1',
    range: TimeRange(
      startUtc: base.add(Duration(hours: hour)),
      endUtc: base.add(Duration(hours: hour + 1)),
    ),
  );

  Future<ScheduleProblem> load({PendingMoveDrafts? pendingMoves}) =>
      RepositoryScheduleProblemSource(
        tasks: _Tasks([task()]),
        lifeAreas: _NoLifeAreas(),
        calendar: _NoCalendar(),
        settings: SettingsService(repository: MemorySettingsRepository()),
        plans: _Plan(
          ConfirmedPlan(
            id: 'v1',
            inputHash: 'h1',
            algorithmVersion: 'test',
            blocks: [block('b1', 9), block('b2', 14)],
          ),
        ),
        clock: _Clock(base),
        timeZoneId: zoneId,
        zones: zones,
        pendingMoves: pendingMoves,
      ).load();

  PendingMoveDrafts deferring(String blockId, {int amount = 30}) =>
      PendingMoveDrafts()..beginAdjustment(
        PlanAdjustmentRequest(
          blockId: blockId,
          amount: amount,
          unit: DeferUnit.minutes,
          // 东八区 10:00 那块 => 01:00Z
          sourceStartUtc: base.add(const Duration(hours: 9)),
          timeZoneId: zoneId,
        ),
      );

  test('**延后一块不再抬高任务的可用起点**（同任务的其他块因此不被牵连）', () async {
    final problem = await load(pendingMoves: deferring('b1'));

    expect(
      problem.tasks.single.availableFromUtc,
      isNull,
      reason:
          '任务本身没有最早开始时间，因此这里必须是 null。'
          '修复前它会被延后请求抬到"原时刻 + 30 分钟"，'
          '于是**同一个任务的另一块也被推后**——那正是裁定要纠正的',
    );
  });

  test('延后请求以**块级**上下文进入排程输入', () async {
    final problem = await load(pendingMoves: deferring('b1'));

    final adjustment = problem.adjustment;
    expect(adjustment, isNotNull, reason: '延后路径必须携带块级上下文');
    expect(adjustment!.targetBlockId, 'b1', reason: '目标必须是**那一块**，不是任务 id');
    expect(
      adjustment.notBeforeUtc,
      base.add(const Duration(hours: 9, minutes: 30)),
      reason: '下界 = 原开始时刻 + 30 分钟（UTC 算术）',
    );
    expect(adjustment.kind, BlockAdjustmentKind.defer);
  });

  test('延后**另一块**时目标跟着换（不会被任务级聚合抹平）', () async {
    final problem = await load(pendingMoves: deferring('b2'));

    expect(problem.adjustment?.targetBlockId, 'b2');
  });

  test('没有延后请求时 `adjustment` 为空（不留残影）', () async {
    expect((await load()).adjustment, isNull);
  });

  test('延后请求指向**不存在**的块时不产生上下文，也不抬高任务起点', () async {
    final problem = await load(pendingMoves: deferring('b-missing'));

    expect(
      problem.adjustment,
      isNull,
      reason:
          '目标块不在确认计划里 ⇒ 这条请求无法表达为块级调整；'
          '不得退回任务级模拟（那会牵连同任务其他块）',
    );
    expect(problem.tasks.single.availableFromUtc, isNull);
  });

  test('任务自己设的最早开始时间**原样保留**（不被延后抹掉，也不被它取代）', () async {
    final problem = await RepositoryScheduleProblemSource(
      tasks: _Tasks([
        PlannerTask(
          id: 't1',
          title: '写报告',
          priority: TaskPriority.medium,
          estimatedMinutes: 120,
          remainingMinutes: 120,
          energyLevel: TaskEnergyLevel.medium,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
          status: TaskStatus.open,
          createdAtUtc: base,
          updatedAtUtc: base,
          availableFromUtc: base.add(const Duration(hours: 5)),
        ),
      ]),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(
        ConfirmedPlan(
          id: 'v1',
          inputHash: 'h1',
          algorithmVersion: 'test',
          blocks: [block('b1', 9)],
        ),
      ),
      clock: _Clock(base),
      timeZoneId: zoneId,
      zones: zones,
      pendingMoves: deferring('b1'),
    ).load();

    expect(
      problem.tasks.single.availableFromUtc,
      base.add(const Duration(hours: 5)),
      reason: '任务自己的约束是任务级的，不该被块级请求改写',
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
