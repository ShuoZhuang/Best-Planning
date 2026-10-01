import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/week_view_page.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/tasks/task_list_page.dart';
import 'package:personal_planner/features/today/today_page.dart';

const _emptyScheduleSource = EmptyScheduleViewSource();
const _disabledMoveController = DisabledWeekMoveController();
final _autoAdjustStore = MemoryAutoAdjustStore();

GoRouter createPlannerRouter({required TaskService taskService}) => GoRouter(
  initialLocation: '/today',
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          _PlannerShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(
          path: '/today',
          builder: (context, state) =>
              TodayPage(source: _emptyScheduleSource, day: _todayUtc()),
        ),
        GoRoute(
          path: '/tasks',
          builder: (context, state) => TaskListPage(service: taskService),
        ),
        GoRoute(
          path: '/calendar',
          builder: (context, state) => WeekViewPage(
            source: _emptyScheduleSource,
            weekStart: _todayUtc(),
            moveController: _disabledMoveController,
            onProposalCreated: (proposalId) =>
                context.go('/planning/preview/$proposalId'),
          ),
        ),
        GoRoute(
          path: '/planning/preview/:proposalId',
          builder: (context, state) => PlanPreviewPage(
            model: PlanPreviewModel(
              proposalId: state.pathParameters['proposalId']!,
              changes: const [],
              conflicts: const [],
              isStale: true,
            ),
            autoAdjustStore: _autoAdjustStore,
            onConfirm: () async {},
          ),
        ),
      ],
    ),
  ],
);

final class _PlannerShell extends StatelessWidget {
  const _PlannerShell({required this.location, required this.child});

  final String location;
  final Widget child;

  int get _selectedIndex => switch (location) {
    '/tasks' => 1,
    '/calendar' => 2,
    _ => 0,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('智能日程')),
      body: Row(
        children: [
          NavigationRail(
            extended: true,
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              context.go(switch (index) {
                1 => '/tasks',
                2 => '/calendar',
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
                icon: Icon(Icons.calendar_view_week_outlined),
                selectedIcon: Icon(Icons.calendar_view_week),
                label: Text('日历'),
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

DateTime _todayUtc() {
  final now = DateTime.now().toUtc();
  return DateTime.utc(now.year, now.month, now.day);
}
