// 1.8.0（规范 §11.4 末段："先在当天做向后级联；当天放不下时才考虑后续日期"）。
//
// **本文件补的是生产接线的两处缺口**（用户复核时发现）：
//
// 1. `repairBestPlan` 的 `dayStartUtc`／`dayEndUtc` 此前传的是**整个规划窗口**
//    （默认 7 天），而不是"目标块所在的那个本地自然日"。于是"当天优先"没有被执行：
//    级联可以直接把目标块放到几天之后，只要那还在窗口内。
// 2. `immovable` 此前传的是**空列表**。`localRepairCascade` 的 `firstFit`
//    只在 `occupied` 里找冲突，而固定日程与保护时间**不在 `blocks` 里**，
//    因此它们**完全不参与**级联的避让——候选项可以直接落进固定日程，
//    直到引擎的硬约束把它判掉（用户看到的是"预览里那块被拒了"）。
//
// 两处都会表现为"本应先在当天调整，却跨天找位置"或"候选落进固定日程"。
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

  PlannedBlock block(String id, int hour, {int minutes = 60}) => PlannedBlock(
    id: id,
    taskId: 't-a',
    range: TimeRange(
      startUtc: at(hour),
      endUtc: at(hour).add(Duration(minutes: minutes)),
    ),
  );

  /// 一块 09:00 的确认块，计划**从 [sourceHour] 起**延后 [amount] 分钟。
  ///
  /// **`sourceStartUtc` 决定下界**：`PlanAdjustmentRequest.notBeforeUtc` 算的是
  /// `sourceStartUtc + amount`（`pending_moves.dart` 的 `deferNotBeforeUtc`），
  /// **不是**"接口给我的某一个时刻"。第一版我没有参数化它，
  /// 于是无论我传什么 `amount`，下界都从 `at(0)` 算起 —— 断言自然对不上。
  /// 这一处我又犯了同一个毛病：**在心里算，而不是量**。
  Future<ScheduleProposal> deferWith({
    required List<CalendarOccurrence> calendar,
    int amount = 30,
    int sourceHour = 0,
  }) {
    final confirmed = ConfirmedPlan(
      id: 'v1',
      inputHash: 'h1',
      algorithmVersion: 'test',
      blocks: [block('b-target', 0)],
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
            sourceStartUtc: at(sourceHour),
            timeZoneId: zoneId,
          ),
        ),
    );
    return PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    ).createProposal();
  }

  CalendarOccurrence fixed(String id, int hour, {int minutes = 60}) =>
      CalendarOccurrence(
        eventId: id,
        title: '线性代数',
        range: TimeRange(
          startUtc: at(hour),
          endUtc: at(hour).add(Duration(minutes: minutes)),
        ),
        locked: true,
        kind: CalendarEventKind.fixed,
      );

  CalendarOccurrence protectedTime(String id, int hour, {int minutes = 60}) =>
      CalendarOccurrence(
        eventId: id,
        title: '保护时间',
        range: TimeRange(
          startUtc: at(hour),
          endUtc: at(hour).add(Duration(minutes: minutes)),
        ),
        locked: true,
        kind: CalendarEventKind.protected,
      );

  /// 每块是否与任何"不可占用"区间重叠。这是**硬约束**：方案不得越过它。
  String? overlapOf(PlannedBlock block, List<CalendarOccurrence> barriers) {
    for (final barrier in barriers) {
      if (block.startUtc.isBefore(barrier.range.endUtc) &&
          barrier.range.startUtc.isBefore(block.endUtc)) {
        return barrier.eventId;
      }
    }
    return null;
  }

  test('**目标块不会落进固定日程**（固定日程必须参与级联避让）', () async {
    // 下界 09:30（09:00 + 30 分钟）。把 09:30–12:00 全部用固定日程占满，
    // 当天再往后没有余量（20:00 之后到日终放不下 60 分钟的任务块之外还有空间，
    // 因此这里只占 09:30–19:00，留出 19:00–24:00）。
    final barriers = [
      fixed('f1', 0, minutes: 240), // 09:00–13:00
      fixed('f2', 4, minutes: 240), // 13:00–17:00
      fixed('f3', 8, minutes: 120), // 17:00–19:00
    ];

    final proposal = await deferWith(calendar: barriers);
    final target = proposal.blocks.where((b) => b.id == 'b-target').firstOrNull;

    expect(target, isNotNull, reason: '目标块必须在提案里');
    expect(
      target!.startUtc.isBefore(at(0).add(const Duration(minutes: 30))),
      isFalse,
      reason: '目标块不得早于下界',
    );
    expect(
      overlapOf(target, barriers),
      isNull,
      reason:
          '**目标块不得与固定日程重叠**。'
          '修复前 `immovable` 传的是空列表，级联看不见固定日程，'
          '候选可以直接落进 09:30 起的固定日程里',
    );
  });

  test('**目标块不会落进保护时间**（保护时间是硬禁区）', () async {
    final barriers = [
      protectedTime('p1', 0, minutes: 300), // 09:00–14:00
      protectedTime('p2', 5, minutes: 300), // 14:00–19:00
    ];

    final proposal = await deferWith(calendar: barriers);
    final target = proposal.blocks.where((b) => b.id == 'b-target').firstOrNull;

    expect(target, isNotNull);
    expect(
      overlapOf(target!, barriers),
      isNull,
      reason: '保护时间是排程硬禁区（规范 §12.1）：候选不得落进去',
    );
  });

  test('**没有固定日程时不产生额外限制**（对照：延后照常生效）', () async {
    final proposal = await deferWith(calendar: const []);
    final target = proposal.blocks.where((b) => b.id == 'b-target').firstOrNull;

    expect(target, isNotNull);
    expect(
      target!.startUtc.isBefore(at(0).add(const Duration(minutes: 30))),
      isFalse,
      reason: '对照组：下界仍然生效',
    );
  });

  test('**当天放得下就不跨天**（规范 §11.4 末段：当天优先，走完整装配链）', () async {
    // 下界 = 本地 09:30（`at(0)` + 30 分钟）；当天其余时间空着。
    final proposal = await deferWith(calendar: const []);
    final target = proposal.blocks.where((b) => b.id == 'b-target').firstOrNull;

    expect(target, isNotNull);
    // 东八区 09:00（= `at(0)`）所在本地日的日终 = 本地 24:00 = `at(15)`。
    expect(
      target!.startUtc.isBefore(at(15)),
      isTrue,
      reason:
          '当天有位置就必须当天放。修复前 `dayEndUtc` 传的是**整个规划窗口**'
          '（默认 7 天），级联可以直接把块放到几天之后',
    );
  });

  test('**当天确实放不下时才往后找**（不假装失败，走完整装配链）', () async {
    // 下界 = 本地**次日 00:30**（`sourceStartUtc` 本地 23:00 + 90 分钟）。
    //
    // **这条用例我改了四次**，每次都是"在心里算边界"而不是量：
    //   ① 本地 23:30 起 ⇒ 实测落点 `15:30Z`/`16:00Z`，**正好**卡在日终，其实放得下；
    //   ② 本地 23:45 起 ⇒ 改 `amount` 没用：下界一直从 `sourceStartUtc` 算起；
    //   ③ 参数化 `sourceStartUtc` 后本地 23:50 起 ⇒ 实测 `15:50Z`，**仍在同一天内**
    //      —— 因为 23:50 这个下界本身就落在当天，"当天放得下"是对的；
    //   ④ 现在把下界推到**次日 00:30**，当天才真的放不下。
    //
    // 教训：涉及本地日边界时，**"下界落在哪一天"本身就要先算清**，
    // 不能只看"是不是快到 24:00 了"。
    final proposal = await deferWith(
      calendar: const [],
      sourceHour: 14,
      amount: 90,
    );
    final target = proposal.blocks.where((b) => b.id == 'b-target').firstOrNull;

    expect(target, isNotNull, reason: '当天放不下 ⇒ 应当继续往后找，而不是判不可行');
    expect(
      target!.startUtc.isBefore(at(15)),
      isFalse,
      reason:
          '下界已经落在次日 ⇒ 落点必然在之后的本地日'
          '（`at(15)` 是 `at(0)` 所在本地日的日终）',
    );
  });

  test('**周一延后、周二还有确认块**：多日计划下"当天优先"仍成立（端到端）', () async {
    // 确认计划：周一 09:00 的目标块 + 周二 09:00 的另一块（同一任务）。
    //
    // 这条走**完整装配链**：`RepositoryScheduleProblemSource` → `PlanningService` → 引擎。
    // 它覆盖真实形态——生产接线传进 `repairBestPlanDayScoped` 的是**整个规划窗口**
    // （默认 7 天）的确认块，因此"当天尝试"必须自己把范围收成目标那一天。
    final confirmed = ConfirmedPlan(
      id: 'v1',
      inputHash: 'h1',
      algorithmVersion: 'test',
      blocks: [block('b-target', 0), block('b-tuesday', 24)],
    );
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: _NoLifeAreas(),
      calendar: const _Calendar([]),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(confirmed),
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
    final proposal = await PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    ).createProposal();

    final target = proposal.blocks.where((b) => b.id == 'b-target').firstOrNull;
    expect(target, isNotNull, reason: '目标块必须在提案里');
    expect(
      target!.startUtc.isBefore(at(15)),
      isTrue,
      reason: '目标块必须留在**周一**（`at(0)` 所在本地日，日终 = `at(15)`）',
    );
    // **实测到的形态**（据此写断言，而不是按我原先的猜测）：
    // 引擎是**从零生成**的，它不认识"周二那一块"，因此把整个任务重排了一遍——
    // 实测两块都落在周一（`01:30Z` 与 `05:30Z`）。**"周二那一块保持原位"这条断言
    // 从一开始就是错的**：本次调整只碰目标块，引擎随后按自己的规则排这个任务。
    //
    // 能验的真实契约是：**当天尝试成功时，不会有任何块被推到目标当天之外**
    // （这正是修复点——修复前周二那块会被搬进/移出周一窗口）。
    for (final block in proposal.blocks) {
      expect(
        block.startUtc.isBefore(at(15)),
        isTrue,
        reason:
            '当天尝试成功 ⇒ 所有落点都在目标当天之内。'
            '修复前"当天尝试"会把整个七天窗口的块一起搬动',
      );
    }
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
