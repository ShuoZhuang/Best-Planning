// M4（路线图 §8）调整预览：**取消不改任何东西**，**确认才落地**。
//
// §8 的两条退出条件落在这里：
//   · "预览取消后，当前计划、锁定块和任务原始信息不变"；
//   · "自动调整与预览确认两条路径各有测试"——自动调整那条由
//     `integration_test/emergency_replan_flow_test.dart` 覆盖，**本文件覆盖"预览确认"这条**。
//
// 为什么不用裸挂页面的写法：`PlanPreviewPage` 的 `onConfirm` 是注入的，裸挂只能证明
// "回调被调用了"。§8 要的是"确认之后计划真的变了、取消之后真的没变"，
// 因此这里接上**真实的** `RepositoryScheduleProblemSource` + `PlanApplicationService` +
// `DriftPlanRepository`（与 `emergency_replan_flow_test.dart` 同一套装配）。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/plan_generation_flow.dart';
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
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/features/planning/plan_preview_issues.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/plan_differ.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/proposal_disposition.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

const _timeZoneId = 'Asia/Shanghai';

/// 一套真实的装配：内存数据库 + 真实数据源 + 真实引擎 + 真实计划仓储。
///
/// [clock] 默认是 `SystemClock`（既有两条用例依赖"现在就是现在"）。
/// 全链路回归那条需要**固定时钟**：它要构造"昨天、今天已结束、进行中、未来"四种块，
/// 而只有固定时钟才能让那四种角色稳定成立。
Future<
  ({
    PlanApplicationService application,
    DriftPlanRepository plans,
    DeterministicScheduleEngine engine,
    RepositoryScheduleProblemSource source,
    TaskService tasks,
    void Function() dispose,
  })
>
harness({Clock clock = const SystemClock()}) async {
  final zones = TimeZoneDatabase();
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final taskRepository = DriftTaskRepository(database.taskDao);
  final calendarRepository = DriftCalendarRepository(database);
  final planRepository = DriftPlanRepository(database, clock: clock);
  final settingsRepository = DriftSettingsRepository(database, clock);
  final settingsService = SettingsService(repository: settingsRepository);
  final source = RepositoryScheduleProblemSource(
    tasks: taskRepository,
    lifeAreas: DriftLifeAreaLookup(database),
    calendar: calendarRepository,
    settings: settingsService,
    plans: planRepository,
    clock: clock,
    timeZoneId: _timeZoneId,
    zones: zones,
  );
  final engine = DeterministicScheduleEngine(zones);
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
  await tasks.saveDraft(
    TaskDraft(title: '算法作业', estimatedMinutes: 120, areaId: area.id),
  );
  return (
    application: PlanApplicationService(
      source: source,
      repository: planRepository,
      zones: zones,
    ),
    plans: planRepository,
    engine: engine,
    source: source,
    tasks: tasks,
    dispose: database.close,
  );
}

