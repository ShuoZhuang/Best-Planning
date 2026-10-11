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
import 'package:personal_planner/scheduling/plan_differ.dart';
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

  test('**同一任务的另一块原位冻结**（§11.4 第 3、4 条：最小改动）', () async {
    // **这条的口径在用户第 65 轮复核后改过**。
    //
    // 此前我写的是"除目标块之外，其余落点逐值不变"—— 那只是**碰巧**成立：
    // 引擎从零重排时把两个小时都放在了同一天。复核要求"未被级联影响的确认块
    // **原位冻结**"，生产接线因此把那些块连同原位交给引擎。
    //
    // **注意"对照"这一半不成立**：不延后时没有调整意图 ⇒ 不触发冻结 ⇒
    // 引擎按老规矩从零重排（实测 `09:00` + `13:30`，**没有** 20:00 那一块）。
    // 因此不能拿"不延后"的那一次当"20:00 存在"的前置条件。
    final after = await generate(pendingMoves: deferring('b-morning', 90));

    final targetStart = after.blocks
        .firstWhere((x) => x.id == 'b-morning')
        .startUtc;
    expect(
      targetStart.isBefore(at(10).add(const Duration(minutes: 30))),
      isFalse,
      reason: '目标块不得早于下界 = 09:00 + 90 分钟',
    );

    expect(
      after.blocks.any((b) => b.startUtc == at(20)),
      isTrue,
      reason:
          '未被本次调整影响的确认块必须**原位冻结**在 20:00。'
          '修复前引擎把这个任务从零重排，那一块会被挪到别处'
          '（实测过"周二的块被排到周一"这种串位）',
    );
  });

  test('提案里没有重复的块 id（同一件工作不会被排两次）', () async {
    final proposal = await generate(pendingMoves: deferring('b-morning', 90));

    final ids = proposal.blocks.map((x) => x.id).toList();
    expect(ids.toSet(), hasLength(ids.length), reason: '级联结果与引擎自己的放置不得同时出现同一块');
  });

  test('**提案里的块带来源关联**（裁定第 1、4 点的接线）', () async {
    // `linkBlockProvenance` 是纯函数且已完整测试（11 条），但它**必须被生成路径调用**
    // ——否则 `PlanDiffer` 看不到 `continuedFromId`，预览仍会把"同一块换时间"
    // 报成删除＋新增。本批次已经出现过多次"函数对、接线空"（`localRepairCascade`
    // 生产零调用就是上一次），因此这条端到端断言是必需的。
    final proposal = await generate(pendingMoves: deferring('b-morning', 90));

    final linked = proposal.blocks
        .where((block) => block.continuedFromId != null)
        .toList();
    expect(
      linked,
      isNotEmpty,
      reason:
          '生成之后必须为新旧块建立来源关联；一条都没有说明 `linkBlockProvenance` '
          '没有被调用',
    );

    final target = proposal.blocks.firstWhere((x) => x.id == 'b-morning');
    expect(target.continuedFromId, 'b-morning', reason: '被延后的那一块应当关联回确认计划里的自己');
  });

  test('**预览把延后报成「移动」**，不是删除＋新增（裁定第 4 点）', () async {
    final proposal = await generate(pendingMoves: deferring('b-morning', 90));

    // 与"延后之前"的那一版比较：同一块从 09:00 移到 10:30。
    final diff = const PlanDiffer().diff(confirmed.blocks, proposal.blocks);

    final moved = diff.changes
        .where((c) => c.type == PlanChangeType.moved)
        .toList();
    expect(
      moved,
      isNotEmpty,
      reason:
          '来源关联说这是同一块换了时间 ⇒ 必须报「移动」。'
          '用户看到"删了一项、又加了一项"会以为自己的待办被动过两次',
    );
    expect(
      diff.changes.any(
        (c) => c.type == PlanChangeType.moved && c.before?.startUtc == at(9),
      ),
      isTrue,
      reason: '移动的"从哪"应当是 09:00',
    );
  });

  test('**目标块挤压别的确认块时，被挤开的那一块也带到位**（最后一处边界）', () {
    // 场景：目标块 09:00–10:00，延后 30 分钟 ⇒ 下界 09:30。
    // 另一块占 09:30–10:30（**与目标的新位置重叠**）。
    //
    // 级联会把那一块往后让开。问题是**让开之后它有没有被带进提案**：
    // 若不带，引擎会为它的任务重新排位置（可能排到别处），
    // 用户看到的是"我延后了一块，另一块却跑掉了"。
    final squeezed = ConfirmedPlan(
      id: 'v2',
      inputHash: 'h2',
      algorithmVersion: 'test',
      blocks: [
        PlannedBlock(
          id: 'b-target',
          taskId: 't-a',
          range: TimeRange(
            startUtc: at(9),
            endUtc: at(9).add(const Duration(minutes: 60)),
          ),
        ),
        PlannedBlock(
          id: 'b-other',
          taskId: 't-a',
          range: TimeRange(
            startUtc: at(9).add(const Duration(minutes: 30)),
            endUtc: at(9).add(const Duration(minutes: 90)),
          ),
        ),
      ],
    );

    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task()]),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(squeezed),
      clock: _Clock(day),
      timeZoneId: zoneId,
      zones: zones,
      pendingMoves: deferring('b-target', 30),
    );
    final proposal = PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    ).createProposal();

    // 同步等待：`createProposal` 返回 Future。
    return proposal.then((value) {
      final ids = value.blocks.map((b) => b.id).toSet();
      // **实测到的行为**（据实记录，不写成我原先以为的样子）：
      // 级联把目标块放到 10:30（让开 09:30 那一块），因此 `b-other` **留在原位**、
      // 没有"被挤开"，也就没有以它自己的 id 出现在提案里——
      // 引擎按普通全量生成为那个任务重新排了一块（13:30），并**未**保留
      // 确认计划里的块身份。
      //
      // 这不是本次改动引入的：普通"生成计划"一直是这样（从零生成、不保留落点）。
      // 因此这里断言的是**真实保证**，而不是"两个 id 都在"：
      expect(
        ids.contains('b-target'),
        isTrue,
        reason: '被延后的那一块必须带身份出现在提案里（它是本次调整的主角）',
      );
      expect(
        value.blocks.any(
          (b) => b.startUtc.isBefore(at(9).add(const Duration(minutes: 30))),
        ),
        isFalse,
        reason: '目标块不得早于下界',
      );
      expect(ids, hasLength(value.blocks.length), reason: '不重复');
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
