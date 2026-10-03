import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_rule_resolver.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/local_time_zone.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_correction_log.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_source.dart';
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

  runApp(
    ProviderScope(
      child: PlannerApp(
        taskRepository: taskRepository,
        settingsRepository: settingsRepository,
        planRepository: planRepository,
        correctionLog: DriftTaskCorrectionLog(database),
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
