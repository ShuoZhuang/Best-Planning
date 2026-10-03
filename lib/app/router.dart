import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/features/analytics/analytics_page.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/week_view_page.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/settings/planning_rules/planning_rules_page.dart';
import 'package:personal_planner/features/settings/preferences/preferences_page.dart';
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
  DateTime? nowUtc,
}) => GoRouter(
  initialLocation: '/today',
  routes: [
    ShellRoute(
      builder: (context, state, child) => _PlannerShell(
        location: state.uri.path,
        onGeneratePlan: planningService == null
            ? null
            : (shellContext) =>
                  _generatePlan(shellContext, planningService),
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
          ),
        ),
        GoRoute(
          // 通知 payload 里的 route 就指向这里（FR-NOTIFY-04 的快捷入口），
          // 此前该路由不存在，点击提醒无处可去。
          path: '/tasks/:taskId',
          builder: (context, state) => TaskDetailPage(
            service: taskService,
            workspace: workspaceService,
            taskId: state.pathParameters['taskId']!,
            nowUtc: nowUtc ?? todayStartUtc,
          ),
        ),
        GoRoute(
          path: '/calendar',
          builder: (context, state) => WeekViewPage(
            source: scheduleSource,
            weekStart: todayStartUtc,
            moveController: moveController,
            onProposalCreated: (proposalId) =>
                context.go('/planning/preview/$proposalId'),
          ),
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
          path: '/settings',
          builder: (context, state) => PlanningRulesPage(
            service: settingsService,
            autoAdjustStore: autoAdjustStore,
          ),
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
            );
          },
        ),
        GoRoute(
          path: '/preferences',
          builder: (context, state) {
            final service = preferences;
            if (service == null) {
              return const _UnavailablePage(
                title: '偏好设置',
                message: '偏好服务未装配，暂无法查看或调整学习到的偏好。',
              );
            }
            return PreferencesPage(service: service);
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
  });

  final String location;
  final Widget child;
  final Future<void> Function(BuildContext context)? onGeneratePlan;

  int get _selectedIndex => switch (location) {
    '/tasks' => 1,
    '/workspace' => 2,
    '/calendar' => 3,
    '/analytics' => 4,
    '/preferences' => 5,
    '/settings' => 6,
    _ => 0,
  };

  @override
  Widget build(BuildContext context) {
    final generate = onGeneratePlan;
    return Scaffold(
      appBar: AppBar(
        title: const Text('智能日程'),
        actions: [
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
                5 => '/preferences',
                6 => '/settings',
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
                icon: Icon(Icons.psychology_outlined),
                selectedIcon: Icon(Icons.psychology),
                label: Text('偏好'),
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
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
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

String _titleOf(
  TimeZoneDatabase zones,
  String timeZoneId,
  PlanChange change,
) {
  final block = change.after ?? change.before;
  if (block == null) return change.blockId;
  final start = zones.toLocal(block.startUtc, timeZoneId);
  final end = zones.toLocal(block.endUtc, timeZoneId);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${block.taskId}  ${two(start.month)}-${two(start.day)} '
      '${two(start.hour)}:${two(start.minute)}–${two(end.hour)}:${two(end.minute)}';
}
