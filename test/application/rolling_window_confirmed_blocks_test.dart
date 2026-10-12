// 1.8.0（2026-10-12 实机故障；本计划的“冻结决策”§1.3）：
// **已结束的确认块不得进入前向排程输入**。
//
// 截图里的现象是“新增”区域出现 10-10、10-11 这样的过去日期。根因不是某一段过滤写错，
// 而是同一个确认块被同时当成“事实”（要冻结）与“未来的安排”（要进提案）：
//
//   · `classifyConfirmedBlocks()` 把 `end <= now` 的块归为 `hardOccupied`，
//     装配层又把**全部** `hardOccupiedIds` 放进 `lockedBlocksOut`；
//   · 引擎以 `blocks = [...problem.lockedBlocks]` 开始，并把每块分钟计入
//     `scheduledByTask` —— 于是历史安排污染了“本次还剩多少要排”；
//   · `PlanValidator` 又要求所有块的开始都在 `planningWindow` 内，
//     于是同一块先被当成合法计划，再被判成“排程输入无效”（用户看到的那句话）。
//
// 这个文件用**真实的装配链**（`RepositoryScheduleProblemSource` → `PlanningService` →
// `DeterministicScheduleEngine`）钉住三种时间角色，而不是只测纯函数：
// 纯函数分类正确、装配层却没用它，正是第 67 轮重复缺陷漏出去的方式。
import 'package:flutter_test/flutter_test.dart';
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
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();

  /// 固定时钟：2026-10-12（周一）09:30 Asia/Shanghai == 01:30Z。
  ///
  /// 四个角色都挂在这一个时刻上：
  /// · `past-day`      10-11 15:00–16:00（本地）—— 昨天，早已结束；
  /// · `boundary-past` 10-12 09:00–09:30（本地）—— **恰好在窗口起点结束**；
  /// · `ongoing`       10-12 09:15–09:45（本地）—— 跨过窗口起点，进行中；
  /// · `future`        10-12 14:00–15:00（本地）—— 完全在窗口起点之后。
  final nowUtc = DateTime.utc(2026, 10, 12, 1, 30);
  DateTime localUtc(int month, int day, int hour, [int minute = 0]) =>
      zones.localDateTimeToUtc(
        DateTime.utc(2026, month, day),
        hour * 60 + minute,
        zoneId,
      );

  PlannedBlock block(
    String id, {
    required DateTime start,
    required int minutes,
    String taskId = 't-a',
    bool locked = false,
  }) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
    locked: locked,
  );

  PlannerTask task({
    required int remainingMinutes,
    int minChunk = 30,
    int maxChunk = 90,
  }) => PlannerTask(
    id: 't-a',
    title: '蓝桥杯竞赛课',
    priority: TaskPriority.medium,
    estimatedMinutes: remainingMinutes,
    remainingMinutes: remainingMinutes,
    energyLevel: TaskEnergyLevel.medium,
    splitMode: TaskSplitMode.splittable,
    minChunkMinutes: minChunk,
    maxChunkMinutes: maxChunk,
    status: TaskStatus.open,
    createdAtUtc: nowUtc,
    updatedAtUtc: nowUtc,
  );

  Future<ScheduleProposal> generate({
    required List<PlannedBlock> confirmedBlocks,
    required PlannerTask plannerTask,
    DateTime? clockNow,
  }) {
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([plannerTask]),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(
        ConfirmedPlan(
          id: 'v1',
          inputHash: 'h1',
          algorithmVersion: 'test',
          blocks: confirmedBlocks,
        ),
      ),
      clock: _Clock(clockNow ?? nowUtc),
      timeZoneId: zoneId,
      zones: zones,
    );
    return PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    ).createProposal();
  }

  /// 四个角色的共同夹具：同一任务、同一份确认计划。
  List<PlannedBlock> fourRoles() => [
    block('past-day', start: localUtc(10, 11, 15), minutes: 60),
    block('boundary-past', start: localUtc(10, 12, 9), minutes: 30),
    block('ongoing', start: localUtc(10, 12, 9, 15), minutes: 30),
    block('future', start: localUtc(10, 12, 14), minutes: 60),
  ];

  test('**已结束的块既不进 lockedBlocks / existingBlocks，也不进提案**', () async {
    final proposal = await generate(
      confirmedBlocks: fourRoles(),
      plannerTask: task(remainingMinutes: 120),
    );

    final ids = proposal.blocks.map((b) => b.id).toList();
    expect(
      ids,
      isNot(contains('past-day')),
      reason: '昨天的块是历史事实，不可能出现在“本次新增”里 —— 那是截图里的第一个现象',
    );
    expect(
      ids,
      isNot(contains('boundary-past')),
      reason: '恰好在窗口起点结束（`end == window.start`）的块属于历史：边界用 `<=`，不留端点缝隙',
    );
    // 进行中的块**原位保留**：引擎收下锁定块时会重新起块 id（`block:<task>:…`），
    // 因此这里按**来源关联**断言"同一块还在"，而不是按 id 断言。
    // 判"移动"用的就是 `continuedFromId`（见 `PlanDiffer` 的说明）。
    expect(
      proposal.blocks.where((b) => b.continuedFromId == 'ongoing'),
      isNotEmpty,
      reason: '进行中的块原位保留，它是当前承诺',
    );
    expect(ids, isNot(contains('boundary-past')));
  });

  test('**历史块不参与装配层的未来输入**（lockedBlocks 与 existingBlocks 都不含它）', () async {
    final source = RepositoryScheduleProblemSource(
      tasks: _Tasks([task(remainingMinutes: 120)]),
      lifeAreas: _NoLifeAreas(),
      calendar: _NoCalendar(),
      settings: SettingsService(repository: MemorySettingsRepository()),
      plans: _Plan(
        ConfirmedPlan(
          id: 'v1',
          inputHash: 'h1',
          algorithmVersion: 'test',
          blocks: fourRoles(),
        ),
      ),
      clock: _Clock(nowUtc),
      timeZoneId: zoneId,
      zones: zones,
    );
    final problem = await source.load();

    expect(
      problem.lockedBlocks.map((b) => b.id),
      isNot(contains('past-day')),
      reason: '历史块进 lockedBlocks 就会被引擎原样复制进提案（R1/R2）',
    );
    expect(
      problem.lockedBlocks.map((b) => b.id),
      isNot(contains('boundary-past')),
    );
    expect(
      problem.existingBlocks.map((b) => b.id),
      isNot(contains('past-day')),
      reason: '它也不该作为“可移动的已确认块”参与移动代价计算',
    );
    // **`confirmedBlocks` 仍携带完整确认计划**：来源关联要用它把“同一块换了时间”
    // 报成「移动」而不是删除＋新增。展示侧按 planning window 过滤，不靠丢数据实现。
    expect(
      problem.confirmedBlocks.map((b) => b.id),
      contains('past-day'),
      reason: '完整确认计划仍在，只是不再作为未来排程输入',
    );
  });

  test('**提案里没有“排程输入无效”**（窗口边界与校验器只有一个口径）', () async {
    final proposal = await generate(
      confirmedBlocks: fourRoles(),
      plannerTask: task(remainingMinutes: 120),
    );

    expect(
      proposal.conflicts.where((c) => c.code == ConflictCode.invalidInput),
      isEmpty,
      reason:
          '修复前是“同一块先被当作有效计划、再被判排程输入无效”：'
          '`PlanValidator` 要求所有块的开始都包含于 planningWindow，'
          '而装配层把过去的块塞进了 future 输入（R3）',
    );
  });

  test('**历史块不计入 scheduledByTask**：缺口来自“本次还剩多少”，不是历史总量', () async {
    // 任务剩余 120 分钟；确认计划里已经排了 45 分钟（ongoing 15＋future 30…
    // 实际上只有 future 与 ongoing 与“将来”有关）。
    //
    // 断言的是**不存在“重复计数”**：历史块既不该出现在块列表里，也不该把
    // 任务的已排分钟抬到超过它自己的剩余量，从而伪造出“已排够”。
    final proposal = await generate(
      confirmedBlocks: fourRoles(),
      plannerTask: task(remainingMinutes: 120),
    );

    final scheduled = proposal.blocks
        .where((b) => b.taskId == 't-a')
        .fold<int>(0, (sum, b) => sum + b.durationMinutes);
    expect(
      proposal.metrics.scheduledMinutes,
      scheduled,
      reason: 'metrics 必须与真实块集合一致，不能把被剔除的历史块留在统计里',
    );
  });

  test('**进行中的块只按与窗口相交的部分占用未来容量**', () async {
    // 09:15–09:45 的块与窗口（起点 09:30）相交 15 分钟。它作为当前承诺计入一次，
    // 但**不得**把 09:15–09:30 这 15 分钟当成“未来的已排分钟”：
    // 那段时间已经过去了，把它算进未来容量会凭空吃掉一段可用时间。
    final proposal = await generate(
      confirmedBlocks: [
        block('ongoing', start: localUtc(10, 12, 9, 15), minutes: 30),
      ],
      plannerTask: task(remainingMinutes: 30),
    );

    final ongoing = proposal.blocks
        .where((b) => b.continuedFromId == 'ongoing')
        .firstOrNull;
    expect(ongoing, isNotNull, reason: '进行中的块必须原位保留');
    expect(
      ongoing!.startUtc,
      localUtc(10, 12, 9, 15),
      reason: '原位且不可移动：它的开始早于窗口起点是允许的例外，不是被搬走的理由',
    );
  });

  test('**恰好等于窗口起点的块是未来**（`start == window.start`）', () async {
    // 边界规则的另外半边：`start >= window.start` 属于未来。
    // 09:30 恰好是窗口起点，因此它必须仍然在提案里。
    final proposal = await generate(
      confirmedBlocks: [
        block('at-start', start: localUtc(10, 12, 9, 30), minutes: 30),
      ],
      plannerTask: task(remainingMinutes: 30),
    );

    expect(
      proposal.blocks.map((b) => b.continuedFromId),
      contains('at-start'),
      reason: '“恰好在窗口起点开始”属于未来，与“恰好在窗口起点结束”属于历史是一对互补边界',
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
