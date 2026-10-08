// M4「跳过本次」（2026-10-07 用户定义）：把用户那六条要求钉成测试。
//
// 用户的原话要点：
//   1. 当前时间块从今天的"待执行时间线"中移除；
//   2. 任务仍是未完成待办、剩余时长不变（已专注部分由既有专注重算扣减）；
//   3. 系统重新寻找截止时间前的下一个合理空档；
//   4. 默认显示调整预览；信任自动调整时可直接应用；
//   5. **不能无条件塞到明天**；
//   6. 排不下时标记"待安排／有逾期风险"并说明缺多少。
//
// 并且**三个动作必须分开**：跳过本次 / 延后到明天 / 取消任务。
//
// 这一组测试全部落在**装配层**（`RepositoryScheduleProblemSource`）：用户要的
// "块消失、任务还在、时段没被锁成禁区、没有指定明天"这几条都发生在这里，
// 因此这里才是它们的事实来源。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/pending_skips.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

const _timeZoneId = 'Asia/Shanghai';

/// 固定"现在"：2026-10-07（周三）08:00 本地。
final _now = DateTime.utc(2026, 10, 7, 0);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

Future<
  ({
    RepositoryScheduleProblemSource source,
    PendingSkipDrafts skips,
    DriftPlanRepository plans,
    TaskService tasks,
    void Function() dispose,
  })
>
harness({PendingSkipDrafts? skips}) async {
  final zones = TimeZoneDatabase();
  const clock = _Clock();
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final taskRepository = DriftTaskRepository(database.taskDao);
  final planRepository = DriftPlanRepository(database, clock: clock);
  final workspaceRepository = DriftWorkspaceRepository(database);
  final workspaceService = WorkspaceService(
    repository: workspaceRepository,
    clock: clock,
    idGenerator: UuidIdGenerator(),
  );
  await workspaceService.ensureDefaultAreas();
  final area = (await workspaceService.listAreas()).firstWhere(
    (item) => item.name == '学业',
  );
  final tasks = TaskService(
    repository: taskRepository,
    workspace: workspaceRepository,
    clock: clock,
    idGenerator: UuidIdGenerator(),
  );
  // 余下 120 分钟、可拆分：留下充足的"排得下"空间。
  await tasks.saveDraft(
    TaskDraft(title: '算法作业', estimatedMinutes: 120, areaId: area.id),
  );

  final sink = skips ?? PendingSkipDrafts();
  return (
    source: RepositoryScheduleProblemSource(
      tasks: taskRepository,
      lifeAreas: DriftLifeAreaLookup(database),
      calendar: DriftCalendarRepository(database),
      settings: SettingsService(
        repository: DriftSettingsRepository(database, clock),
      ),
      plans: planRepository,
      clock: clock,
      timeZoneId: _timeZoneId,
      zones: zones,
      pendingSkips: sink,
    ),
    skips: sink,
    plans: planRepository,
    tasks: tasks,
    dispose: database.close,
  );
}

/// 往已确认计划里放一个块，返回那个块。
Future<PlannedBlock> seedBlock(
  DriftPlanRepository plans, {
  required String blockId,
  required String taskId,
  required DateTime startUtc,
  required Duration length,
  bool locked = false,
}) async {
  final block = PlannedBlock(
    id: blockId,
    taskId: taskId,
    range: TimeRange(startUtc: startUtc, endUtc: startUtc.add(length)),
    locked: locked,
  );
  final result = await plans.applyProposal(
    ScheduleProposal(
      proposalId: 'seed-proposal',
      inputHash: 'seed-hash',
      algorithmVersion: 'v1',
      blocks: [block],
      conflicts: const [],
      unscheduled: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 60,
        unscheduledMinutes: 0,
      ),
    ),
    'seed-hash',
  );
  expect(result.status.name, 'applied', reason: '前置条件：种下一个已确认块');
  final confirmed = await plans.current();
  // `applyProposal` 会把块 id 重写成 `<提案 id>:<块 id>`，所以取回真实的那个 id。
  return confirmed!.blocks.firstWhere((item) => item.taskId == taskId);
}

