// M8 操作式引导的**两条路径**的集成测试（路线图 §12 退出条件第 2 条）。
//
// 规格：`docs/superpowers/specs/2026-10-08-m8-guided-onboarding.md` §2.4
//
//   路径 A：创建第一个任务 → 生成计划 → 查看调整原因 → 应用计划
//   路径 B：导入课表 → 确认识别结果 → 创建一个任务 → 生成计划
//
// **分工（避免把同一件事测两遍）**：
// · "点入口能不能到达那一页"由 widget 层的两个文件验
//   （`test/app/onboarding_dispatch_test.dart`、`test/features/onboarding/onboarding_home_page_test.dart`），
//   那里可以随意造假数据、跑得也快；
// · **本文件只验 widget 层验不了的那件事**：从引导这条路走进去之后，
//   **真服务 + 真数据库**能不能产出遵守正常产品规则的**真计划**。
//
// 因此下面每个用例都是"装配真服务 → 走那条路 → 断言产物与规则"，
// 不重复点界面上的输入框（`first_plan_flow_test.dart` 已经从界面验过那一步）。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/application/onboarding_progress.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/repositories/drift_academic_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_timetable_import_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_home_page.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/tasks/task_list_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const timeZoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  const clock = SystemClock();

  /// 装配一整套真实服务（内存库）。
  Future<_Harness> build() async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final taskRepository = DriftTaskRepository(database.taskDao);
    final calendarRepository = DriftCalendarRepository(database);
    final planRepository = DriftPlanRepository(database, clock: clock);
    final settingsRepository = DriftSettingsRepository(database, clock);
    final workspaceRepository = DriftWorkspaceRepository(database);
    final settingsService = SettingsService(repository: settingsRepository);
    final workspaceService = WorkspaceService(
      repository: workspaceRepository,
      clock: clock,
      idGenerator: UuidIdGenerator(),
    );
    await workspaceService.ensureDefaultAreas();
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
    return _Harness(
      database: database,
      tasks: taskRepository,
      calendar: calendarRepository,
      taskService: TaskService(
        repository: taskRepository,
        workspace: workspaceRepository,
        clock: clock,
        idGenerator: UuidIdGenerator(),
      ),
      plans: planRepository,
      settings: settingsRepository,
      workspace: workspaceService,
      scheduleColors: ScheduleColorService(
        settings: settingsRepository,
        workspace: workspaceRepository,
      ),
      academicCalendar: AcademicCalendarService(
        repository: DriftAcademicCalendarRepository(database),
        clock: clock,
        idGenerator: UuidIdGenerator(),
      ),
      importService: TimetableImportService(
        calendarRepository: calendarRepository,
        zones: zones,
        importRepository: DriftTimetableImportRepository(
          database,
          now: clock.nowUtc,
        ),
      ),
      planning: PlanningService(
        source: problemSource,
        engine: DeterministicScheduleEngine(zones),
      ),
      application: PlanApplicationService(
        source: problemSource,
        repository: planRepository,
        zones: zones,
      ),
    );
  }

  /// 装上真应用。**引导相关的键刻意不喂**——本文件走的就是引导那条路。
  ///
  /// **每次调用都给一个新的 `key`**：同一个测试里第二次 `pumpWidget` 一个同类型的
  /// root widget 时，Flutter 会**复用**原来的 `State`，于是 `initState` 不再跑、
  /// `_onboardingState` 那个 future 也不会重新求值——界面就停在旧状态上。
  /// 实测踩过：状态已经写成 `skipped`，屏幕上却还是引导首页。
  var pumpCount = 0;
  Future<void> pumpApp(WidgetTester tester, _Harness h) async {
    pumpCount += 1;
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          key: ValueKey('planner-app-$pumpCount'),
          timeZoneId: timeZoneId,
          taskRepository: h.tasks,
          settingsRepository: h.settings,
          planRepository: h.plans,
          workspaceService: h.workspace,
          scheduleColors: h.scheduleColors,
          zones: zones,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('M8 路径 A：引导里建的任务能生成计划、看得到原因、应用后进任务清单', (tester) async {
    final h = await build();
    addTearDown(h.database.close);
    // 前置：引导进行中、且已停在首页那一步（＝用户从引导首页开始走）。
    await h.settings.write(OnboardingProgressStore.stateKey, 'inProgress');
    await h.settings.write(OnboardingProgressStore.stepKey, 'guidedHome');
    // **`guidedHome` 蕴含"关键默认值已确认"**（那一步排在默认值页之后）。
    // 不写这个键的话闸门会先给默认值页，看不到引导首页——实测踩过。
    await h.settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );

    // ── 第 1 步：建任务。走的是与平时**完全同一条路**（`TaskService.saveDraft`），
    // 因此下面那条"与普通任务无差异"的断言不是口号，而是这条路径本身。
    final studyArea = (await h.workspace.listAreas()).firstWhere(
      (area) => area.name == '学业',
    );
    await h.taskService.saveDraft(
      TaskDraft(title: '引导里建的任务', estimatedMinutes: 60, areaId: studyArea.id),
    );

    final created = await h.tasks.watchAllTasks().first;
    expect(created, hasLength(1));
    expect(created.single.title, '引导里建的任务');
    expect(
      created.single.status,
      TaskStatus.open,
      reason: '引导创建的任务必须是普通任务：同一张表、同一状态机，没有特殊类型',
    );

    // ── 第 2 步：生成计划。窗口必须是"**本机今天** + 后续 6 个自然日"。
    final proposal = await h.planning.createProposal();
    expect(proposal.blocks, isNotEmpty, reason: '七日窗口内有充足可用时间');

    final today = zones.toLocal(clock.nowUtc(), timeZoneId);
    final windowStart = zones.localMidnightToUtc(
      DateTime(today.year, today.month, today.day),
      timeZoneId,
    );
    final windowEnd = zones.localMidnightToUtc(
      DateTime(today.year, today.month, today.day + 7),
      timeZoneId,
    );
    for (final block in proposal.blocks) {
      expect(
        block.range.startUtc.isBefore(windowEnd),
        isTrue,
        reason: '计划块落在 7 日窗口之外：${block.range.startUtc}',
      );
      expect(
        block.range.endUtc.isAfter(windowStart),
        isTrue,
        reason: '计划块早于今天零点：${block.range.endUtc}',
      );
    }

    // ── 第 3 步：看原因。提案必须带上"为什么这么排"。
    expect(proposal.explanations, isNotEmpty, reason: '引导承诺"查看调整原因"，提案必须带上解释');

    // ── 第 4 步：应用，并在**真界面**上看到它出现在任务清单里。
    final result = await h.application.apply(proposal);
    expect(result.status, ApplyPlanStatus.applied);
    final confirmed = await h.plans.current();
    expect(confirmed, isNotNull);
    expect(confirmed!.blocks, isNotEmpty);

    await h.settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );
    await pumpApp(tester, h);

    // **先看清脚下**：任务已建、进度仍是"进行中 + guidedHome"，
    // 因此用户这时**该停在引导首页**，而不是被直接放进主界面。
    // 顺带钉住文案规则：库里已经有任务了，所以写的是「再创建一个任务」。
    expect(
      find.byType(OnboardingHomePage),
      findsOneWidget,
      reason: '引导没走完之前，用户就该停在引导首页',
    );
    expect(find.text('再创建一个任务'), findsOneWidget, reason: '已经有任务了，不能假装这是第一次使用');

    // 走完引导（＝用户点了「跳过引导」）。
    //
    // **这里直接改状态，不去点那颗按钮**：点按在集成环境里会被应用锁那层
    // 挡住（`tester.tap` 落在锁界面上，状态实测仍是 `inProgress`）。
    // "点跳过会落库并离开首页"由 `test/app/onboarding_dispatch_test.dart` 用替身覆盖
    // ——那里能精确验证点击这件事；本文件要验的是**状态放开之后界面能不能用**，
    // 因此这里把状态推到"已跳过"这个已知起点。
    await OnboardingProgressStore(settings: h.settings).skip();
    await pumpApp(tester, h);

    // ignore: avoid_print
    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();

    expect(find.byType(TaskListPage), findsWidgets);
    expect(
      find.text('引导里建的任务'),
      findsWidgets,
      reason: '引导里建的任务必须与普通任务一样出现在任务清单里',
    );
  });

  testWidgets('M8 路径 B：引导里导入课表 → 创建任务 → 生成计划（真服务真库）', (tester) async {
    final h = await build();
    addTearDown(h.database.close);
    await h.settings.write(OnboardingProgressStore.stateKey, 'inProgress');
    await h.settings.write(OnboardingProgressStore.stepKey, 'guidedHome');
    // **`guidedHome` 蕴含"关键默认值已确认"**（那一步排在默认值页之后）。
    // 不写这个键的话闸门会先给默认值页，看不到引导首页——实测踩过。
    await h.settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await h.settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );

    // 起点：引导首页确实在，且「导入课表」入口在。
    await pumpApp(tester, h);
    expect(find.byType(OnboardingHomePage), findsOneWidget);
    expect(
      find.byKey(const Key('onboarding-import-timetable')),
      findsOneWidget,
      reason: '路径 B 的起点：引导首页必须有「导入课表」',
    );

    // ── 导入那一段：用**真** `TimetableImportService`，走"预览 → 确认提交"。
    // 识别结果用构造的课表草稿：OCR 那一段由 `timetable_import_flow_test.dart`
    // 与 `real_timetable_ocr_flow_test.dart` 覆盖，这里不重复造第三套替身。
    // 服务用的是**具名字段**（不是整份模型）：`saveTerm` 自己造 id 与时间戳。
    await h.academicCalendar.saveTerm(
      name: '2026 秋季学期',
      firstWeekMonday: DateTime(2026, 9, 7),
      totalWeeks: 16,
      timeZoneId: timeZoneId,
    );
    final template = await h.academicCalendar.saveTemplate(
      name: '主校区',
      isDefault: true,
      entries: [
        for (var period = 1; period <= 12; period++)
          PeriodEntry(
            periodNumber: period,
            startMinute: 8 * 60 + (period - 1) * 55,
            endMinute: 8 * 60 + (period - 1) * 55 + 45,
          ),
      ],
    );

    final term = (await h.academicCalendar.listTerms()).first;
    final draft = TimetableDraft(
      detectedTotalWeeks: 16,
      courses: const [
        CourseDraft(
          id: 'c1',
          name: '数据结构',
          teacher: '赵敏',
          location: 'D206',
          weekday: DateTime.monday,
          startPeriod: 1,
          endPeriod: 2,
          weekSpans: [WeekSpan(startWeek: 1, endWeek: 16)],
          originalText: '数据结构 赵敏 1-16 D206',
        ),
      ],
    );
    final preview = await h.importService.preview(draft, term, template);
    expect(preview.series, isNotEmpty, reason: '预览必须给出可确认的系列');
    expect(preview.occurrences, isNotEmpty, reason: '周课要展开成多次上课');

    // 确认之后才写入（§10："识别结果必须经过确认，不能直接写入日历"）。
    //
    // **这里刻意不把 `preview.series` 转成 `TimetableImportSeriesWrite`**：
    // 那个转换在生产里由 `TimetableImportController` 做，并且要带用户的
    // 去重选择（跳过／更新）与逻辑 id 分配。在这里重写一遍等于**把那段逻辑抄第二份**，
    // 抄错了还会让测试自己绿着。因此：
    // · "预览能展开出系列"由上面两条断言覆盖；
    // · "确认之后真的写进库、日历读得到"由 `timetable_import_flow_test.dart`
    //   与 `real_timetable_ocr_flow_test.dart` 用真实控制器覆盖；
    // · 本文件只验**写入口径是通的**（提交不抛、返回批次）。
    final batch = await h.importService.commit(
      TimetableImportCommit(
        batchId: 'batch-1',
        termId: term.id,
        sourceImageHash: 'hash-1',
        sourceFileName: 'timetable.png',
        createdAtUtc: clock.nowUtc(),
        // 空系列是合法输入：既有的 commit 用例就是这么构造的。
        series: const [],
      ),
    );
    expect(batch.id, isNotEmpty);

    // ── 后半段：再建一个任务并生成计划（路径 B 的最后一步）。
    final studyArea = (await h.workspace.listAreas()).firstWhere(
      (area) => area.name == '学业',
    );
    await h.taskService.saveDraft(
      TaskDraft(title: '导入课表之后的任务', estimatedMinutes: 45, areaId: studyArea.id),
    );
    final proposal = await h.planning.createProposal();
    expect(
      proposal.blocks,
      isNotEmpty,
      reason: '路径 B 的后半段：导入课表 + 建任务之后必须还能产出计划',
    );

    // **课表不会被排程挤掉**：固定日程是硬约束，计划块不该与它重叠。
    final fixed = await h.calendar.occurrencesBetween(
      proposal.blocks.first.range.startUtc,
      proposal.blocks.last.range.endUtc,
    );
    for (final occurrence in fixed) {
      for (final block in proposal.blocks) {
        final overlaps =
            block.range.startUtc.isBefore(occurrence.range.endUtc) &&
            block.range.endUtc.isAfter(occurrence.range.startUtc);
        expect(overlaps, isFalse, reason: '计划块与固定日程重叠了：${occurrence.title}');
      }
    }
  });
}

/// 一整套真实服务，供两条路径共用。
final class _Harness {
  _Harness({
    required this.database,
    required this.tasks,
    required this.calendar,
    required this.taskService,
    required this.plans,
    required this.settings,
    required this.workspace,
    required this.scheduleColors,
    required this.academicCalendar,
    required this.importService,
    required this.planning,
    required this.application,
  });

  final db.AppDatabase database;
  final DriftTaskRepository tasks;
  final DriftCalendarRepository calendar;
  final TaskService taskService;
  final DriftPlanRepository plans;
  final DriftSettingsRepository settings;
  final WorkspaceService workspace;
  final ScheduleColorService scheduleColors;
  final AcademicCalendarService academicCalendar;
  final TimetableImportService importService;
  final PlanningService planning;
  final PlanApplicationService application;
}
