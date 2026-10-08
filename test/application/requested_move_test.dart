// FR-CAL-05「拖动可移动任务块；手动移动后可选择锁定」与 FR-CAL-06「固定日程冲突时必须提示」。
//
// **本文件存在的理由**：这条需求此前在真实用户路径上**完全不存在**——`MoveDraftSink` 只有
// 声明、全库没有任何实现，而 `planner_app.dart` 注入的是 `DisabledWeekMoveController`。也就是说
// 周视图上确实画了 `LongPressDraggable`，但放手之后没有任何代码会读它。测试要钉住的因此不是
// "有一个拖动控件"，而是**放手之后计划真的变了**这一条端到端事实。
//
// 三个层次各自钉住一件事：
// 1. `PendingMoveDrafts`（意图的容器）：同一个块反复拖动以后一次为准；
// 2. `RepositoryScheduleProblemSource`（意图 → 排程输入）：钉住的块**替换**它原来的位置而不是
//    与之并存，时间保留原本地钟点，且"锁定/不锁定"两支产生不同的输入；
// 3. `DeterministicScheduleEngine`（输入 → 计划）：不管锁不锁，**该块都落在目标日**——这正是
//    "拖了有用"；差别只在提案里的 `locked`，那是后续重排能否再移动它的分界。
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
import 'package:personal_planner/scheduling/plan_validator.dart';
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

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';
  // 2026-10-05 02:00Z == 本地 10:00（周一）；规划窗口是本地 10-05 起的七天。
  final clock = _FixedClock(DateTime.utc(2026, 10, 5, 2));
  final created = DateTime.utc(2026, 10, 1);

  /// 周一本地 10:00–11:30（= 02:00Z–03:30Z）的一个未锁定已确认块。
  PlannedBlock mondayBlock({bool locked = false, String id = 'block-1'}) =>
      PlannedBlock(
        id: id,
        taskId: 'research',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 10, 5, 2),
          endUtc: DateTime.utc(2026, 10, 5, 3, 30),
        ),
        locked: locked,
      );

  final research = PlannerTask(
    id: 'research',
    title: '科研实验',
    priority: TaskPriority.high,
    estimatedMinutes: 180,
    remainingMinutes: 180,
    energyLevel: TaskEnergyLevel.high,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: 30,
    maxChunkMinutes: 90,
    status: TaskStatus.open,
    createdAtUtc: created,
    updatedAtUtc: created,
  );

  RepositoryScheduleProblemSource source({
    List<CalendarOccurrence> occurrences = const [],
    ConfirmedPlan? plan,
    PendingMoveDrafts? pendingMoves,
  }) => RepositoryScheduleProblemSource(
    tasks: _FakeTasks([research]),
    lifeAreas: const _NoLifeAreas(),
    calendar: _FakeCalendar(occurrences),
    settings: SettingsService(repository: MemorySettingsRepository()),
    plans: _FakePlans(plan),
    clock: clock,
    timeZoneId: zoneId,
    zones: zones,
    pendingMoves: pendingMoves,
  );

  ConfirmedPlan planWith(List<PlannedBlock> blocks) => ConfirmedPlan(
    id: 'plan-1',
    inputHash: 'hash',
    algorithmVersion: '9',
    blocks: blocks,
  );

  group('PendingMoveDrafts', () {
    test('同一个块反复拖动以后一次为准，不同块各自记住', () {
      final drafts = PendingMoveDrafts()
        ..setRequestedMove(
          RequestedMove(
            blockId: 'b1',
            localDate: DateTime(2026, 10, 6),
            lock: true,
          ),
        )
        ..setRequestedMove(
          RequestedMove(
            blockId: 'b1',
            localDate: DateTime(2026, 10, 8),
            lock: false,
          ),
        )
        ..setRequestedMove(
          RequestedMove(
            blockId: 'b2',
            localDate: DateTime(2026, 10, 7),
            lock: true,
          ),
        );

      expect(drafts.length, 2);
      expect(drafts.forBlock('b1')!.localDate, DateTime(2026, 10, 8));
      expect(drafts.forBlock('b1')!.lock, isFalse);
      expect(drafts.forBlock('b2')!.localDate, DateTime(2026, 10, 7));
      expect(drafts.forBlock('missing'), isNull);
    });
  });

  group('拖动 → 排程输入', () {
    test('钉住的块替换它原来的位置，时间保留原本地钟点', () async {
      final drafts = PendingMoveDrafts()
        ..setRequestedMove(
          RequestedMove(
            blockId: 'block-1',
            localDate: DateTime(2026, 10, 7),
            lock: true,
          ),
        );

      final problem = await source(
        plan: planWith([mondayBlock()]),
        pendingMoves: drafts,
      ).load();

      // 同一个 id 绝不能出现两次，否则引擎会排出两条。
      expect(problem.lockedBlocks, hasLength(1));
      final pinned = problem.lockedBlocks.single;
      expect(pinned.id, 'block-1');
      // 本地 10:00 搬到 10-07（周三）→ 02:00Z；时长 90 分钟不变。
      expect(pinned.range.startUtc, DateTime.utc(2026, 10, 7, 2));
      expect(pinned.range.endUtc, DateTime.utc(2026, 10, 7, 3, 30));
      // 原位置不再作为"已确认但未锁定"的块出现。
      expect(
        problem.existingBlocks.where((block) => block.id == 'block-1'),
        isEmpty,
      );
    });

    test('不锁定的拖动同样被钉住，但记进 pinnedUnlockedBlockIds', () async {
      final drafts = PendingMoveDrafts()
        ..setRequestedMove(
          RequestedMove(
            blockId: 'block-1',
            localDate: DateTime(2026, 10, 7),
            lock: true,
          ),
        );

      final draftsUnlocked = PendingMoveDrafts()
        ..setRequestedMove(
          RequestedMove(
            blockId: 'block-1',
            localDate: DateTime(2026, 10, 7),
            lock: false,
          ),
        );

      final locked = await source(
        plan: planWith([mondayBlock()]),
        pendingMoves: drafts,
      ).load();
      final unlocked = await source(
        plan: planWith([mondayBlock()]),
        pendingMoves: draftsUnlocked,
      ).load();

      expect(locked.pinnedUnlockedBlockIds, isEmpty);
      expect(unlocked.pinnedUnlockedBlockIds, {'block-1'});
      // 两支都必须把它钉在目标日——否则"没锁定"就等于"拖了没用"。
      expect(
        unlocked.lockedBlocks.single.range.startUtc,
        DateTime.utc(2026, 10, 7, 2),
      );
      // 两支的输入不同，因此哈希必须不同，否则确认阶段可能接受另一支的提案。
      expect(locked.inputHash, isNot(unlocked.inputHash));
    });

    test('已锁定的块被拖动时也只剩一条，位置换成目标日', () async {
      final drafts = PendingMoveDrafts()
        ..setRequestedMove(
          RequestedMove(
            blockId: 'block-1',
            localDate: DateTime(2026, 10, 9),
            lock: true,
          ),
        );

      final problem = await source(
        plan: planWith([mondayBlock(locked: true)]),
        pendingMoves: drafts,
      ).load();

      expect(problem.lockedBlocks, hasLength(1));
      expect(
        problem.lockedBlocks.single.range.startUtc,
        DateTime.utc(2026, 10, 9, 2),
      );
    });

    test('id 已经对不上任何已确认块时不钉任何东西（落地后自动失效）', () async {
      // 应用计划时块 id 会被重写成 `<提案 id>:<块 id>`，因此旧 id 再也匹配不上——
      // 这条性质让"待处理移动"不需要显式清理。若它不成立，用户拖动一次之后该块会被
      // 永久钉在那一天。
      final drafts = PendingMoveDrafts()
        ..setRequestedMove(
          RequestedMove(
            blockId: 'block-1',
            localDate: DateTime(2026, 10, 7),
            lock: true,
          ),
        );

      final problem = await source(
        plan: planWith([mondayBlock(id: 'plan-1:block-1')]),
        pendingMoves: drafts,
      ).load();

      expect(problem.lockedBlocks, isEmpty);
      expect(problem.pinnedUnlockedBlockIds, isEmpty);
      expect(problem.existingBlocks.single.id, 'plan-1:block-1');
    });

    test('未装配待处理移动时行为与从前完全一致', () async {
      final problem = await source(plan: planWith([mondayBlock()])).load();

      expect(problem.lockedBlocks, isEmpty);
      expect(problem.existingBlocks.single.id, 'block-1');
    });
  });

  group('拖动 → 计划（FR-CAL-05 端到端）', () {
    ScheduleProposal generate(ScheduleProblem problem) =>
        DeterministicScheduleEngine(zones).generate(problem);

    test('锁定的一支：该块落在目标日，并且在提案里就是锁定的', () async {
      final drafts = PendingMoveDrafts()
        ..setRequestedMove(
          RequestedMove(
            blockId: 'block-1',
            localDate: DateTime(2026, 10, 7),
            lock: true,
          ),
        );
      final problem = await source(
        plan: planWith([mondayBlock()]),
        pendingMoves: drafts,
      ).load();

      final proposal = generate(problem);
      final pinned = proposal.blocks.firstWhere(
        (block) => block.id == 'block-1',
      );

      expect(pinned.range.startUtc, DateTime.utc(2026, 10, 7, 2));
      expect(pinned.locked, isTrue);
      // 周二（10-06）整天不该再有这个块的旧位置。
      expect(
        proposal.blocks.where(
          (block) =>
              block.id == 'block-1' &&
              zones.toLocal(block.startUtc, zoneId).day == 5,
        ),
        isEmpty,
      );
    });

    test('不锁定的一支：该块**照样**落在目标日，但提案里是未锁定', () async {
      // 这是本设计最容易做错的地方：若把"不锁定"实现成"不钉住"，引擎会立刻把它搬回
      // 别处，用户看到的是"拖了没用"。因此生成期间必须按锁定对待，生成之后才改回未锁定。
      final drafts = PendingMoveDrafts()
        ..setRequestedMove(
          RequestedMove(
            blockId: 'block-1',
            localDate: DateTime(2026, 10, 7),
            lock: false,
          ),
        );
      final problem = await source(
        plan: planWith([mondayBlock()]),
        pendingMoves: drafts,
      ).load();

      final proposal = generate(problem);
      final pinned = proposal.blocks.firstWhere(
        (block) => block.id == 'block-1',
      );

      expect(pinned.range.startUtc, DateTime.utc(2026, 10, 7, 2));
      expect(pinned.locked, isFalse, reason: '未锁定的一支必须落地为未锁定，否则"可选择锁定"这一支没有意义');
      // 未锁定的块要计入当日可移动上限；若装配与校验两侧口径不同，这里会凭空出现
      // dailyLimitExceeded 把合法提案判为无效。
      expect(
        proposal.conflicts.where(
          (item) => item.code == ConflictCode.dailyLimitExceeded,
        ),
        isEmpty,
      );
    });

    test('没有拖动时，块不会凭空出现在目标日（判别性对照）', () async {
      final problem = await source(plan: planWith([mondayBlock()])).load();

      final proposal = generate(problem);

      // 没有意图就不该有任何 id 为 block-1 的块——它是"已确认但未锁定"的块，引擎会
      // 重新安排任务，而不是把这一块原样搬过去。
      expect(proposal.blocks.where((block) => block.id == 'block-1'), isEmpty);
    });
  });

  group('FR-CAL-06 固定日程冲突必须提示', () {
    test('拖到与固定日程重叠的位置时，冲突被报出来而不是静默覆盖', () async {
      // 目标日 10-07 的本地 10:00–11:00 有一节课（= 02:00Z–03:00Z）。
      final drafts = PendingMoveDrafts()
        ..setRequestedMove(
          RequestedMove(
            blockId: 'block-1',
            localDate: DateTime(2026, 10, 7),
            lock: true,
          ),
        );
      final problem = await source(
        plan: planWith([mondayBlock()]),
        pendingMoves: drafts,
        occurrences: [
          CalendarOccurrence(
            eventId: 'class-wed',
            title: '数据结构课',
            range: TimeRange(
              startUtc: DateTime.utc(2026, 10, 7, 2),
              endUtc: DateTime.utc(2026, 10, 7, 3),
            ),
            locked: true,
          ),
        ],
      ).load();

      final proposal = DeterministicScheduleEngine(zones).generate(problem);

      expect(
        proposal.conflicts.where(
          (item) => item.code == ConflictCode.fixedEventOverlap,
        ),
        isNotEmpty,
        reason: '与固定日程重叠必须被报出，界面据此显示「与固定日程重叠」',
      );
      // 「必须提示、不得静默覆盖」在服务层是这条：校验器认为提案非法，因此 apply 会拒绝，
      // 用户看到的是冲突而不是一次静默的覆盖。
      final applied = PlanValidator(zones).validate(problem, proposal.blocks);
      expect(
        applied.where((item) => item.code == ConflictCode.fixedEventOverlap),
        isNotEmpty,
      );
    });
  });
}

final class _NoLifeAreas implements LifeAreaLookup {
  const _NoLifeAreas();
  @override
  Future<Set<String>> lifeTaskIds() async => const {};
}
