// Task 8 Step 3（计划 §2.6／§2.7／§2.8 的跨视图一致性）：
//
// **流程**：启动 → 生成并应用计划 → **不重启**切到近期日历与日视图 → 两处出现同一份
// 课程与计划块 → 编辑固定日程 → 两处自动变更 → 完成任务 → 今日页与日视图**只给任务**
// 显示完成状态（固定日程的钟点过去不算完成，R11）。
//
// **为什么必须是集成测试**：这条链上的每一环都已经被单元/Widget 测试覆盖，但没有任何一条
// 测试把**真实组合根形状**（真实 drift 库 + 真实仓储 + 真实 `RepositoryScheduleViewSource`
// + app-scoped 失效总线）的三个页面同时挂在同一棵树上跑一遍。页面级测试之前注入的都是能
// 手工 `add()` 的假数据源（R10），因此"改完之后另外两个页面会不会自己刷新"从来没被验过。
//
// **它不重复验证的东西**：排程正确性（`test/scheduling`）、条文级的按钮层级
// （`test/features/planning`）。这里只回答一个问题：**同一件事在三个视图里是不是同一件事，
// 而且不用重启、不用手工刷新。**
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/application/schedule_view_invalidation.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/app/planner_app.dart';
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
import 'package:personal_planner/features/calendar/week_view/schedule_view_source.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const timeZoneId = 'Asia/Shanghai';

  testWidgets('应用计划与编辑日程后，近期日历／日视图／今日页在同一进程内保持一致', (tester) async {
    final zones = TimeZoneDatabase();
    const clock = SystemClock();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final taskRepository = DriftTaskRepository(database.taskDao);
    final calendarRepository = DriftCalendarRepository(database);
    final planRepository = DriftPlanRepository(database, clock: clock);
    final settingsRepository = DriftSettingsRepository(database, clock);
    final workspaceRepository = DriftWorkspaceRepository(database);

    // ── 组合根形状：**唯一**的失效总线，同时交给数据源与每个写入服务（§2.6）───
    final bus = ScheduleViewInvalidationBus();
    addTearDown(bus.dispose);
    final invalidation = ScheduleViewInvalidationWiring(bus);

    final settingsService = SettingsService(
      repository: settingsRepository,
      onPlanningRulesChanged: invalidation.planningRules,
    );
    final workspaceService = WorkspaceService(
      repository: workspaceRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
      onWorkspaceChanged: invalidation.workspace,
    );
    final scheduleColors = ScheduleColorService(
      settings: settingsRepository,
      workspace: workspaceRepository,
      onColorsChanged: invalidation.colors,
    );
    final problemSource = RepositoryScheduleProblemSource(
      tasks: taskRepository,
      lifeAreas: DriftLifeAreaLookup(database),
      calendar: calendarRepository,
      settings: settingsService,
      plans: planRepository,
      clock: clock,
      timeZoneId: timeZoneId,
      zones: zones,
    );
    final planning = PlanningService(
      source: problemSource,
      engine: DeterministicScheduleEngine(zones),
    );
    final application = PlanApplicationService(
      source: problemSource,
      repository: planRepository,
      zones: zones,
      onPlanChanged: invalidation.planAfter(() async {}),
    );
    final calendarService = CalendarService(
      repository: calendarRepository,
      deletion: calendarRepository,
      recurringRepository: calendarRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
      zones: zones,
      onScheduleInputChanged: invalidation.calendarAfter((change) {}),
    );

    // 两道闸门都要过，否则 pump 出来的是引导页或教程页而不是主界面。
    await settingsRepository.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await settingsRepository.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );

    // ── 输入：一个领域、一件任务、一节固定日程（都走生产写入路径）──────────────
    await workspaceService.ensureDefaultAreas();
    final area = (await workspaceService.listAreas()).firstWhere(
      (item) => item.name == '学业',
    );
    await TaskService(
      repository: taskRepository,
      workspace: workspaceRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
    ).saveDraft(
      TaskDraft(title: '完成课程论文', estimatedMinutes: 120, areaId: area.id),
    );
    final taskId = (await taskRepository.watchOpenTasks().first).single.id;

    final todayLocalDate = zones.toLocal(clock.nowUtc(), timeZoneId);
    final todayStartUtc = zones.localMidnightToUtc(
      DateTime(todayLocalDate.year, todayLocalDate.month, todayLocalDate.day),
      timeZoneId,
    );
    final savedLesson = await calendarService.save(
      EventDraft(
        title: '数据结构课',
        startAtUtc: todayStartUtc.add(const Duration(hours: 10)),
        endAtUtc: todayStartUtc.add(const Duration(hours: 11)),
        timeZoneId: timeZoneId,
      ),
    );
    expect(
      savedLesson.isSuccess,
      isTrue,
      reason: savedLesson.fieldErrors.toString(),
    );
    final eventId = savedLesson.event!.id;

    // ── 生成并应用计划 ────────────────────────────────────────────────────────
    final proposal = await planning.createProposal();
    expect(proposal.blocks, isNotEmpty, reason: '窗口里有充足可用时间');
    expect(proposal.metrics.isFullyFeasible, isTrue);
    final applied = await application.apply(proposal);
    expect(applied.status, ApplyPlanStatus.applied);
    // **一件 120 分钟的任务会被拆成多块**（最小片段 30），因此这里取**落在今天**的那一块：
    // 日视图只画今天，取一个别的日子的块会让后面的断言因为"卡片不在这一页上"而失败——
    // 那说明的是夹具选错了块，不是产品坏了。
    final plannedBlocks = applied.plan!.blocks;
    expect(plannedBlocks, isNotEmpty, reason: '应用后的计划必须真的有块');
    final todayRange = TimeRange(
      startUtc: todayStartUtc,
      endUtc: zones.localMidnightToUtc(
        DateTime(
          todayLocalDate.year,
          todayLocalDate.month,
          todayLocalDate.day + 1,
        ),
        timeZoneId,
      ),
    );
    final block = plannedBlocks.firstWhere(
      (item) => item.range.overlaps(todayRange),
      orElse: () => plannedBlocks.first,
    );
    final blockId = block.id;

    // ── 起应用：生产形状的数据源（**必须**接上总线，否则固定日程与计划的写入不会刷新）──
    final scheduleSource = RepositoryScheduleViewSource(
      tasks: taskRepository,
      calendar: calendarRepository,
      plans: planRepository,
      history: planRepository,
      rules: PlanningRuleResolver(settingsService),
      colors: scheduleColors,
      zones: zones,
      timeZoneId: timeZoneId,
      invalidation: bus,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          taskRepository: taskRepository,
          settingsRepository: settingsRepository,
          planRepository: planRepository,
          workspaceService: workspaceService,
          scheduleColors: scheduleColors,
          zones: zones,
          timeZoneId: timeZoneId,
          planningService: planning,
          planApplication: application,
          scheduleSource: scheduleSource,
          scheduleInvalidation: bus,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final semanticsHandle = tester.ensureSemantics();

    // ── ① 今日页：任务与课程都在 ─────────────────────────────────────────────
    await tester.tap(find.text('今日'));
    await tester.pumpAndSettle();
    expect(find.text('完成课程论文'), findsWidgets, reason: '今日页应当显示刚应用的计划块');

    // ── ② 近期日历：标题是「近期日历」，且两件事都在 ──────────────────────────
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    expect(
      find.text('近期日历'),
      findsOneWidget,
      reason: '标题必须与"昨天 + 今天起七天"共八列的范围一致（R12）',
    );
    expect(find.text('七日日历'), findsNothing, reason: '旧标题与八列范围矛盾，必须消失');
    expect(find.text('完成课程论文'), findsWidgets, reason: '近期日历要显示同一条计划块');
    expect(find.text('数据结构课'), findsWidgets, reason: '近期日历要显示同一条固定日程');

    // ── ③ 日视图：**同一份条目 id 与同一个区间**（不是两份各自算出来的数据）────
    await tester.tap(find.byKey(const Key('open-day-view')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('day-schedule-card-block:$blockId')),
      findsOneWidget,
      reason: '日视图渲染的必须是**同一条**计划块（同一 id）',
    );
    expect(
      find.byKey(Key('day-schedule-card-fixed:$eventId')),
      findsOneWidget,
      reason: '日视图渲染的必须是**同一条**固定日程（同一 id）',
    );

    // ── ④ 编辑固定日程：**不离开页面、不手工刷新**，两处都换成新标题与新时间 ────
    final updated = await calendarService.updateEvent(
      target: CalendarEditTarget(
        anchorId: eventId,
        scope: EventEditScope.entireSeries,
      ),
      event: CalendarEventEditDraft(
        title: '数据结构课（改）',
        startAtUtc: todayStartUtc.add(const Duration(hours: 14)),
        endAtUtc: todayStartUtc.add(const Duration(hours: 15)),
        timeZoneId: timeZoneId,
      ),
    );
    expect(
      updated.status,
      CalendarMutationStatus.saved,
      reason: updated.error ?? '',
    );
    await tester.pumpAndSettle();

    expect(
      find.text('数据结构课（改）'),
      findsWidgets,
      reason: '日视图必须自己收到新标题（无需离开页面或手工刷新）',
    );
    expect(find.text('数据结构课'), findsNothing, reason: '日视图不得同时留着旧标题');

    await tester.tap(find.byKey(const Key('open-week-view')));
    await tester.pumpAndSettle();
    expect(
      find.text('数据结构课（改）'),
      findsWidgets,
      reason: '近期日历也必须自己收到新标题——它和日视图订阅的是同一条总线',
    );
    expect(find.text('数据结构课'), findsNothing, reason: '近期日历不得同时留着旧标题');

    // ── ⑤ 完成任务：**只有任务**显示完成，固定日程的钟点过去不算完成（R11）────
    await tester.tap(find.text('今日'));
    await tester.pumpAndSettle();
    await TaskService(
      repository: taskRepository,
      workspace: workspaceRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
    ).changeStatus(taskId, TaskStatus.completed);
    await tester.pumpAndSettle();

    // 语义树要显式打开；**读完就把句柄还掉**——`addTearDown` 在这里太晚，
    // 集成绑定的收尾检查会先报"A SemanticsHandle was active at the end of the test"。
    final taskLabel = tester
        .getSemantics(find.byKey(ValueKey('today-schedule-block:$blockId')))
        .label;
    final fixedLabel = tester
        .getSemantics(find.byKey(ValueKey('today-schedule-fixed:$eventId')))
        .label;
    semanticsHandle.dispose();

    expect(taskLabel, contains('已完成'), reason: '任务真的完成了：今日页必须显示完成状态');
    expect(
      fixedLabel,
      isNot(contains('已完成')),
      reason: '**R11**：固定日程结束时间已过 ≠ 任务已完成，完成语义只属于 TaskStatus.completed',
    );

    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-day-view')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('day-schedule-completed-block:$blockId')),
      findsOneWidget,
      reason: '日视图里完成标记只在任务块上',
    );
    expect(
      find.byKey(Key('day-schedule-completed-fixed:$eventId')),
      findsNothing,
      reason: '**R11**：固定日程永远不带任务完成标记',
    );
  });
}
