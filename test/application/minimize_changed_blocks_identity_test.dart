// **Task 8 的 ID 族验收**：真实装配下 `minimizeChangedBlocks` 必须能认出既有块。
//
// ## 这条测试守的是什么
//
// 在 ID 族修复之前，真实装配的三处 id 互不相认：
//
// | 来源 | id 形状 |
// | --- | --- |
// | 引擎新排的块 | `block:<taskId>:<开始微秒>:<时长>` |
// | 确认计划的块（`existingBlocks`） | persistedId，如 `<提案 id>:block:<taskId>:…` |
// | `referenceBlocks` 的键 | 与确认计划**同一批** persistedId |
//
// 于是 `minimizeChangedBlocks` 里的 `referenceBlocks.containsKey(block.id)`
// 对每个引擎排出的块都是 false ⇒ 全部被判为"没有参照、不可移动" ⇒
// **那一步在真实装配下是空操作**，"尽量少改动"只在函数级测试里成立。
//
// 修复后：未锁定的既有块以**原 id** 作为起点进入排程，因此参照能匹配上。
//
// 这条用例走**真实装配**（`RepositoryScheduleProblemSource`），不是手写夹具，
// 因为缺陷恰好出在"装配层与引擎各自命名"这一层。
import 'package:flutter_test/flutter_test.dart';
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
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final class _FixedClock implements Clock {
  const _FixedClock(this.instant);
  final DateTime instant;
  @override
  DateTime nowUtc() => instant;
}

final class _FakeTasks implements TaskRepository {
  _FakeTasks(this.items);
  final List<PlannerTask> items;
  @override
  Future<PlannerTask?> getById(String id) async =>
      items.where((item) => item.id == id).firstOrNull;
  @override
  Future<void> save(PlannerTask task) async {}
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(items);
  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(items);
}

final class _FakeCalendar implements CalendarRepository {
  _FakeCalendar(this.occurrences);
  final List<CalendarOccurrence> occurrences;
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => occurrences
      .where(
        (item) =>
            item.range.overlaps(TimeRange(startUtc: startUtc, endUtc: endUtc)),
      )
      .toList();
  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _FakePlans implements PlanRepository {
  _FakePlans(this.plan);
  final ConfirmedPlan? plan;
  @override
  Future<ConfirmedPlan?> current() async => plan;
  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async => ApplyPlanResult.stale();
}

final class _NoLifeAreas implements LifeAreaLookup {
  const _NoLifeAreas();
  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';
  // 2026-10-05 02:00Z == 本地 10:00（周一）；规划窗口是本地 10-05 起的七天。
  final clock = _FixedClock(DateTime.utc(2026, 10, 5, 2));
  final created = DateTime.utc(2026, 10, 1);

  DateTime localAt(int day, int hour) => zones
      .localMidnightToUtc(DateTime(2026, 10, day), zoneId)
      .add(Duration(hours: hour));

  PlannerTask taskOf(String id) => PlannerTask(
    id: id,
    projectId: null,
    areaId: null,
    title: '任务 $id',
    notes: '',
    priority: TaskPriority.medium,
    estimatedMinutes: 60,
    remainingMinutes: 60,
    energyLevel: TaskEnergyLevel.medium,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 60,
    status: TaskStatus.open,
    createdAtUtc: created,
    updatedAtUtc: created,
  );

  RepositoryScheduleProblemSource source({
    required List<PlannerTask> tasks,
    ConfirmedPlan? plan,
  }) => RepositoryScheduleProblemSource(
    tasks: _FakeTasks(tasks),
    lifeAreas: const _NoLifeAreas(),
    calendar: _FakeCalendar(const []),
    settings: SettingsService(repository: MemorySettingsRepository()),
    plans: _FakePlans(plan),
    clock: clock,
    timeZoneId: zoneId,
    zones: zones,
  );

  ConfirmedPlan planWith(List<PlannedBlock> blocks) => ConfirmedPlan(
    id: 'plan-1',
    inputHash: 'hash',
    algorithmVersion: '17',
    blocks: blocks,
  );

  test('**真实装配：既有块保留原 id，minimizeChangedBlocks 因此不是空操作**', () async {
    // 两个任务各一块，都在周一上午。id 用 persistedId 形状
    //（`<提案 id>:block:<taskId>:…`）——这正是真实落库后的样子。
    final alphaBlockId = 'proposal:old:block:alpha:100:60';
    final betaBlockId = 'proposal:old:block:beta:200:60';
    final problem = await source(
      tasks: [taskOf('alpha'), taskOf('beta')],
      plan: planWith([
        PlannedBlock(
          id: alphaBlockId,
          taskId: 'alpha',
          range: TimeRange(startUtc: localAt(5, 14), endUtc: localAt(5, 15)),
        ),
        PlannedBlock(
          id: betaBlockId,
          taskId: 'beta',
          range: TimeRange(startUtc: localAt(5, 16), endUtc: localAt(5, 17)),
        ),
      ]),
    ).load();

    // ① 装配层必须把未锁定的既有块原样交出，且 `referenceBlocks` 与它们同族。
    expect(
      problem.existingBlocks.map((block) => block.id),
      containsAll([alphaBlockId, betaBlockId]),
      reason: '装配层必须把未锁定的既有块原样交给引擎',
    );
    expect(
      problem.referenceBlocks.keys,
      containsAll([alphaBlockId, betaBlockId]),
      reason: '`referenceBlocks` 的键必须与既有块同族，否则永远匹配不上',
    );

    final proposal = DeterministicScheduleEngine(zones).generate(problem);

    // ② 引擎必须**沿用**这些 id，而不是重新起名。
    final proposalIds = proposal.blocks.map((block) => block.id).toSet();
    expect(
      proposalIds,
      containsAll([alphaBlockId, betaBlockId]),
      reason:
          '既有块必须保留原 id；否则 `referenceBlocks.containsKey(block.id)` '
          '永远为 false，最小化改动是空操作（实测 id：$proposalIds）',
    );

    // ③ 最小化改动能真的识别它们：它们本来就在原位，因此必须留在原位。
    final repair = minimizeChangedBlocks(
      problem: problem,
      blocks: proposal.blocks,
      dayStartUtc: localAt(5, 0),
      dayEndUtc: localAt(6, 0),
    );
    for (final entry in {
      alphaBlockId: localAt(5, 14),
      betaBlockId: localAt(5, 16),
    }.entries) {
      final restored = repair.blocks.firstWhere(
        (block) => block.id == entry.key,
      );
      expect(
        restored.startUtc,
        entry.value,
        reason: '${entry.key} 在原位，最小化改动必须把它留在原位',
      );
      expect(
        repair.movedBlockIds,
        isNot(contains(entry.key)),
        reason: '${entry.key} 没有移动，不该被记为"已改动"',
      );
    }
  });

