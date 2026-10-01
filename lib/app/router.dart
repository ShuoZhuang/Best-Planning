import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final GoRouter plannerRouter = GoRouter(
  initialLocation: '/today',
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          _PlannerShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(
          path: '/today',
          builder: (context, state) => const _SectionPage(
            title: '今日',
            description: '今日安排',
            icon: Icons.today_outlined,
          ),
        ),
        GoRoute(
          path: '/tasks',
          builder: (context, state) => const _SectionPage(
            title: '任务',
            description: '任务清单',
            icon: Icons.checklist_outlined,
          ),
        ),
        GoRoute(
          path: '/calendar',
          builder: (context, state) => const _SectionPage(
            title: '日历',
            description: '七日日历',
            icon: Icons.calendar_view_week_outlined,
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

final class _SectionPage extends StatelessWidget {
  const _SectionPage({
    required this.title,
    required this.description,
    required this.icon,
  });

  final String title;
  final String description;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: title,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(
              description,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
    );
  }
}
