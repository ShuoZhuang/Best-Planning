import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
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
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_source.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

/// 端到端流程：录入任务 → 生成七日计划 → 确认应用 → 界面显示已确认的计划块。
///
/// 这是产品最核心的承诺（"用户只提供任务和时长即可获得未来七天的日程建议"）
/// 第一次被完整地穿过：仓储 → 排程输入装配 → 引擎 → 提案校验与落库 → 周视图。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const timeZoneId = 'Asia/Shanghai';

  testWidgets('录入任务后可以生成、确认并在周视图看到首个七日计划', (tester) async {
    final zones = TimeZoneDatabase();
    const clock = SystemClock();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final taskRepository = DriftTaskRepository(database.taskDao);
    final calendarRepository = DriftCalendarRepository(database);
    final planRepository = DriftPlanRepository(database, clock: clock);
    final settingsRepository = DriftSettingsRepository(database, clock);
    final settingsService = SettingsService(repository: settingsRepository);
    final ruleResolver = PlanningRuleResolver(settingsService);
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
    );

    // 引导已完成，否则应用会先显示引导页而不是主界面。
    await settingsRepository.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    // **首次教程闸门是另一条独立的门**（同样是"设置键 + 版本比较"）：不喂这一条，
    // 整个应用 pump 出来的是**教程页**而不是主界面，下面的 `find.text('日历')` 自然
    // 一个都找不到。仓库里 15 个其它 pump `PlannerApp` 的测试都写了这一条，
    // **只有这个集成测试漏了**——因此它从教程闸门加入那天起就一直失败，
    // 而路线图 §15 要求逐条跑通这四个集成测试。
    await settingsRepository.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );

    // 快速录入：只提供标题与预计时长。
    final workspaceRepository = DriftWorkspaceRepository(database);
    final workspaceService = WorkspaceService(
      repository: workspaceRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
    );
    final scheduleColors = ScheduleColorService(
      settings: settingsRepository,
      workspace: workspaceRepository,
    );
    await workspaceService.ensureDefaultAreas();
    final studyArea = (await workspaceService.listAreas()).firstWhere(
      (area) => area.name == '学业',
    );
    final taskService = TaskService(
      repository: taskRepository,
      workspace: workspaceRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
    );
    await taskService.saveDraft(
      TaskDraft(title: '完成课程论文', estimatedMinutes: 180, areaId: studyArea.id),
    );
    final openTasks = await taskRepository.watchOpenTasks().first;
    expect(openTasks, hasLength(1));
    expect(openTasks.single.title, '完成课程论文');

    // 生成提案并确认应用。
    final proposal = await planning.createProposal();
    expect(proposal.blocks, isNotEmpty, reason: '七日窗口内有充足可用时间');
    expect(proposal.metrics.isFullyFeasible, isTrue);

    final result = await application.apply(proposal);
    expect(result.status, ApplyPlanStatus.applied);
    final confirmed = await planRepository.current();
    expect(confirmed, isNotNull);
    expect(confirmed!.blocks, isNotEmpty);

    // 同一份数据驱动的界面应当显示已确认的计划块。
    final scheduleSource = RepositoryScheduleViewSource(
      tasks: taskRepository,
      calendar: calendarRepository,
      plans: planRepository,
      history: planRepository,
      rules: ruleResolver,
      colors: scheduleColors,
      zones: zones,
      timeZoneId: timeZoneId,
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    expect(find.text('完成课程论文'), findsWidgets);
  });
}