  test('**新排的块不得冒用既有 id**', () async {
    // 既有块只覆盖任务的一部分，剩下的分钟由引擎新排——新块必须用新 id。
    final existingId = 'proposal:old:block:alpha:100:30';
    final problem = await source(
      tasks: [taskOf('alpha')],
      plan: planWith([
        PlannedBlock(
          id: existingId,
          taskId: 'alpha',
          range: TimeRange(startUtc: localAt(5, 14), endUtc: localAt(5, 15)),
        ),
      ]),
    ).load();

    final proposal = DeterministicScheduleEngine(zones).generate(problem);
    final ids = proposal.blocks.map((block) => block.id).toList();
    expect(ids.toSet().length, ids.length, reason: '块 id 必须唯一：$ids');
  });

  test('**锁定块的身份语义不变**：保留原 id 与 locked 标志', () async {
    // 锁定块走 `lockedBlocks`（硬约束冻结），不参与"可采纳的既有块"。
    // 它必须原样出现在结果里，且 `locked` 仍为 true——用户点头锁定的东西
    // 不能因为这次 ID 族改造而被悄悄解锁或挪走。
    final lockedId = 'proposal:old:block:alpha:100:60';
    final problem = await source(
      tasks: [taskOf('alpha')],
      plan: planWith([
        PlannedBlock(
          id: lockedId,
          taskId: 'alpha',
          range: TimeRange(startUtc: localAt(5, 14), endUtc: localAt(5, 15)),
          locked: true,
        ),
      ]),
    ).load();

    expect(
      problem.lockedBlocks.map((block) => block.id),
      contains(lockedId),
      reason: '锁定的既有块必须进 lockedBlocks',
    );

    final proposal = DeterministicScheduleEngine(zones).generate(problem);
    final locked = proposal.blocks.firstWhere((block) => block.id == lockedId);
    expect(locked.locked, isTrue, reason: '锁定块必须保持锁定');
    expect(locked.startUtc, localAt(5, 14), reason: '锁定块的位置不得被移动');
  });

  test('**旧数据兼容**：id 是 uuid 形状的既有块同样被采纳', () async {
    // 用户要求："旧数据缺少稳定 block ID 时，需要兼容迁移或确定性补全，
    // 不能导致计划全部被判断为新块。"
    //
    // 这条钉住的是**判据与 id 形状无关**：采纳只看"任务还在、时段仍可用、
    // 不超目标"，不解析 id 的内容。因此无论是 persistedId
    //（`<提案 id>:block:…`）还是更早期的裸 uuid，都能被认出来。
    final uuid = '3f2a1c4e-5b6d-4e7f-8a90-1b2c3d4e5f60';
    final problem = await source(
      tasks: [taskOf('alpha')],
      plan: planWith([
        PlannedBlock(
          id: uuid,
          taskId: 'alpha',
          range: TimeRange(startUtc: localAt(5, 14), endUtc: localAt(5, 15)),
        ),
      ]),
    ).load();

    final proposal = DeterministicScheduleEngine(zones).generate(problem);
    expect(
      proposal.blocks.map((block) => block.id),
      contains(uuid),
      reason: 'id 形状不该影响采纳；旧 uuid 也必须被原样保留',
    );
  });

  test('**同一份输入重复排程，块 id 与结果完全一致**', () async {
    final problem = await source(
      tasks: [taskOf('alpha'), taskOf('beta')],
      plan: planWith([
        PlannedBlock(
          id: 'proposal:old:block:alpha:100:60',
          taskId: 'alpha',
          range: TimeRange(startUtc: localAt(5, 14), endUtc: localAt(5, 15)),
        ),
      ]),
    ).load();

    final engine = DeterministicScheduleEngine(zones);
    final first = engine.generate(problem);
    final second = engine.generate(problem);
    String signature(ScheduleProposal proposal) => proposal.blocks
        .map(
          (block) =>
              '${block.id}|${block.taskId}|${block.startUtc.toIso8601String()}|'
              '${block.durationMinutes}|${block.locked}',
        )
        .join(',');

    expect(
      signature(second),
      signature(first),
      reason: '块 id 的生成必须是确定性的，不能依赖哈希或随机',
    );
  });
}
