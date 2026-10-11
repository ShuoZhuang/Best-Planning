// 1.8.0（裁定第 3 点；设计 §5.3）：延后的**作用域**。
//
// §11.1 的文案要求："**只调整当前计划块**，不修改任务截止时间。"
// §11.2 又说："目标是 `notBeforeUtc` 下界，不是必须精确占用的点。"
//
// **本文件曾经记录过一个缺陷**：修复前，块级下界是通过**抬高任务的 `availableFromUtc`**
// 实现的，而"任务的可用起点"是**任务级**输入，因此
//
//     > 延后一个任务的一块，会把它自己其余的块也一起推后。
//
// 那时这个文件的三条用例（"延后一块会抬高整个任务的可用起点"等）**把这个错误行为
// 固定了下来** —— 用例忠实描述了现实，而现实是错的。裁定第 3 点明确纠正：
// 不得再用任务级 `availableFromUtc` 模拟块级延后。
//
// 现在它验的是**纠正之后**的语义：延后只表达为 `ScheduleProblem.adjustment`
// 的一个块级上下文，任务的可用起点**一个字段都不动**。
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
            // 同一个任务的两块：东八区 10:00 与 15:00。
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
          sourceStartUtc: base.add(const Duration(hours: 9)),
          timeZoneId: zoneId,
        ),
      );

  test('**任务的可用起点不被延后改动**（同任务的其他块因此不被牵连）', () async {
    final problem = await load(pendingMoves: deferring('b1'));

    expect(
      problem.tasks.single.availableFromUtc,
      isNull,
      reason:
          '修复前这里会被抬到"原时刻 + 30 分钟"，于是 b2（同一任务的另一块）'
          '也被推后——那正是裁定第 3 点要纠正的。任务自己没设最早开始时间，'
          '因此必须是 null',
    );
  });

  test('延后以**块级**上下文表达，目标是那一块而不是任务', () async {
    final problem = await load(pendingMoves: deferring('b1'));

    expect(problem.adjustment?.targetBlockId, 'b1', reason: '块级意图必须指向块');
    expect(
      problem.adjustment?.notBeforeUtc,
      base.add(const Duration(hours: 9, minutes: 30)),
      reason: '下界 = 原开始时刻 + 30 分钟',
    );
  });

  test('**未延后的块不受影响**：它仍有参考位置，且不被精确钉住', () async {
    final problem = await load(pendingMoves: deferring('b1'));

    expect(
      problem.referenceBlocks['b2'],
      base.add(const Duration(hours: 14)),
      reason: '参考位置仍是原时刻——引擎据此判断"要不要动它"',
    );
    expect(
      problem.pinnedUnlockedBlockIds.contains('b2'),
      isFalse,
      reason:
          'b2 不在精确钉住集合里（延后请求期间只有下界，没有钉点）。'
          '若这里变成 true，说明延后把同一任务的**其他块**也钉住了，那是更重的错误',
    );
  });

  test('**被延后的那一块**不进精确钉住集合', () async {
    final problem = await load(pendingMoves: deferring('b1'));

    expect(
      problem.pinnedUnlockedBlockIds.contains('b1'),
      isFalse,
      reason: '目标是下界而不是精确点（规范 §11.2）；钉住会让目标被占用时直接失败',
    );
  });

  test('对照：没有延后请求时既无上下文、也无任务级约束', () async {
    final problem = await load();

    expect(problem.adjustment, isNull);
    expect(problem.tasks.single.availableFromUtc, isNull);
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
