import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/application/recovery_planning_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/tag_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';
import 'package:personal_planner/features/analytics/analytics_page.dart';
import 'package:personal_planner/features/calendar/day_view/day_view_page.dart';
import 'package:personal_planner/features/calendar/event_editor/event_editor_form.dart';
import 'package:personal_planner/features/calendar/special_day/special_day_page.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/week_view_page.dart';
import 'package:personal_planner/features/focus/focus_page.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/settings/app_lock/app_lock_page.dart';
import 'package:personal_planner/features/settings/data/export_page.dart';
import 'package:personal_planner/features/settings/planning_rules/planning_rules_page.dart';
import 'package:personal_planner/features/settings/preferences/preferences_page.dart';
import 'package:personal_planner/features/settings/settings_hub_page.dart';
import 'package:personal_planner/features/tasks/task_detail_page.dart';
import 'package:personal_planner/features/tasks/task_list_page.dart';
import 'package:personal_planner/features/today/today_page.dart';
import 'package:personal_planner/features/workspace/workspace_management_page.dart';
import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/plan_differ.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 组装应用路由。
///
/// `planningService`、`planApplication` 与 `plans` 可为空：在不带数据库的测试
/// 场景下（例如只构造 `PlannerApp()`），今日页与周视图仍可显示真实数据源给出的
/// 内容，而"生成计划"入口会隐藏、调整预览会明确提示计划服务不可用，而不是
/// 显示一个点了没反应的按钮。
GoRouter createPlannerRouter({
  required TaskService taskService,
  required SettingsService settingsService,
  required ScheduleViewSource scheduleSource,
  required WeekMoveController moveController,
  required AutoAdjustStore autoAdjustStore,
  required DateTime todayStartUtc,
  required TimeZoneDatabase zones,
  required String timeZoneId,
  PlanningService? planningService,
  PlanApplicationService? planApplication,
  PlanRepository? plans,
  AnalyticsQuery? analytics,
  PreferenceService? preferences,
  WorkspaceService? workspaceService,
  TagService? tagService,
  AppLockService? appLock,
  ExportService? exportService,
  FocusService? focusService,
  Future<List<PreferenceEvidence>> Function()? loadPreferenceEvidence,
  void Function(String action, String suggestionId)? onSuggestionAction,
  RecoveryPlanningService? recovery,
  CalendarRepository? calendar,
  CalendarService? calendarService,
  DateTime? nowUtc,
}) => GoRouter(
  initialLocation: '/today',
  routes: [
    ShellRoute(
      builder: (context, state, child) => _PlannerShell(
        location: state.uri.path,
        onGeneratePlan: planningService == null
            ? null
            : (shellContext) => _generatePlan(shellContext, planningService),
        onSpecialDay: recovery == null || calendar == null
            ? null
            : (shellContext) => shellContext.go('/special-day'),
        child: child,
      ),
      routes: [
        GoRoute(
          path: '/today',
          builder: (context, state) =>
              TodayPage(source: scheduleSource, day: todayStartUtc),
        ),
        GoRoute(
          path: '/tasks',
          builder: (context, state) => TaskListPage(
            service: taskService,
            nowUtc: nowUtc ?? todayStartUtc,
            // FR-TASK-03 的"批量调整"最后一环。整批共用同一天，因此**只换算一次**；
            // 页面不认识时区，本地日期到 UTC 的换算在此完成（与"设置截止时间"同一模式）。
            onSetDueDateForSelection: (taskIds, localDate, minute) async {
              final dueAtUtc = zones.localDateTimeToUtc(
                localDate,
                minute,
                timeZoneId,
              );
              var allSaved = true;
              for (final id in taskIds) {
                final result = await taskService.setDueDate(id, dueAtUtc);
                allSaved = allSaved && result.isSuccess;
              }
              return allSaved;
            },
          ),
        ),
        GoRoute(
          // 通知 payload 里的 route 就指向这里（FR-NOTIFY-04 的快捷入口），
          // 此前该路由不存在，点击提醒无处可去。
          path: '/tasks/:taskId',
          builder: (context, state) => TaskDetailPage(
            service: taskService,
            workspace: workspaceService,
            // FR-TASK-02 的标签入口。为空时该区不显示，其余部分照常可用。
            tags: tagService,
            // FR-FOCUS-01 的入口。页面不认识路由，导航由这里注入。
            onStartFocus: focusService == null
                ? null
                : () => context.go('/focus/${state.pathParameters['taskId']!}'),
            taskId: state.pathParameters['taskId']!,
            nowUtc: nowUtc ?? todayStartUtc,
            // FR-REPLAN-07 的"设置截止时间"。页面把**本地**日期与"当天第几分钟"交回，
            // 时区换算是这里的事——路由持有 `zones` 与 `timeZoneId`，页面两者都不需要。
            onSetDueDate: (localDate, minute) async {
              final result = await taskService.setDueDate(
                state.pathParameters['taskId']!,
                zones.localDateTimeToUtc(localDate, minute, timeZoneId),
              );
              return result.isSuccess;
            },
          ),
        ),
        GoRoute(
          // 专注计时（FR-FOCUS-01）。页面早已存在，但从未有路由，也没有任何界面指向它，
          // 因此计时在真实运行中完全不可达（W3）。
          path: '/focus/:taskId',
          builder: (context, state) {
            final service = focusService;
            if (service == null) {
              return const _UnavailablePage(
                title: '专注计时',
                message: '专注服务未装配，暂无法计时。',
              );
            }
            return _FocusLoader(
              focus: service,
              tasks: taskService,
              taskId: state.pathParameters['taskId']!,
            );
          },
        ),
        GoRoute(
          path: '/calendar',
          builder: (context, state) => WeekViewPage(
            source: scheduleSource,
            weekStart: todayStartUtc,
            moveController: moveController,
            onProposalCreated: (proposalId) =>
                context.go('/planning/preview/$proposalId'),
            // FR-CAL-03 的日视图入口：与周视图互为切换，不占导航项。
            onOpenDay: (dayStartUtc) => context.go(
              '/calendar/day/${dayStartUtc.microsecondsSinceEpoch}',
            ),
            onCreateEvent: calendarService == null
                ? null
                : () => context.go('/calendar/new'),
          ),
        ),
        GoRoute(
          path: '/calendar/new',
          builder: (context, state) {
            final service = calendarService;
            if (service == null) {
              return const _UnavailablePage(
                title: '新建固定日程',
                message: '日历写入服务未装配，暂无法新建固定日程。',
              );
            }
            final localDay = zones.toLocal(todayStartUtc, timeZoneId);
            final startUtc = zones.localDateTimeToUtc(
              DateTime(localDay.year, localDay.month, localDay.day),
              9 * 60,
              timeZoneId,
            );
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            tooltip: '返回日历',
                            onPressed: () => context.go('/calendar'),
                            icon: const Icon(Icons.arrow_back),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '新建固定日程',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      EventEditorForm(
                        service: service,
                        initialStartUtc: startUtc,
                        initialEndUtc: startUtc.add(const Duration(hours: 1)),
                        timeZoneId: timeZoneId,
                        zones: zones,
                        onSaved: () => context.go('/calendar'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        GoRoute(
          // 日视图（FR-CAL-03）。与周视图共用同一个数据源，只是窗口为一天。
          path: '/calendar/day/:dayStartMicros',
          builder: (context, state) {
            final micros = int.tryParse(
              state.pathParameters['dayStartMicros'] ?? '',
            );
            if (micros == null) {
              return const _UnavailablePage(
                title: '日视图',
                message: '日期参数无效，无法显示这一天。',
              );
            }
            return DayViewPage(
              source: scheduleSource,
              dayStartUtc: DateTime.fromMicrosecondsSinceEpoch(
                micros,
                isUtc: true,
              ),
              zones: zones,
              timeZoneId: timeZoneId,
              onOpenWeek: () => context.go('/calendar'),
              // FR-CAL-01 的删除。页面只交回条目 id；删除端口未装配时不显示该按钮。
              // 删除后**不需要手动刷新**：日程视图由 drift 的 watch 驱动，写入会使它重新发出。
              onDeleteEvent: calendarService?.deleteEvent,
            );
          },
        ),
        GoRoute(
          // 需求的信息架构把"项目与分类管理"归在任务之下，因此它是任务的同级入口，
          // 而不是又一个设置页。管理界面本身此前完全不存在：服务层、仓库与
          // "新建项目并归属"都已就绪，但用户改不了名字、标记不了生活、归档不了项目。
          path: '/workspace',
          builder: (context, state) {
            final service = workspaceService;
            if (service == null) {
              return const _UnavailablePage(
                title: '领域与项目',
                message: '领域服务未装配，暂无法管理领域与项目。',
              );
            }
            return WorkspaceManagementPage(workspace: service);
          },
        ),
        GoRoute(
          // 设置成为入口页：其下再列子页，导航栏因此不必每加一个设置页就长一项（W3 的
          // "信息架构提醒"）。只列出实际装配好的子页。
          path: '/settings',
          builder: (context, state) => SettingsHubPage(
            entries: [
              SettingsHubEntry(
                key: const Key('settings-rules'),
                title: '规划规则与默认值',
                subtitle: '作息、精力区间、保护时间、每日上限与生活配额',
                onOpen: () => context.go('/settings/rules'),
              ),
              if (preferences != null)
                SettingsHubEntry(
                  key: const Key('settings-preferences'),
                  title: '学习偏好',
                  subtitle: '查看、确认或停用从行为中学到的偏好',
                  onOpen: () => context.go('/settings/preferences'),
                ),
              if (appLock != null)
                SettingsHubEntry(
                  key: const Key('settings-app-lock'),
                  title: '应用锁',
                  subtitle: '启动时需要密码；不宣称加密数据库',
                  onOpen: () => context.go('/settings/app-lock'),
                ),
              if (exportService != null)
                SettingsHubEntry(
                  key: const Key('settings-export'),
                  title: '数据导出',
                  subtitle: '把全部事实导出为 JSON 文件',
                  onOpen: () => context.go('/settings/export'),
                ),
            ],
          ),
        ),
        GoRoute(
          path: '/settings/rules',
          builder: (context, state) => PlanningRulesPage(
            service: settingsService,
            autoAdjustStore: autoAdjustStore,
          ),
        ),
        GoRoute(
          // 应用锁必须可达，否则它只能"被开启"却无法被开启：启动门控已经存在，但设置
          // 密码的入口此前没有任何路由，用户永远无法让锁生效（W6 + W3）。
          path: '/settings/app-lock',
          builder: (context, state) {
            final service = appLock;
            if (service == null) {
              return const _UnavailablePage(
                title: '应用锁',
                message: '应用锁服务未装配，暂无法开启或关闭应用锁。',
              );
            }
            return AppLockPage(service: service);
          },
        ),
        GoRoute(
          // 数据导出（FR-DATA-06）。服务与适配器早已写好并有测试，但从未在生产装配，
          // 因此"导出"在真实运行中不可达。
          path: '/settings/export',
          builder: (context, state) {
            final service = exportService;
            if (service == null) {
              return const _UnavailablePage(
                title: '数据导出',
                message: '导出服务未装配，暂无法导出数据。',
              );
            }
            // 目录选择与写入用的是同一个端口实例，这里直接复用服务里那一份。
            return ExportPage(service: service, files: service.files);
          },
        ),
        GoRoute(
          path: '/analytics',
          builder: (context, state) {
            final query = analytics;
            // 与调整预览一致：依赖未装配时明确说明原因，而不是给一个点了没反应的页面。
            if (query == null) {
              return const _UnavailablePage(
                title: '统计',
                message: '统计服务未装配，暂无法展示统计报表。',
              );
            }
            return AnalyticsPage(
              analytics: query,
              nowUtc: nowUtc ?? todayStartUtc,
              // FR-STAT-02 的标签筛选。标签服务未装配时整块不渲染。
              loadTagNames: tagService?.allTagNames,
            );
          },
        ),
        GoRoute(
          // 设置类页面统一挂在 /settings 之下，入口页按前缀判断导航选中项。
          path: '/settings/preferences',
          builder: (context, state) {
            final service = preferences;
            if (service == null) {
              return const _UnavailablePage(
                title: '偏好设置',
                message: '偏好服务未装配，暂无法查看或调整学习到的偏好。',
              );
            }
            return PreferencesPage(
              service: service,
              // FR-PREF-01/03 的输入端：没有它，这一页永远列不出建议。
              loadEvidence: loadPreferenceEvidence,
              // FR-STAT 的"建议采纳行为"来源（W5）。
              onSuggestionAction: onSuggestionAction,
            );
          },
        ),
        GoRoute(
          // 特殊日与次日恢复保护（Task 11）。C8 修复后恢复例外不再落库，因此这条链路
          // 必须真正可达：页面早已存在，却从来没有路由，也没有任何界面指向它（W3）。
          path: '/special-day',
          builder: (context, state) {
            final service = recovery;
            final events = calendar;
            if (service == null || events == null) {
              return const _UnavailablePage(
                title: '特殊日与恢复保护',
                message: '恢复服务未装配，暂无法生成恢复方案。',
              );
            }
            return _SpecialDayLoader(
              recovery: service,
              calendar: events,
              settings: settingsService,
              zones: zones,
              timeZoneId: timeZoneId,
              nowUtc: nowUtc ?? todayStartUtc,
              onOpenPreview: (proposalId) =>
                  context.go('/planning/preview/$proposalId'),
            );
          },
        ),
        GoRoute(
          path: '/planning/preview/:proposalId',
          builder: (context, state) => _PlanPreviewLoader(
            proposalId: state.pathParameters['proposalId']!,
            planning: planningService,
            application: planApplication,
            plans: plans,
            autoAdjustStore: autoAdjustStore,
            zones: zones,
            timeZoneId: timeZoneId,
          ),
        ),
      ],
    ),
  ],
);

/// 特殊日页需要**当日的规则与固定日程**，因此先把它们装配好再渲染页面。
///
/// 这正是 W3 里说的"特殊日需要动态数据装配"：页面本身只接收已经解析好的规则与事件，
/// 因为它不该知道规则来自设置、事件来自日历仓库。
final class _SpecialDayLoader extends StatelessWidget {
  const _SpecialDayLoader({
    required this.recovery,
    required this.calendar,
    required this.settings,
    required this.zones,
    required this.timeZoneId,
    required this.nowUtc,
    required this.onOpenPreview,
  });

  final RecoveryPlanningService recovery;
  final CalendarRepository calendar;
  final SettingsService settings;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final DateTime nowUtc;
  final ValueChanged<String> onOpenPreview;

  @override
  Widget build(BuildContext context) => FutureBuilder<_SpecialDayInputs>(
    future: _load(),
    builder: (context, snapshot) {
      final inputs = snapshot.data;
      if (inputs == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return SpecialDayPage(
        recoveryDate: inputs.recoveryDate,
        rules: inputs.rules,
        fixedEvents: inputs.fixedEvents,
        timeZoneId: timeZoneId,
        onCreateOverride: recovery.createOverride,
        onOpenPreview: onOpenPreview,
      );
    },
  );

  Future<_SpecialDayInputs> _load() async {
    // "恢复日"取本机今天：用户是在当晚或次日处理"晚归"的。选择其它日期需要日期选择器，
    // 那属于界面功能，不在本轮范围内，因此这里只用今天而不是假装支持任意日期。
    final local = zones.toLocal(nowUtc, timeZoneId);
    final today = DateTime(local.year, local.month, local.day);
    final startUtc = zones.localMidnightToUtc(today, timeZoneId);
    final endUtc = zones.localMidnightToUtc(
      today.add(const Duration(days: 1)),
      timeZoneId,
    );
    final rules = (await settings.resolveForDate(today)).rules;
    // 早课之类的固定日程会与"最低睡眠"冲突（FR-RECOVERY-04），因此必须带上当日实际事件。
    final events = await calendar.occurrencesBetween(startUtc, endUtc);
    return _SpecialDayInputs(
      recoveryDate: today,
      rules: rules,
      fixedEvents: events,
    );
  }
}

final class _SpecialDayInputs {
  const _SpecialDayInputs({
    required this.recoveryDate,
    required this.rules,
    required this.fixedEvents,
  });

  final DateTime recoveryDate;
  final PlanningRules rules;
  final List<CalendarOccurrence> fixedEvents;
}

/// 专注页需要"任务身份"（标题），因此这里先把任务读出来再渲染页面。
///
/// 任务不存在时给出明确说明而不是一个空标题：通知 payload 的 `route` 也会指向任务，
/// 而任务可能已被永久清除，此时用户需要知道发生了什么。
final class _FocusLoader extends StatefulWidget {
  const _FocusLoader({
    required this.focus,
    required this.tasks,
    required this.taskId,
  });

  final FocusService focus;
  final TaskService tasks;
  final String taskId;

  @override
  State<_FocusLoader> createState() => _FocusLoaderState();
}

final class _FocusLoaderState extends State<_FocusLoader> {
  late final Future<PlannerTask?> _task = widget.tasks.findById(widget.taskId);

  @override
  Widget build(BuildContext context) => FutureBuilder<PlannerTask?>(
    future: _task,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      final task = snapshot.data;
      if (task == null) {
        return const _UnavailablePage(
          title: '专注计时',
          message: '该任务不存在或已被永久删除，无法计时。',
        );
      }
      return FocusPage(
        service: widget.focus,
        taskId: task.id,
        taskTitle: task.title,
      );
    },
  );
}

Future<void> _generatePlan(
  BuildContext context,
  PlanningService planning,
) async {
  final proposal = await planning.createProposal();
  if (!context.mounted) return;
  context.go('/planning/preview/${proposal.proposalId}');
}

final class _PlannerShell extends StatelessWidget {
  const _PlannerShell({
    required this.location,
    required this.child,
    this.onGeneratePlan,
    this.onSpecialDay,
  });

  final String location;
  final Widget child;
  final Future<void> Function(BuildContext context)? onGeneratePlan;

  /// 特殊日与恢复保护的入口。为空时不显示该动作——未装配恢复服务时不留死按钮。
  final void Function(BuildContext context)? onSpecialDay;

  int get _selectedIndex => switch (location) {
    '/tasks' => 1,
    '/workspace' => 2,
    // 周视图与日视图同属"日历"，因此按前缀判断而不是逐条列举。
    final path when path.startsWith('/calendar') => 3,
    '/analytics' => 4,
    // 设置类页面都归在"设置"这一项下，因此按前缀判断而不是逐条列举。
    final path when path.startsWith('/settings') => 5,
    _ => 0,
  };

  @override
  Widget build(BuildContext context) {
    final generate = onGeneratePlan;
    final specialDay = onSpecialDay;
    return Scaffold(
      appBar: AppBar(
        title: const Text('智能日程'),
        actions: [
          if (specialDay != null)
            TextButton.icon(
              key: const Key('open-special-day'),
              onPressed: () => specialDay(context),
              icon: const Icon(Icons.bedtime_outlined),
              label: const Text('特殊日'),
            ),
          if (generate != null)
            TextButton.icon(
              onPressed: () => generate(context),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('生成计划'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            extended: true,
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              context.go(switch (index) {
                1 => '/tasks',
                2 => '/workspace',
                3 => '/calendar',
                4 => '/analytics',
                5 => '/settings',
                _ => '/today',
              });
            },
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.today_outlined),
                selectedIcon: Icon(Icons.today),
                label: Text('今日'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.checklist_outlined),
                selectedIcon: Icon(Icons.checklist),
                label: Text('任务'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.account_tree_outlined),
                selectedIcon: Icon(Icons.account_tree),
                label: Text('领域'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.calendar_view_week_outlined),
                selectedIcon: Icon(Icons.calendar_view_week),
                label: Text('日历'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.insights_outlined),
                selectedIcon: Icon(Icons.insights),
                label: Text('统计'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: Text('设置'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 依赖未装配时的占位页。
///
/// 明确写出"哪个服务没装、因此什么做不到"，而不是渲染一个空页面或点了没反应的
/// 控件——后者会让人以为功能坏了，而不是"这次没接线"。
final class _UnavailablePage extends StatelessWidget {
  const _UnavailablePage({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

/// 从内存中的提案构建真实的调整预览：与当前已确认计划做差异、带上冲突与缺口，
/// 确认时调用 `PlanApplicationService` 真正落库。
final class _PlanPreviewLoader extends StatefulWidget {
  const _PlanPreviewLoader({
    required this.proposalId,
    required this.autoAdjustStore,
    required this.zones,
    required this.timeZoneId,
    this.planning,
    this.application,
    this.plans,
  });

  final String proposalId;
  final AutoAdjustStore autoAdjustStore;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final PlanningService? planning;
  final PlanApplicationService? application;
  final PlanRepository? plans;

  @override
  State<_PlanPreviewLoader> createState() => _PlanPreviewLoaderState();
}

final class _PlanPreviewLoaderState extends State<_PlanPreviewLoader> {
  late final Future<PlanPreviewModel> _model = _build();

  Future<PlanPreviewModel> _build() async {
    final planning = widget.planning;
    if (planning == null) {
      return PlanPreviewModel(
        proposalId: widget.proposalId,
        changes: const [],
        conflicts: const ['当前未装配排程服务，无法生成或应用计划'],
        isStale: true,
      );
    }
    final proposal = planning.preview(widget.proposalId);
    if (proposal == null) {
      // 提案只保存在内存中；重启或重新生成后旧链接会失效。
      return PlanPreviewModel(
        proposalId: widget.proposalId,
        changes: const [],
        conflicts: const ['该调整提案已失效，请重新生成计划'],
        isStale: true,
      );
    }

    final current = await widget.plans?.current();
    final diff = const PlanDiffer().diff(
      current?.blocks ?? const <PlannedBlock>[],
      proposal.blocks,
    );

    return PlanPreviewModel(
      proposalId: widget.proposalId,
      changes: [
        for (final change in diff.changes)
          PreviewChange(
            kind: _kindOf(change),
            title: _titleOf(widget.zones, widget.timeZoneId, change),
            reason: explanationLabel(change.reason ?? ''),
          ),
      ],
      conflicts: [
        for (final conflict in proposal.conflicts) conflictLabel(conflict.code),
        for (final task in proposal.unscheduled)
          '「${task.taskId}」还缺 ${task.shortageMinutes} 分钟',
      ],
      isStale: false,
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlanPreviewModel>(
    future: _model,
    builder: (context, snapshot) {
      final model = snapshot.data;
      if (model == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return PlanPreviewPage(
        model: model,
        autoAdjustStore: widget.autoAdjustStore,
        onConfirm: () => _confirm(context, model),
      );
    },
  );

  Future<void> _confirm(BuildContext context, PlanPreviewModel model) async {
    final proposal = widget.planning?.preview(widget.proposalId);
    final application = widget.application;
    if (proposal == null || application == null) return;

    final result = await application.apply(proposal);
    if (!context.mounted) return;

    final message = switch (result.status) {
      ApplyPlanStatus.applied => '计划已更新',
      ApplyPlanStatus.staleProposal => '输入已变化，计划已过期，请重新生成',
      ApplyPlanStatus.invalidProposal => '计划未通过校验，未应用',
    };
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
    if (result.status == ApplyPlanStatus.applied) {
      context.go('/calendar');
    }
  }
}

PreviewChangeKind _kindOf(PlanChange change) => switch (change.type) {
  PlanChangeType.added => PreviewChangeKind.added,
  PlanChangeType.moved => PreviewChangeKind.moved,
  PlanChangeType.split => PreviewChangeKind.split,
  PlanChangeType.removed => PreviewChangeKind.removed,
};

String _titleOf(TimeZoneDatabase zones, String timeZoneId, PlanChange change) {
  final block = change.after ?? change.before;
  if (block == null) return change.blockId;
  final start = zones.toLocal(block.startUtc, timeZoneId);
  final end = zones.toLocal(block.endUtc, timeZoneId);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${block.taskId}  ${two(start.month)}-${two(start.day)} '
      '${two(start.hour)}:${two(start.minute)}–${two(end.hour)}:${two(end.minute)}';
}
