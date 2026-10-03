import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:personal_planner/app/backup_assembly.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/application/focus_evidence_recorder.dart';
import 'package:personal_planner/application/notification_service.dart';
import 'package:personal_planner/application/pending_moves.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/recovery_planning_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/tag_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/local_time_zone.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/database/daos/analytics_dao.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_analytics_event_log.dart';
import 'package:personal_planner/data/repositories/drift_export_data_source.dart';
import 'package:personal_planner/data/repositories/drift_focus_entry_store.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_preference_evidence_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_tag_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_correction_log.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';

import 'package:personal_planner/features/calendar/week_view/schedule_view_source.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/platform/notifications/windows_notification_adapter.dart';
import 'package:personal_planner/platform/files/file_selector_adapter.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';
import 'package:personal_planner/platform/windows/windows_package_identity.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 组合根：在这里把数据库、仓库、排程引擎与应用服务装配成一个可运行的应用。
///
/// 在此之前 `PlannerApp` 只拿到任务与设置仓储，排程引擎、`PlanningService` 与
/// `PlanApplicationService` 从未被构造，今日页与周视图注入的是恒空的
/// `EmptyScheduleViewSource`，因此排程链路在真实运行中完全不可达（偏差 W1–W2）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 数据库路径必须在**打开数据库之前**确定：备份要复制这个文件，而用户安排的恢复也要在此
  // 刻完成替换（见 backup_assembly.dart 对"为什么等到启动"的说明）。
  final databasePath = await preparePlannerDatabase();

  const clock = SystemClock();
  final zones = TimeZoneDatabase();

  // 需求 §13 要求以本机当前时区保存和展示。Dart 读不到 IANA 标识，因此按本机
  // 当前偏移解析（见 LocalTimeZoneResolver）。解析不出精确匹配时仍取最接近的
  // 时区，但会在诊断里说明——目前只在开发期记录，用户可见的提示待首次引导实现。
  final resolvedZone = LocalTimeZoneResolver(
    zones,
  ).resolve(localOffset: DateTime.now().timeZoneOffset, nowUtc: clock.nowUtc());
  final timeZoneId = resolvedZone.timeZoneId;
  if (!resolvedZone.exact) {
    debugPrint('未能精确匹配本机时区：${resolvedZone.diagnostic}');
  }

  final database = AppDatabase.openDefault();
  // 数据备份页所需的服务（W3 的最后一条缺失路由）。它依赖真实的数据库路径，因此在这里装。
  final backups = await buildBackupService(
    database: database,
    clock: clock,
    databasePath: databasePath,
  );
  final taskRepository = DriftTaskRepository(database.taskDao);
  final calendarRepository = DriftCalendarRepository(database);
  // 行为事件（FR-STAT 的建议采纳行为）。此前 `change_log` 只有计划生命周期事件，
  // 而统计读的是 interruption/replan/suggestion 三类行为事件，因此那几项恒为空（W5）。
  //
  // **必须在 `CalendarService` 之前构造**：日历服务也要用它记"重排原因"（见下），因此它的
  // 声明位置从原来的偏好学习那一段上移到这里。构造本身只依赖数据库，上移不改变任何行为。
  final analyticsEvents = DriftAnalyticsEventLog(
    database,
    idGenerator: UuidIdGenerator(),
  );
  final calendarService = CalendarService(
    repository: calendarRepository,
    recurringRepository: calendarRepository,
    // FR-CAL-01 的删除：同一个仓储实例也实现删除端口。不装配它会让界面上出现一个点了
    // 不生效的删除按钮（服务返回 false），因此这一行是"入口可达"的必要条件。
    deletion: calendarRepository,
    clock: clock,
    idGenerator: UuidIdGenerator(),
    zones: zones,
    // FR-STAT-06 的"重排原因"的**第二个写入方**（另一个在任务服务，见下方 `PlannerApp`）。
    // 固定日程占用的时间是排程的硬约束，因此它的增删改同样会改变排程；此前这条路径登记为
    // "未覆盖"（§13.0 W9 的 (a)），于是统计里的"重排原因"看起来像完整分布，实际缺了日历
    // 这一整类。两个写入方共用同一份 lambda 形状与同一个事件端口，此处不新造一套口径。
    onScheduleInputChanged: (reasonCode) => analyticsEvents.record(
      kind: AnalyticsEventKind.replan,
      code: reasonCode,
      observedAtUtc: clock.nowUtc(),
    ),
  );
  final planRepository = DriftPlanRepository(database, clock: clock);
  final settingsRepository = DriftSettingsRepository(database, clock);

  final settingsService = SettingsService(repository: settingsRepository);
  final ruleResolver = PlanningRuleResolver(settingsService);
  // FR-CAL-05：手动拖动的意图。**同一个实例必须同时给"记录的落点"（周视图经 PlannerApp）
  // 与"消费的通道"（下面的排程输入来源）**——只给一侧就是"拖了没用"或"记了没人看"，这正是
  // 本次之前的状态（接口没有任何实现，且组合根注入的是 DisabledWeekMoveController）。
  final pendingMoves = PendingMoveDrafts();
  final problemSource = RepositoryScheduleProblemSource(
    tasks: taskRepository,
    lifeAreas: DriftLifeAreaLookup(database),
    calendar: calendarRepository,
    settings: settingsService,
    plans: planRepository,
    clock: clock,
    timeZoneId: timeZoneId,
    zones: zones,
    pendingMoves: pendingMoves,
  );

  // 通知此前完全没有生产装配：`NotificationService` 的四类通知、提前时间的钳制修正
  // 与点击回调虽然都已实现并有测试，却没有任何调用方，因此真实运行中永远不会安排
  // 提醒。这里把它接上。
  //
  final notifications = WindowsNotificationAdapter(
    hasPackageIdentity: hasWindowsPackageIdentity(),
  );
  // 最近一次生成的提案。冲突**不是持久事实**，只活在提案里，因此"冲突待处理"通知必须有一个
  // 持有者——此前应用里没有任何组件持有它，于是那一类通知只能被跳过而不是伪造（R8 ③；与 W9
  // 同源：两处缺的都是"谁持有当前待处理的提案"）。声明必须在通知服务之前，因为它的来源要用它。
  ScheduleProposal? latestProposal;
  final notificationService = NotificationService(
    plans: planRepository,
    settings: settingsService,
    notifications: notifications,
    clock: clock,
    zones: zones,
    timeZoneId: timeZoneId,
    calendar: calendarRepository,
    tasks: taskRepository,
    // 冲突不是持久事实而是每次排程的产物：来源就是上面那个"最近一次生成的提案"。
    // 尚未生成过提案时返回空表，该类通知因此被跳过（而不是伪造一条）。
    pendingConflicts: () async => latestProposal?.conflicts ?? const [],
  );

  // 启动即同步未来七天的提醒，但不阻塞首屏：通知不是启动的必要条件，平台侧失败也不
  // 应让应用起不来。
  unawaited(() async {
    try {
      await notificationService.syncNextSevenDays();
    } on Object catch (error) {
      debugPrint('启动时同步提醒失败：$error');
    }
  }());

  // 首次运行建立默认领域。生活标记只存在于领域上，因此没有领域，`is_life` 就无人赋值，
  // 生活配额与统计的"生活"分类都不会生效——默认领域是这两条链路的前置条件，不是示例数据。
  // `ensureDefaultAreas` 只在**一个领域都没有**时写入，因此不会覆盖用户自己的整理结果。
  final workspaceRepository = DriftWorkspaceRepository(database);
  final workspaceService = WorkspaceService(
    repository: workspaceRepository,
    clock: clock,
    idGenerator: UuidIdGenerator(),
  );
  unawaited(() async {
    try {
      await workspaceService.ensureDefaultAreas();
    } on Object catch (error) {
      debugPrint('建立默认领域失败：$error');
    }
  }());

  // 标签此前只有两张表：没有任何写入方，因此界面上无法建立标签、也无法把它打到任务上，
  // 统计的标签筛选即便修好取数也没有数据可筛（R1）。
  final tagService = TagService(
    repository: DriftTagRepository(database),
    clock: clock,
    idGenerator: UuidIdGenerator(),
  );

  // 应用锁此前只有设置页与服务：`AppLockService.verify` 没有启动调用方，因此锁只能被
  // 开启、永远不会拦住任何人（W6）。凭据存在设置仓库里，与设置页共用同一份，
  // 因为"是否上锁"必须与"能否解锁"来自同一个来源。
  final appLockService = AppLockService(
    store: SettingsAppLockCredentialStore(settingsRepository),
  );

  // 数据导出（FR-DATA-06）。服务、数据源与文件适配器此前都已写好并有测试，但生产代码里
  // 从未构造过任何一个，因此"导出"在真实运行中不可达（W3/W6 同类的"没装配"）。
  // 注意目录选择与写文件是平台行为，本机只能经假端口验证，见 §13.0。
  const exportFiles = FileSelectorAdapter();
  final exportService = ExportService(
    source: DriftExportDataSource(database),
    files: exportFiles,
    clock: clock,
  );

  // 偏好学习的闭环（FR-PREF-01/03/04）。此前两端都断：`PreferenceEvidence` 零构造
  // （没有任何代码写证据），且 `PreferenceService.refresh(evidence)` 没有任何生产调用方
  // （只有测试调用），因此建议永远不会被生成。这里把两端接上——专注结束时写证据，
  // 打开偏好页时按证据重新分析。
  final preferenceEvidence = DriftPreferenceEvidenceRepository(database);
  final focusEvidence = FocusEvidenceRecorder(
    evidence: preferenceEvidence,
    tasks: taskRepository,
    workspace: workspaceRepository,
    zones: zones,
    timeZoneId: timeZoneId,
    clock: clock,
    idGenerator: UuidIdGenerator(),
  );
  final focusService = FocusService(
    store: DriftFocusEntryStore(database),
    clock: clock,
    monotonicClock: StopwatchMonotonicClock(),
    idGenerator: UuidIdGenerator(),
    onFinished: focusEvidence.recordCompletedFocus,
    // FR-STAT-06 的"常见中断"来源：**暂停即记一次**。标签写成人类可读的"专注中暂停"，
    // 因为统计页直接把它显示给用户（而不是显示一个内部代码）。
    onInterrupted: (session) => analyticsEvents.record(
      kind: AnalyticsEventKind.interruption,
      code: '专注中暂停',
      observedAtUtc: clock.nowUtc(),
      entityId: session.taskId,
    ),
  );

  // "信任自动调整"是持久设置，但它驱动的只是一个内存 store；此前该 store 每次启动都是新的，
  // 且只有打开设置页时才被灌入持久值——于是同一个设置在不同启动里表现不同（W8）。
  // 这里在启动时就用持久值初始化它，与默认领域、应用锁同在组合根。
  final autoAdjustStore = MemoryAutoAdjustStore();
  unawaited(() async {
    try {
      autoAdjustStore.setEnabled(await settingsService.loadTrustAutoAdjust());
    } on Object catch (error) {
      debugPrint('读取"信任自动调整"设置失败：$error');
    }
  }());

  // 排程服务：每次生成提案后把最近一份交给上面那个持有者，冲突通知因此有了真实来源。
  final planningService = PlanningService(
    source: problemSource,
    engine: DeterministicScheduleEngine(zones),
    onProposalCreated: (proposal) => latestProposal = proposal,
  );
  // 特殊日与次日恢复保护（Task 11）。C8 修复后例外是**提案输入**而不是持久设置，
  // 因此这条链路必须真正可达：页面早已存在，却从来没有路由（W3）。
  final recovery = RecoveryPlanningService(
    planning: planningService,
    zones: zones,
  );

  runApp(
    ProviderScope(
      child: PlannerApp(
        taskRepository: taskRepository,
        // 同一实例既负责安排提醒，也把"用户点击通知"交回来（FR-NOTIFY-04）。
        notifications: notifications,
        settingsRepository: settingsRepository,
        planRepository: planRepository,
        correctionLog: DriftTaskCorrectionLog(database),
        // 与启动时的默认领域初始化共用同一实例：任务详情页要用它列出项目，
        // 用户才能把任务归属到领域下的项目（R2）。
        workspaceService: workspaceService,
        // 任务详情页的标签区（FR-TASK-02）。与统计的标签筛选读的是同一批表。
        tagService: tagService,
        // 启动门控：锁开启时必须先解锁；设置页也用它开启/关闭（需求 §11.3）。
        appLock: appLockService,
        exportService: exportService,
        // 任务详情页的"开始专注"入口与 /focus/:taskId 路由（FR-FOCUS-01）。
        focusService: focusService,
        // 偏好页的分析输入（FR-PREF-03 的样本积累靠历史证据，因此给一个足够长的窗口）。
        loadPreferenceEvidence: () => preferenceEvidence.since(
          clock.nowUtc().subtract(const Duration(days: 180)),
        ),
        // 偏好页的建议动作写进行为事件，统计的"建议采纳行为"因此有了数据来源。
        onSuggestionAction: (action, suggestionId) => analyticsEvents.record(
          kind: AnalyticsEventKind.suggestion,
          code: action,
          observedAtUtc: clock.nowUtc(),
          entityId: suggestionId,
        ),
        // FR-STAT-06 的"重排原因"来源：任务的截止日期／优先级／剩余时长／状态变化各记一条
        // `replan:` 事件。此前这一类**没有任何写入方**，统计页那一行因此永远空着（W5）。
        onScheduleInputChanged: (reasonCode) => analyticsEvents.record(
          kind: AnalyticsEventKind.replan,
          code: reasonCode,
          observedAtUtc: clock.nowUtc(),
        ),
        // 启动时已按持久设置初始化（W8）。
        autoAdjustStore: autoAdjustStore,
        // FR-CAL-05：与上面那个排程输入来源共用同一实例。
        pendingMoves: pendingMoves,
        analytics: AnalyticsService(
          source: AnalyticsDao(database),
          // FR-STAT-05 的精力分桶按**本地时刻**归桶，因此这里必须把时区交进去；
          // 不交则该节不显示（而不是按 UTC 算出一组错误的时段）。
          zones: zones,
          timeZoneId: timeZoneId,
        ),
        backups: backups,
        preferences: PreferenceService(
          analyzer: const RuleBasedPreferenceAnalyzer(),
          store: SettingsPreferenceStore(settingsRepository),
        ),
        zones: zones,
        timeZoneId: timeZoneId,
        planningService: planningService,
        // 特殊日页要装配"当日规则 + 当日固定日程"，因此两样依赖都交下去（W3）。
        recovery: recovery,
        calendar: calendarRepository,
        calendarService: calendarService,
        planApplication: PlanApplicationService(
          source: problemSource,
          repository: planRepository,
          zones: zones,
        ),
        scheduleSource: RepositoryScheduleViewSource(
          tasks: taskRepository,
          calendar: calendarRepository,
          plans: planRepository,
          rules: ruleResolver,
          zones: zones,
          timeZoneId: timeZoneId,
        ),
      ),
    ),
  );
}
