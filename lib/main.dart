import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/application/notification_service.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/local_time_zone.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/database/daos/analytics_dao.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_correction_log.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_source.dart';
import 'package:personal_planner/platform/notifications/windows_notification_adapter.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

/// 组合根：在这里把数据库、仓库、排程引擎与应用服务装配成一个可运行的应用。
///
/// 在此之前 `PlannerApp` 只拿到任务与设置仓储，排程引擎、`PlanningService` 与
/// `PlanApplicationService` 从未被构造，今日页与周视图注入的是恒空的
/// `EmptyScheduleViewSource`，因此排程链路在真实运行中完全不可达（偏差 W1–W2）。
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  const clock = SystemClock();
  final zones = TimeZoneDatabase();

  // 需求 §13 要求以本机当前时区保存和展示。Dart 读不到 IANA 标识，因此按本机
  // 当前偏移解析（见 LocalTimeZoneResolver）。解析不出精确匹配时仍取最接近的
  // 时区，但会在诊断里说明——目前只在开发期记录，用户可见的提示待首次引导实现。
  final resolvedZone = LocalTimeZoneResolver(zones).resolve(
    localOffset: DateTime.now().timeZoneOffset,
    nowUtc: clock.nowUtc(),
  );
  final timeZoneId = resolvedZone.timeZoneId;
  if (!resolvedZone.exact) {
    debugPrint('未能精确匹配本机时区：${resolvedZone.diagnostic}');
  }

  final database = AppDatabase.openDefault();
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

  // 通知此前完全没有生产装配：`NotificationService` 的四类通知、提前时间的钳制修正
  // 与点击回调虽然都已实现并有测试，却没有任何调用方，因此真实运行中永远不会安排
  // 提醒。这里把它接上。
  //
  // `hasPackageIdentity` 取默认的 false：运行时无法判定当前是否以 MSIX 安装启动，
  // 而报 false 只会让"可靠取消"降级为不可用并给出诊断，方向是安全的——不会假装
  // 能取消掉已经交给系统的旧提醒。首次发布前需补上真实判定（见 Task 20）。
  final notifications = WindowsNotificationAdapter();
  final notificationService = NotificationService(
    plans: planRepository,
    settings: settingsService,
    notifications: notifications,
    clock: clock,
    zones: zones,
    timeZoneId: timeZoneId,
    calendar: calendarRepository,
    tasks: taskRepository,
    // 冲突不是持久事实而是每次排程的产物，这里暂不提供来源，因此"冲突待处理"通知
    // 会被跳过而不是伪造一条。
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
  final workspaceService = WorkspaceService(
    repository: DriftWorkspaceRepository(database),
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

  runApp(
    ProviderScope(
      child: PlannerApp(
        taskRepository: taskRepository,
        // 同一实例既负责安排提醒，也把"用户点击通知"交回来（FR-NOTIFY-04）。
        notifications: notifications,
        settingsRepository: settingsRepository,
        planRepository: planRepository,
        correctionLog: DriftTaskCorrectionLog(database),
        analytics: AnalyticsService(source: AnalyticsDao(database)),
        preferences: PreferenceService(
          analyzer: const RuleBasedPreferenceAnalyzer(),
          store: SettingsPreferenceStore(settingsRepository),
        ),
        zones: zones,
        timeZoneId: timeZoneId,
        planningService: PlanningService(
          source: problemSource,
          engine: DeterministicScheduleEngine(zones),
        ),
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