void main() {
  test('M4 跳过之后：该块从 lockedBlocks 与 existingBlocks 两处都消失', () async {
    final h = await harness();
    addTearDown(h.dispose);
    final block = await seedBlock(
      h.plans,
      blockId: 'b1',
      taskId: (await h.tasks.watchOpenTasks().first).single.id,
      startUtc: DateTime.utc(2026, 10, 7, 6), // 本地 14:00
      length: const Duration(hours: 1),
      locked: true,
    );

    // 前置条件：没跳过时它确实被冻结着。
    final before = await h.source.load();
    expect(
      before.lockedBlocks.map((item) => item.id),
      contains(block.id),
      reason: '前置条件：未跳过时该块在 lockedBlocks 里',
    );

    h.skips.setRequestedSkip(RequestedSkip(blockId: block.id));
    final after = await h.source.load();

    expect(
      after.lockedBlocks.map((item) => item.id),
      isNot(contains(block.id)),
      reason: '跳过的块不该再被冻结',
    );
    expect(
      after.existingBlocks.map((item) => item.id),
      isNot(contains(block.id)),
      reason: '跳过的块也不该作为"可移动的已确认块"留在输入里',
    );
  });

  test('M4 跳过**不会**把旧时段锁成禁区（空出来就是给别人用）', () async {
    final h = await harness();
    addTearDown(h.dispose);
    final task = (await h.tasks.watchOpenTasks().first).single;
    final start = DateTime.utc(2026, 10, 7, 6); // 本地 14:00–15:00
    final block = await seedBlock(
      h.plans,
      blockId: 'b1',
      taskId: task.id,
      startUtc: start,
      length: const Duration(hours: 1),
    );
    h.skips.setRequestedSkip(RequestedSkip(blockId: block.id));

    final problem = await h.source.load();
    final skippedRange = TimeRange(
      startUtc: start,
      endUtc: start.add(const Duration(hours: 1)),
    );

    // 用户跳过的是"这件事现在不做"，**不是**"这段时间不许安排别的事"。
    // 若把它锁成禁区，"跳过之后空出来"就变成"跳过之后白白浪费"。
    for (final busy in [
      ...problem.fixedIntervals,
      ...problem.protectedIntervals,
    ]) {
      expect(
        busy.range.overlaps(skippedRange),
        isFalse,
        reason: '跳过不得把旧时段变成禁区（${busy.id}）',
      );
    }
  });

  test('M4 跳过之后任务仍是未完成待办，剩余时长不变', () async {
    final h = await harness();
    addTearDown(h.dispose);
    final task = (await h.tasks.watchOpenTasks().first).single;
    final before = (await h.tasks.findById(task.id))!;
    final block = await seedBlock(
      h.plans,
      blockId: 'b1',
      taskId: task.id,
      startUtc: DateTime.utc(2026, 10, 7, 6),
      length: const Duration(hours: 1),
    );

    h.skips.setRequestedSkip(RequestedSkip(blockId: block.id));
    final problem = await h.source.load();

    // ① 任务仍在待排集合里——跳过不退出排程（那是"取消任务"）。
    expect(
      problem.tasks.map((item) => item.id),
      contains(task.id),
      reason: '跳过只放弃块，任务必须继续参与重排',
    );
    // ② 剩余时长照旧：已专注的部分由既有专注重算扣减，这里**不重算**。
    expect(problem.tasks.single.requiredMinutes, before.remainingMinutes);
    final after = (await h.tasks.findById(task.id))!;
    expect(after.status, TaskStatus.open, reason: '跳过不得改任务状态');
    expect(after.remainingMinutes, before.remainingMinutes);
  });

  test('M4 跳过**不指定明天**：不得碰 availableFromUtc 与 dueAtUtc', () async {
    final h = await harness();
    addTearDown(h.dispose);
    final task = (await h.tasks.watchOpenTasks().first).single;
    final before = (await h.tasks.findById(task.id))!;
    final block = await seedBlock(
      h.plans,
      blockId: 'b1',
      taskId: task.id,
      startUtc: DateTime.utc(2026, 10, 7, 6),
      length: const Duration(hours: 1),
    );

    h.skips.setRequestedSkip(RequestedSkip(blockId: block.id));
    final problem = await h.source.load();

    // 用户第 5 条：新时间可能是今天稍后、明天或其他日期，**不能无条件塞到明天**。
    // 因此"跳过"绝不能去改"最早开始时间"——那正是「延后到明天」这个**另一个动作**的做法。
    expect(
      problem.tasks.single.availableFromUtc,
      before.availableFromUtc,
      reason: '跳过不得改最早开始时间（那是「延后到明天」）',
    );
    // 用户第 3 条要求"在截止时间前"找空档，因此截止时间也不能被跳过动过。
    expect(problem.tasks.single.dueAtUtc, before.dueAtUtc, reason: '跳过不得改截止时间');
    final after = (await h.tasks.findById(task.id))!;
    expect(after.availableFromUtc, before.availableFromUtc);
    expect(after.dueAtUtc, before.dueAtUtc);
    expect(after.status, isNot(TaskStatus.cancelled), reason: '跳过不是「取消任务」');
  });

  test('M4 没有跳过意图时行为与从前完全一致', () async {
    // 回归防线：`pendingSkips` 为空时，装配结果不该有任何变化。
    final h = await harness();
    addTearDown(h.dispose);
    final task = (await h.tasks.watchOpenTasks().first).single;
    final block = await seedBlock(
      h.plans,
      blockId: 'b1',
      taskId: task.id,
      startUtc: DateTime.utc(2026, 10, 7, 6),
      length: const Duration(hours: 1),
      locked: true,
    );

    final problem = await h.source.load();
    expect(
      problem.lockedBlocks.map((item) => item.id),
      contains(block.id),
      reason: '没有跳过意图时，原本锁定的块必须照旧被冻结',
    );
  });

  test('M4 跳过只影响被点的那一块，同一任务的其他块不受影响', () async {
    // 粒度是"块"而不是"任务"：同一任务今天有两段时，跳过一段不该把两段都丢掉。
    final h = await harness();
    addTearDown(h.dispose);
    final task = (await h.tasks.watchOpenTasks().first).single;

    final first = PlannedBlock(
      id: 'b1',
      taskId: task.id,
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 7, 6),
        endUtc: DateTime.utc(2026, 10, 7, 7),
      ),
      locked: true,
    );
    final second = PlannedBlock(
      id: 'b2',
      taskId: task.id,
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 7, 8),
        endUtc: DateTime.utc(2026, 10, 7, 9),
      ),
      locked: true,
    );
    await h.plans.applyProposal(
      ScheduleProposal(
        proposalId: 'seed-pair',
        inputHash: 'seed',
        algorithmVersion: 'v1',
        blocks: [first, second],
        conflicts: const [],
        unscheduled: const [],
        explanations: const [],
        metrics: const ProposalMetrics(
          isFullyFeasible: true,
          scheduledMinutes: 120,
          unscheduledMinutes: 0,
        ),
      ),
      'seed',
    );
    final confirmed = (await h.plans.current())!;
    expect(confirmed.blocks.length, 2);
    final target = confirmed.blocks.firstWhere(
      (item) => item.range.startUtc == DateTime.utc(2026, 10, 7, 6),
    );
    final keeper = confirmed.blocks.firstWhere(
      (item) => item.range.startUtc == DateTime.utc(2026, 10, 7, 8),
    );

    h.skips.setRequestedSkip(RequestedSkip(blockId: target.id));
    final problem = await h.source.load();
    final lockedIds = problem.lockedBlocks.map((item) => item.id).toList();

    expect(lockedIds, isNot(contains(target.id)), reason: '被点的那一块消失');
    expect(lockedIds, contains(keeper.id), reason: '同一任务的另一块必须留着');
  });
}