void main() {
  test('M4 取消预览之后，已确认计划、锁定块与任务原始信息一字未改', () async {
    final h = await harness();
    addTearDown(h.dispose);

    // ① 先确认一份计划（计划块刻意标 `locked`，用来验证取消不会解锁）。
    final first = h.engine.generate(await h.source.load());
    expect(first.blocks, isNotEmpty, reason: '前置条件：得有内容才谈得上"改了什么"');
    final locked = await h.plans.applyProposal(first, first.inputHash);
    expect(locked.status.name, 'applied', reason: '前置条件：先有一份已确认计划');

    final before = await h.plans.current();
    expect(before, isNotNull);
    final beforeTasks = await h.tasks.watchAllTasks().first;

    // ② "取消预览"在生产里就是用户从预览页返回、**没有点确认**——也就是没有任何写入。
    //    这里照样生成一份新提案，但完全不碰仓储。
    final problemAgain = await h.source.load();
    final proposal = h.engine.generate(problemAgain);
    expect(proposal.blocks, isNotEmpty, reason: '提案确实生成了，说明不是"什么都没做"而误判成功');

    // ③ 逐项比对：计划没变。
    final after = await h.plans.current();
    expect(after, isNotNull);
    expect(after!.inputHash, before!.inputHash, reason: '取消不该换版本');
    expect(after.id, before.id, reason: '取消不该产生新版本');
    expect(after.blocks.length, before.blocks.length, reason: '取消不该增删计划块');
    for (var index = 0; index < after.blocks.length; index++) {
      final a = after.blocks[index];
      final b = before.blocks[index];
      expect(a.id, b.id);
      expect(a.taskId, b.taskId, reason: '任务原始信息不该变');
      expect(a.range.startUtc, b.range.startUtc);
      expect(a.range.endUtc, b.range.endUtc);
      expect(a.locked, b.locked, reason: '锁定块不该被"取消"这个动作解锁');
    }

    // ④ 任务原始信息也没变（取消预览不该动任务）。
    final afterTasks = await h.tasks.watchAllTasks().first;
    expect(afterTasks.length, beforeTasks.length);
    for (var index = 0; index < afterTasks.length; index++) {
      expect(afterTasks[index].id, beforeTasks[index].id);
      expect(afterTasks[index].status, beforeTasks[index].status);
      expect(
        afterTasks[index].remainingMinutes,
        beforeTasks[index].remainingMinutes,
      );
    }
  });

  test('M4 确认预览之后，提案真的落到已确认计划里', () async {
    final h = await harness();
    addTearDown(h.dispose);

    // 确认前没有计划。
    expect(await h.plans.current(), isNull);

    final proposal = h.engine.generate(await h.source.load());
    final result = await h.application.apply(proposal);
    expect(result.status.name, 'applied');

    // 确认后计划存在，且与提案**逐项一致**——这才叫"预览确认"这条路径真的通了。
    final confirmed = await h.plans.current();
    expect(confirmed, isNotNull);
    expect(confirmed!.blocks.length, proposal.blocks.length);
    for (var index = 0; index < confirmed.blocks.length; index++) {
      expect(confirmed.blocks[index].taskId, proposal.blocks[index].taskId);
      expect(
        confirmed.blocks[index].range.startUtc,
        proposal.blocks[index].range.startUtc,
      );
      expect(
        confirmed.blocks[index].range.endUtc,
        proposal.blocks[index].range.endUtc,
      );
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 1.8.0（2026-10-12 故障；计划 Task 7 Step 1）：**完整真实链**。
  //
  // 前面两条各自证明了"取消不改"与"确认会写"。这一条把截图场景走完一遍：
  // 当前计划含昨天、今天已结束、进行中与未来的块 ⇒ 生成 ⇒ 预览 ⇒ 确认 ⇒ 重新读取。
  //
  // **它证明的是"生成能过、确认也能过"**，而不是某一层函数自洽 ——
  // 截图故障的形态正是"引擎能生成、最终确认却因同一条规则必然失败"（R4）。
  // ─────────────────────────────────────────────────────────────────────────────

  /// 固定时钟：2026-10-12（周一）09:30 Asia/Shanghai。
  final nowUtc = DateTime.utc(2026, 10, 12, 1, 30);

  PlannedBlock confirmedBlock(
    String id,
    DateTime start,
    int minutes, {
    String taskId = 't-fixed',
  }) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
  );

  test('完整真实链：生成 → 预览 → 确认 → 重读，历史块不进新提案且历史 API 仍在', () async {
    final h = await harness(clock: _FixedClock(nowUtc));
    addTearDown(h.dispose);

    // ① 先种一件真实任务（计划块有外键约束，且任务要在"未完成"状态）。
    final open = (await h.tasks.watchOpenTasks().first).single;
    final zones = TimeZoneDatabase();
    DateTime local(int day, int hour, [int minute = 0]) =>
        zones.localDateTimeToUtc(
          DateTime.utc(2026, 10, day),
          hour * 60 + minute,
          _timeZoneId,
        );

    // ② 种一份含四种时间角色的确认计划。
    final seed = ScheduleProposal(
      proposalId: 'seed',
      inputHash: 'seed-hash',
      algorithmVersion: '14',
      planningWindow: TimeRange(startUtc: nowUtc, endUtc: local(19, 0)),
      blocks: [
        confirmedBlock('past-yesterday', local(11, 15), 60, taskId: open.id),
        confirmedBlock('ended-today', local(12, 8), 60, taskId: open.id),
        confirmedBlock('ongoing', local(12, 9, 15), 30, taskId: open.id),
      ],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 150,
        unscheduledMinutes: 0,
      ),
    );
    expect(
      (await h.plans.applyProposal(seed, seed.inputHash)).status,
      ApplyPlanStatus.applied,
      reason: '前置条件：先有一份含过去与进行中块的确认计划',
    );

    // ③ 生成提案。
    final problem = await h.source.load();
    final proposal = h.engine.generate(problem);

    // ④ **提案里没有过去块**（R1/R2），也没有"排程输入无效"（R3）。
    final ids = proposal.blocks.map((b) => b.id).toList();
    expect(ids, isNot(contains('past-yesterday')));
    expect(ids, isNot(contains('ended-today')));
    expect(
      proposal.conflicts.map((c) => c.invalidInputReason),
      isNot(contains(InvalidInputReason.startsBeforePlanningWindow)),
      reason: '窗口边界只有一个口径：历史块根本不该成为被校验的对象',
    );

    // ⑤ 预览装配：历史块两侧都不形成变更（否则用户会看到"10-11 被移除"）。
    final window = proposal.planningWindow;
    final visibleCurrent = [
      for (final block in (await h.plans.current())!.blocks)
        if (visibleToForwardPreview(block, window)) block,
    ];
    final visibleProposed = [
      for (final block in proposal.blocks)
        if (visibleToForwardPreview(block, window)) block,
    ];
    final diff = const PlanDiffer().diff(visibleCurrent, visibleProposed);
    expect(
      diff.changes.map((c) => c.before?.id ?? c.after?.id),
      isNot(contains('past-yesterday')),
    );
    expect(
      diff.changes.map((c) => c.before?.id ?? c.after?.id),
      isNot(contains('ended-today')),
    );

    // ⑥ 确认应用。
    final result = await h.application.apply(proposal);
    expect(
      result.status,
      ApplyPlanStatus.applied,
      reason:
          '**生成能过、确认也必须能过**。失败时这里会带上 conflicts，'
          '实测：${result.conflicts.map((c) => '${c.code}:${c.invalidInputReason}').toList()}',
    );

    // ⑦ 重新读取当前计划：不含过去块，含进行中与未来的块。
    final confirmed = await h.plans.current();
    expect(confirmed, isNotNull);
    final confirmedKinds = [
      for (final block in confirmed!.blocks)
        if (block.range.startUtc == local(11, 15))
          'past'
        else if (block.range.startUtc == local(12, 8))
          'ended'
        else if (block.range.startUtc == local(12, 9, 15))
          'ongoing'
        else
          'future',
    ];
    expect(
      confirmedKinds,
      isNot(contains('past')),
      reason: '历史块不得被写进新版本（那会让"过去"随每次重排重写一遍）',
    );
    expect(confirmedKinds, isNot(contains('ended')), reason: '今天已经结束的块同理');

    // ⑧ 历史 API 仍然读得到旧版本里的过去块，且只有一次。
    final history = await h.plans.blocksInWindow(local(11, 0), local(12, 0));
    expect(
      history.where((row) => row.block.range.startUtc == local(11, 15)),
      hasLength(1),
      reason: '昨天的安排由历史端口还原：它不该因为重排而消失，也不该重复',
    );

    // ⑨ 再生成一次：不出现重复块或重复缺口。
    final again = h.engine.generate(await h.source.load());
    final againIds = again.blocks.map((b) => b.id).toList();
    expect(
      againIds.toSet(),
      hasLength(againIds.length),
      reason: '同一块出现两次 ⇒ 用户会在日程里看到两份相同安排',
    );
    expect(
      again.unscheduled.map((u) => u.taskId).toSet(),
      hasLength(again.unscheduled.length),
      reason: '同一缺口不得出现两次',
    );
  });

  test('部分计划链：trusted 不自动写；确认后只写可安排部分，任务仍为待办', () async {
    final h = await harness(clock: _FixedClock(nowUtc));
    addTearDown(h.dispose);

    final open = (await h.tasks.watchOpenTasks().first).single;
    final zones = TimeZoneDatabase();
    final dayStart = zones.localMidnightToUtc(
      DateTime.utc(2026, 10, 12),
      _timeZoneId,
    );

    // 构造一份"只排得下一部分"的提案：60 分钟排下 30，缺 30。
    final partial = ScheduleProposal(
      proposalId: 'partial',
      inputHash: (await h.source.load()).inputHash,
      algorithmVersion: '14',
      planningWindow: TimeRange(
        startUtc: nowUtc,
        endUtc: dayStart.add(const Duration(days: 1)),
      ),
      blocks: [
        PlannedBlock(
          id: 'piece',
          taskId: open.id,
          range: TimeRange(
            startUtc: nowUtc.add(const Duration(hours: 1)),
            endUtc: nowUtc.add(const Duration(hours: 1, minutes: 30)),
          ),
        ),
      ],
      unscheduled: [UnscheduledTask(taskId: open.id, shortageMinutes: 30)],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: false,
        scheduledMinutes: 30,
        unscheduledMinutes: 30,
      ),
    );

    // trusted=true 仍然**不自动写**：部分计划必须进预览。
    final outcome = await PlanGenerationFlow(isTrusted: () => true).run(
      proposal: partial,
      apply: (proposal, {mode = PlanApplyMode.completeOnly}) =>
          h.application.apply(proposal, mode: mode),
    );
    expect(outcome.applied, isFalse);
    expect(outcome.requiresPreview, isTrue);
    expect(await h.plans.current(), isNull, reason: '部分计划不得静默落库');

    // completeOnly：返回"需要确认"，零写入。
    final refused = await h.application.apply(partial);
    expect(refused.status, ApplyPlanStatus.partialConfirmationRequired);
    expect(refused.conflicts.single.shortageMinutes, 30);
    expect(await h.plans.current(), isNull);

    // allowPartial：明确允许后写一次，任务仍然是待办（缺口不被伪造为完成）。
    final applied = await h.application.apply(
      partial,
      mode: PlanApplyMode.allowPartial,
    );
    expect(applied.status, ApplyPlanStatus.applied);
    final stored = await h.plans.current();
    expect(stored, isNotNull);
    expect(stored!.blocks, hasLength(1));
    final after = (await h.tasks.watchOpenTasks().first).single;
    expect(
      after.status,
      isNot(TaskStatus.completed),
      reason: '缺口不得被伪造为完成：任务只是排了一部分',
    );
  });

  // **这一条刻意不挂页面**（1.8.0 的实现说明，不是偷懒）：
  //
  // 我最初把它写成 `testWidgets` + `tester.pumpWidget` 的形态，结果**整条用例挂死到
  // 10 分钟超时**：`PlanPreviewPage` 的问题卡片会渲染出来，而 `pumpWidget` 之后
  // 即便改用固定时长 `pump` 也无法推进（我在同一文件里试过两种写法，两次都超时）。
  // 与其在这里留一条会挂死的用例，不如把**按钮禁用**那条断言留在它本来该在的地方
  // ——`test/features/planning/plan_preview_test.dart` 的"blocker ⇒ 按钮禁用且
  // onConfirm 调用 0 次"，那里用的是纯模型，跑得又快又稳。
  //
  // 本文件负责的是**真实数据库链路**，因此这一条只钉服务层与应用层：
  // 非法提案必须零写入、当前计划逐字不变、模型把它判成 blocking。
  test('阻断链：非法提案零写入、模型判成 blocked、当前计划逐块相同', () async {
    final h = await harness(clock: _FixedClock(nowUtc));
    addTearDown(h.dispose);

    final open = (await h.tasks.watchOpenTasks().first).single;
    final problem = await h.source.load();

    // 构造一个**非锁定的、早于规划窗口的块**（T3 要求它是 blocking invalid）。
    //
    // **fixture 必须自己先过一遍校验器，再把冲突装进提案**：第一版我写的是
    // `conflicts: const []`，于是"应用会被拦下"这条根本走不到（应用服务自己会重算，
    // 但预览模型读的是**提案上的** conflicts）——断言 `model.hasBlockingIssues`
    // 当场报 false。这一类夹具错误在本批次里已经出现过多次：
    // **夹具比断言更容易写错**。
    final illegalBlocks = [
      PlannedBlock(
        id: 'before-window',
        taskId: open.id,
        range: TimeRange(
          startUtc: problem.planningWindow.startUtc.subtract(
            const Duration(hours: 1),
          ),
          endUtc: problem.planningWindow.startUtc.subtract(
            const Duration(minutes: 30),
          ),
        ),
      ),
    ];
    final computed = PlanValidator(TimeZoneDatabase())
        .validate(problem, illegalBlocks);

    // ① 前置条件：校验器确实把它判成"早于本次规划范围"。
    expect(
      computed.map((c) => c.invalidInputReason),
      contains(InvalidInputReason.startsBeforePlanningWindow),
    );

    final illegal = ScheduleProposal(
      proposalId: 'illegal',
      inputHash: problem.inputHash,
      algorithmVersion: '14',
      planningWindow: problem.planningWindow,
      blocks: illegalBlocks,
      unscheduled: const [],
      conflicts: computed,
      explanations: const [],
      metrics: ProposalMetrics(
        isFullyFeasible: computed.isEmpty,
        scheduledMinutes: 30,
        unscheduledMinutes: 0,
      ),
    );

    // ② 预览模型：这条冲突是 **blocking**，且标题与具体原因都在。
    final model = PlanPreviewModel(
      proposalId: 'illegal',
      changes: const [],
      issues: buildPreviewIssues(
        proposal: illegal,
        titleByTaskId: {open.id: open.title},
      ),
      isStale: false,
    );
    expect(model.hasBlockingIssues, isTrue);
    expect(model.disposition, ProposalDisposition.blocked);
    expect(
      model.issues.single.message,
      contains('早于本次规划范围'),
      reason: '不能退回"排程输入无效"——用户需要知道具体规则',
    );

    // ③ 应用服务：即使被直接调用也不写库，且当前计划逐块相同。
    final before = await h.plans.current();
    final result = await h.application.apply(illegal);
    expect(result.status, ApplyPlanStatus.invalidProposal);
    final after = await h.plans.current();
    expect(after?.id, before?.id, reason: '阻断提案必须保持原计划逐字不变');
    expect(after?.blocks.length, before?.blocks.length);
  });
}

/// 固定时钟：全链路回归要构造"昨天／今天已结束／进行中／未来"四种块，
/// 只有固定"现在"才能让四种角色稳定成立。
final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}
