// 1.8.0（设计规范 §11）：延后**当前计划块**的语义边界。
//
// §11.1 的文案要求："只调整当前计划块，不修改任务截止时间。"
// §11.2 又说："目标是 `notBeforeUtc` 下界，不是必须精确占用的点。"
//
// 两条合起来有一处需要实证的地方：块级下界是通过**抬高任务的 `availableFromUtc`**
// 实现的（见 `repository_schedule_problem_source.dart` 里 `deferredTaskStarts` 那一段），
// 而"任务的可用起点"是**任务级**输入。因此一个任务有多个块时，
// **延后其中一块会把它自己其余的块也一起往后推**。
//
// 本文件把这件事**测出来并钉住**，而不是靠读代码推断：
// 用户按的是"延后这一块"，若结果里别的块也动了，那是他预期之外的位移。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_moves.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/models/time_range.dart';
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

  test('**延后一块会抬高整个任务的可用起点**（因此它其余的块也被推后）', () async {
    // 只延后 b1（10:00 那块）30 分钟。
    final drafts = PendingMoveDrafts()
      ..beginAdjustment(
        PlanAdjustmentRequest(
          blockId: 'b1',
          amount: 30,
          unit: DeferUnit.minutes,
          sourceStartUtc: base.add(const Duration(hours: 9)),
          timeZoneId: zoneId,
        ),
      );

    final problem = await load(pendingMoves: drafts);

    final schedulable = problem.tasks.single;
    expect(
      schedulable.availableFromUtc,
      base.add(const Duration(hours: 9, minutes: 30)),
      reason:
          '下界被并进了任务的可用起点（`_laterOf(task.availableFromUtc, 下界)`）；'
          '这是**任务级**输入，因此它同时影响这个任务的每一块',
    );

    // **这就是要钉住的事实**：只延后 b1，但 b2（15:00 那块）也被推迟到 10:30 之后
    // 才允许开始排。b2 原本 15:00 已经满足这个下界，因此"是否真的移动"取决于引擎；
    // 但**输入层面它已经不再被钉在 15:00**（见下面那条断言）。
    expect(
      problem.referenceBlocks['b2'],
      base.add(const Duration(hours: 14)),
      reason: '参考位置仍然是原时刻——引擎据此判断"要不要动它"',
    );
  });

  test('**未被延后的块不再被精确钉住**：它只是有参考位置，可以被引擎挪动', () async {
    // 与上一条同一场景。这里断言的是"b2 是否还属于可移动块"。
    //
    // 延后路径刻意**跳过**精确钉住（`if (deferredTaskStarts.containsKey(block.taskId)) continue;`），
    // 因此 b2 会作为普通可移动块进入引擎——也就是说，**引擎有权把它挪走**，
    // 而不是必须把它留在 15:00。
    final drafts = PendingMoveDrafts()
      ..beginAdjustment(
        PlanAdjustmentRequest(
          blockId: 'b1',
          amount: 30,
          unit: DeferUnit.minutes,
          sourceStartUtc: base.add(const Duration(hours: 9)),
          timeZoneId: zoneId,
        ),
      );

    final problem = await load(pendingMoves: drafts);

    final taskB = problem.tasks.single;
    // `referenceBlocks` 是"引擎应当尽量贴近"的位置，不是硬约束；
    // 硬约束只有一个可用起点。
    expect(
      taskB.availableFromUtc!.isAfter(base.add(const Duration(hours: 9))),
      isTrue,
    );
    expect(
      problem.pinnedUnlockedBlockIds.contains('b2'),
      isFalse,
      reason:
          'b2 不在 `blocks`（精确钉住表）里 —— 延后请求期间只有下界，没有钉点。'
          '若这里变成 true，说明延后把同一任务的**其他块**也钉住了，那是更重的错误',
    );
  });

  test('对照：没有延后请求时，任务的可用起点不被改动', () async {
    final problem = await load();

    expect(
      problem.tasks.single.availableFromUtc,
      isNull,
      reason:
          '**注意这里是 `null` 而不是计划起点**：任务本身没设最早开始时间时，'
          '排程输入交给引擎的就是"没有约束"。延后**新增**的正是这样一个任务级约束——'
          '这也解释了为什么它会影响该任务的每一块，而不只是被延后的那一块',
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
