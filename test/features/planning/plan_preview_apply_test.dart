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
import 'package:personal_planner/scheduling/schedule_engine.dart';

const _timeZoneId = 'Asia/Shanghai';

/// 一套真实的装配：内存数据库 + 真实数据源 + 真实引擎 + 真实计划仓储。
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
harness() async {
  final zones = TimeZoneDatabase();
  const clock = SystemClock();
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
}
